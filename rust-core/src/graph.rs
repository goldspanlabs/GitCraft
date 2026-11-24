use std::collections::{HashMap, HashSet};

use gix::bstr::ByteSlice;

use crate::{
    BranchInfo, CommitRow, CommitSort, GitCraftError, GraphEdge, RefBadge, RefKind, TagInfo,
};

#[derive(Clone, Debug)]
pub(crate) struct RawCommit {
    pub oid: gix::ObjectId,
    pub parents: Vec<gix::ObjectId>,
    pub summary: String,
    pub author_name: String,
    pub timestamp: i64,
}

pub fn get_commit_graph(
    sync_repo: &gix::ThreadSafeRepository,
    offset: u32,
    limit: u32,
    search_query: Option<String>,
    sort: CommitSort,
) -> Result<Vec<CommitRow>, GitCraftError> {
    graph_walk(sync_repo, offset, limit, search_query, false, sort)
}

/// Like [`get_commit_graph`], but limited to the checked-out branch and the
/// default (base) branch, starting at their fork point. Falls back to the full
/// graph when HEAD is detached, is the default branch itself, or no base exists.
pub fn get_branch_graph(
    sync_repo: &gix::ThreadSafeRepository,
    offset: u32,
    limit: u32,
    search_query: Option<String>,
    sort: CommitSort,
) -> Result<Vec<CommitRow>, GitCraftError> {
    graph_walk(sync_repo, offset, limit, search_query, true, sort)
}

/// Resolves the default branch: `origin/HEAD`'s target, else `main`/`master`
/// (local branch preferred over `origin/`). Returns its full ref name and tip.
fn default_base(repo: &gix::Repository) -> Option<(String, gix::ObjectId)> {
    let mut candidates: Vec<String> = Vec::new();
    if let Ok(Some(r)) = repo.try_find_reference("refs/remotes/origin/HEAD") {
        if let gix::refs::TargetRef::Symbolic(name) = r.target() {
            let remote = name.as_bstr().to_str_lossy().into_owned();
            // Prefer the local branch of the same name (it may hold unpushed work).
            if let Some(short) = remote.strip_prefix("refs/remotes/origin/") {
                candidates.push(format!("refs/heads/{short}"));
            }
            candidates.push(remote);
        }
    }
    for n in ["main", "master"] {
        candidates.push(format!("refs/heads/{n}"));
        candidates.push(format!("refs/remotes/origin/{n}"));
    }
    candidates.into_iter().find_map(|name| {
        let r = repo.try_find_reference(name.as_str()).ok().flatten()?;
        let id = r.into_fully_peeled_id().ok()?.detach();
        Some((name, id))
    })
}

fn short_branch_name(full: &str) -> &str {
    full.strip_prefix("refs/heads/")
        .or_else(|| full.strip_prefix("refs/remotes/origin/"))
        .unwrap_or(full)
}

/// Tips and hidden commits for the "current branch vs base" view, or `None`
/// when the full graph should be shown.
fn branch_scope(repo: &gix::Repository) -> Option<(Vec<gix::ObjectId>, Vec<gix::ObjectId>)> {
    let head = repo.head().ok()?;
    let head_ref = head.referent_name()?.as_bstr().to_str_lossy().into_owned();
    let head_id = head.id()?.detach();
    let (base_ref, base_id) = default_base(repo)?;
    if short_branch_name(&head_ref) == short_branch_name(&base_ref) || head_id == base_id {
        return None;
    }
    // Hide everything below the fork point, but keep the fork commit itself.
    let hidden = repo
        .merge_base(head_id, base_id)
        .ok()
        .flatten()
        .and_then(|mb| repo.find_commit(mb.detach()).ok())
        .map(|c| c.parent_ids().map(|p| p.detach()).collect())
        .unwrap_or_default();
    Some((vec![head_id, base_id], hidden))
}

fn graph_walk(
    sync_repo: &gix::ThreadSafeRepository,
    offset: u32,
    limit: u32,
    search_query: Option<String>,
    scoped: bool,
    sort: CommitSort,
) -> Result<Vec<CommitRow>, GitCraftError> {
    if limit == 0 {
        return Ok(Vec::new());
    }

    let mut repo = sync_repo.to_thread_local();
    repo.object_cache_size_if_unset(4 * 1024 * 1024);
    let (refs_by_oid, mut tips, mut local_reachable) = collect_refs_and_tips(&repo)?;
    if tips.is_empty() {
        return Ok(Vec::new());
    }
    let mut hidden: Vec<gix::ObjectId> = Vec::new();
    if scoped {
        if let Some((scoped_tips, scoped_hidden)) = branch_scope(&repo) {
            tips = scoped_tips;
            hidden = scoped_hidden;
        }
    }
    let has_local_refs = !local_reachable.is_empty();

    let query = search_query
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty());

    let target_count = offset.saturating_add(limit) as usize;

    let graph_err = |e: &dyn std::fmt::Display| GitCraftError::message(e.to_string());
    let ids: Box<dyn Iterator<Item = Result<gix::ObjectId, GitCraftError>>> = match sort {
        CommitSort::ByDate => {
            let walk = repo
                .rev_walk(tips)
                .with_hidden(hidden)
                .sorting(gix::revision::walk::Sorting::ByCommitTime(
                    gix::traverse::commit::simple::CommitTimeOrder::NewestFirst,
                ))
                .all()
                .map_err(|e| graph_err(&e))?;
            Box::new(walk.map(|entry| entry.map(|info| info.id).map_err(|e| graph_err(&e))))
        }
        CommitSort::Topological => {
            // Like `git log --topo-order`: a parent never appears before its children and
            // commits of one line of history are not interleaved with another's.
            let topo =
                gix::traverse::commit::topo::Builder::from_iters(&repo.objects, tips, Some(hidden))
                    .sorting(gix::traverse::commit::topo::Sorting::TopoOrder)
                    .parents(gix::traverse::commit::Parents::All)
                    .build()
                    .map_err(|e| graph_err(&e))?;
            Box::new(topo.map(|entry| entry.map(|info| info.id).map_err(|e| graph_err(&e))))
        }
    };

    let mut active_lanes: Vec<Option<gix::ObjectId>> = Vec::new();
    let mut lane_colors: Vec<u8> = Vec::new();
    let mut next_color: u8 = 0;

    let mut results: Vec<CommitRow> = Vec::new();

    for entry in ids {
        let oid = entry?;
        let commit = repo
            .find_commit(oid)
            .map_err(|e| GitCraftError::message(e.to_string()))?;

        let parents: Vec<gix::ObjectId> = commit.parent_ids().map(|id| id.detach()).collect();

        let is_local = !has_local_refs || local_reachable.contains(&oid);
        if is_local {
            for &p in &parents {
                local_reachable.insert(p);
            }
        }
        let is_remote_only = !is_local;

        let summary = commit
            .message_raw_sloppy()
            .to_str_lossy()
            .lines()
            .next()
            .unwrap_or_default()
            .trim()
            .to_owned();

        let author_name = commit
            .author()
            .map(|a| a.name.to_str_lossy().into_owned())
            .unwrap_or_default();

        let timestamp = commit.time().map(|t| t.seconds).unwrap_or_default();

        let raw = RawCommit {
            oid,
            parents,
            summary,
            author_name,
            timestamp,
        };

        let badges = refs_by_oid.get(&oid).cloned().unwrap_or_default();
        let mut row = assign_commit_lane(
            &raw,
            badges,
            &mut active_lanes,
            &mut lane_colors,
            &mut next_color,
        );
        row.is_remote_only = is_remote_only;

        let matches_query = match &query {
            None => true,
            Some(q) => {
                row.summary.to_lowercase().contains(q)
                    || row.author_name.to_lowercase().contains(q)
                    || row.oid_hex.to_lowercase().contains(q)
            }
        };

        if matches_query {
            results.push(row);
            if results.len() >= target_count {
                break;
            }
        }
    }

    Ok(results
        .into_iter()
        .skip(offset as usize)
        .take(limit as usize)
        .collect())
}

pub(crate) fn assign_commit_lane(
    commit: &RawCommit,
    refs: Vec<RefBadge>,
    active_lanes: &mut Vec<Option<gix::ObjectId>>,
    lane_colors: &mut Vec<u8>,
    next_color: &mut u8,
) -> CommitRow {
    let mut edges: Vec<GraphEdge> = Vec::new();

    // 1. Locate commit.oid in active_lanes; collapse converging duplicates.
    let matching_slots: Vec<usize> = active_lanes
        .iter()
        .enumerate()
        .filter_map(|(idx, slot)| (*slot == Some(commit.oid)).then_some(idx))
        .collect();

    let (commit_lane, commit_color) = if let Some(&first_slot) = matching_slots.first() {
        let color = lane_colors[first_slot];
        for &dup in &matching_slots[1..] {
            let dup_color = lane_colors[dup];
            active_lanes[dup] = None;
            edges.push(GraphEdge {
                from_lane: dup as u32,
                to_lane: first_slot as u32,
                is_merge: true,
                color_idx: dup_color,
            });
        }
        (first_slot, color)
    } else {
        // Branch tip: place in first free slot or append a new lane.
        let slot = active_lanes
            .iter()
            .position(|s| s.is_none())
            .unwrap_or_else(|| {
                active_lanes.push(None);
                lane_colors.push(0);
                active_lanes.len() - 1
            });
        let color = *next_color % 8;
        *next_color = next_color.wrapping_add(1);
        active_lanes[slot] = Some(commit.oid);
        lane_colors[slot] = color;
        (slot, color)
    };

    // 2. Emit vertical pass-through edges for all other occupied slots.
    for (idx, slot) in active_lanes.iter().enumerate() {
        if idx != commit_lane && slot.is_some() {
            edges.push(GraphEdge {
                from_lane: idx as u32,
                to_lane: idx as u32,
                is_merge: false,
                color_idx: lane_colors[idx],
            });
        }
    }

    // 3. Route parents[0] into active_lanes[commit_lane] to keep mainline straight.
    if let Some(&first_parent) = commit.parents.first() {
        active_lanes[commit_lane] = Some(first_parent);
        lane_colors[commit_lane] = commit_color;
        edges.push(GraphEdge {
            from_lane: commit_lane as u32,
            to_lane: commit_lane as u32,
            is_merge: false,
            color_idx: commit_color,
        });
    } else {
        active_lanes[commit_lane] = None;
    }

    // 4. Route parents[1..] (merge parents) into existing matching lanes or nearest free slot.
    for &parent_oid in commit.parents.iter().skip(1) {
        let (target_lane, edge_color) =
            if let Some(existing) = active_lanes.iter().position(|s| *s == Some(parent_oid)) {
                (existing, lane_colors[existing])
            } else {
                let slot = nearest_free_lane(active_lanes, commit_lane).unwrap_or_else(|| {
                    active_lanes.push(None);
                    lane_colors.push(0);
                    active_lanes.len() - 1
                });
                let color = *next_color % 8;
                *next_color = next_color.wrapping_add(1);
                active_lanes[slot] = Some(parent_oid);
                lane_colors[slot] = color;
                (slot, color)
            };

        edges.push(GraphEdge {
            from_lane: commit_lane as u32,
            to_lane: target_lane as u32,
            is_merge: true,
            color_idx: edge_color,
        });
    }

    // Compute max_lanes across active lanes and emitted edges before trimming.
    let mut max_lanes = active_lanes.len().max(commit_lane + 1);
    for edge in &edges {
        max_lanes = max_lanes
            .max(edge.from_lane as usize + 1)
            .max(edge.to_lane as usize + 1);
    }

    // 5. Trim trailing None slots to keep max_lanes compact.
    while active_lanes.last().is_some_and(|s| s.is_none()) {
        active_lanes.pop();
        lane_colors.pop();
    }

    let oid_hex = commit.oid.to_hex().to_string();
    let short_oid = oid_hex.chars().take(7).collect();

    CommitRow {
        oid_hex,
        short_oid,
        summary: commit.summary.clone(),
        author_name: commit.author_name.clone(),
        timestamp: commit.timestamp,
        lane: commit_lane as u32,
        color_idx: commit_color,
        max_lanes: max_lanes as u32,
        edges,
        refs,
        is_remote_only: false,
    }
}

fn nearest_free_lane(active_lanes: &[Option<gix::ObjectId>], origin: usize) -> Option<usize> {
    active_lanes
        .iter()
        .enumerate()
        .filter(|(_, slot)| slot.is_none())
        .min_by_key(|(idx, _)| idx.abs_diff(origin))
        .map(|(idx, _)| idx)
}

type RefsAndTips = (
    HashMap<gix::ObjectId, Vec<RefBadge>>,
    Vec<gix::ObjectId>,
    HashSet<gix::ObjectId>,
);

fn collect_refs_and_tips(repo: &gix::Repository) -> Result<RefsAndTips, GitCraftError> {
    let mut refs_by_oid: HashMap<gix::ObjectId, Vec<RefBadge>> = HashMap::new();
    let mut tip_set: HashSet<gix::ObjectId> = HashSet::new();
    let mut local_tips: HashSet<gix::ObjectId> = HashSet::new();

    let head = repo
        .head()
        .map_err(|e| GitCraftError::message(e.to_string()))?;
    let head_referent = head
        .referent_name()
        .map(|name| name.as_bstr().to_str_lossy().into_owned());

    if let Some(head_id) = head.id() {
        let oid = head_id.detach();
        tip_set.insert(oid);
        local_tips.insert(oid);
        if head_referent.is_none() {
            refs_by_oid.entry(oid).or_default().push(RefBadge {
                name: "HEAD".to_owned(),
                kind: RefKind::Head,
                is_current: true,
            });
        }
    }

    let references = repo
        .references()
        .map_err(|e| GitCraftError::message(e.to_string()))?;
    let all_refs = references
        .all()
        .map_err(|e| GitCraftError::message(e.to_string()))?;

    for reference_res in all_refs {
        let reference = match reference_res {
            Ok(r) => r,
            Err(_) => continue,
        };
        let full_name = reference.name().as_bstr().to_str_lossy().into_owned();

        let (kind, short_name) = if let Some(name) = full_name.strip_prefix("refs/heads/") {
            (RefKind::LocalBranch, name.to_owned())
        } else if let Some(name) = full_name.strip_prefix("refs/remotes/") {
            if name.ends_with("/HEAD") {
                continue;
            }
            (RefKind::RemoteBranch, name.to_owned())
        } else if let Some(name) = full_name.strip_prefix("refs/tags/") {
            (RefKind::Tag, name.to_owned())
        } else {
            continue;
        };

        let is_current = head_referent.as_deref() == Some(full_name.as_str());
        if let Ok(peeled) = reference.into_fully_peeled_id() {
            let oid = peeled.detach();
            tip_set.insert(oid);
            if matches!(kind, RefKind::LocalBranch) {
                local_tips.insert(oid);
            }
            refs_by_oid.entry(oid).or_default().push(RefBadge {
                name: short_name,
                kind,
                is_current,
            });
        }
    }

    for badges in refs_by_oid.values_mut() {
        badges.sort_by(|a, b| {
            b.is_current
                .cmp(&a.is_current)
                .then_with(|| ref_kind_rank(a.kind).cmp(&ref_kind_rank(b.kind)))
                .then_with(|| a.name.cmp(&b.name))
        });
    }

    let mut tips: Vec<gix::ObjectId> = tip_set.into_iter().collect();
    tips.sort();
    Ok((refs_by_oid, tips, local_tips))
}

fn ref_kind_rank(kind: RefKind) -> u8 {
    match kind {
        RefKind::Head => 0,
        RefKind::LocalBranch => 1,
        RefKind::RemoteBranch => 2,
        RefKind::Tag => 3,
    }
}

pub fn list_branches(
    sync_repo: &gix::ThreadSafeRepository,
) -> Result<Vec<BranchInfo>, GitCraftError> {
    let repo = sync_repo.to_thread_local();
    let head = repo
        .head()
        .map_err(|e| GitCraftError::message(e.to_string()))?;
    let head_referent = head
        .referent_name()
        .map(|name| name.as_bstr().to_str_lossy().into_owned());

    let references = repo
        .references()
        .map_err(|e| GitCraftError::message(e.to_string()))?;
    let all_refs = references
        .all()
        .map_err(|e| GitCraftError::message(e.to_string()))?;

    let mut remote_oids: HashMap<String, gix::ObjectId> = HashMap::new();
    let mut remote_head_targets: HashMap<String, String> = HashMap::new();
    let mut local_entries: Vec<(String, String, gix::ObjectId, bool)> = Vec::new();
    let mut remote_entries: Vec<(String, String, gix::ObjectId)> = Vec::new();

    for reference_res in all_refs {
        let reference = match reference_res {
            Ok(r) => r,
            Err(_) => continue,
        };
        let full_name = reference.name().as_bstr().to_str_lossy().into_owned();
        if let Some(name) = full_name.strip_prefix("refs/heads/") {
            let is_head = head_referent.as_deref() == Some(full_name.as_str());
            if let Ok(peeled) = reference.into_fully_peeled_id() {
                local_entries.push((name.to_owned(), full_name, peeled.detach(), is_head));
            }
        } else if let Some(name) = full_name.strip_prefix("refs/remotes/") {
            if name.ends_with("/HEAD") {
                // e.g. refs/remotes/origin/HEAD -> refs/remotes/origin/main
                if let gix::refs::TargetRef::Symbolic(target) = reference.target() {
                    remote_head_targets.insert(
                        full_name.clone(),
                        target.as_bstr().to_str_lossy().into_owned(),
                    );
                }
                continue;
            }
            if let Ok(peeled) = reference.into_fully_peeled_id() {
                let oid = peeled.detach();
                remote_oids.insert(full_name.clone(), oid);
                remote_entries.push((name.to_owned(), full_name, oid));
            }
        }
    }

    let config = repo.config_snapshot();
    let mut branches = Vec::with_capacity(local_entries.len() + remote_entries.len());

    // Branches are "merged" when fully contained in origin's default branch.
    let base_ref = remote_head_targets
        .get("refs/remotes/origin/HEAD")
        .cloned()
        .filter(|r| remote_oids.contains_key(r))
        .or_else(|| {
            ["refs/remotes/origin/main", "refs/remotes/origin/master"]
                .into_iter()
                .find(|r| remote_oids.contains_key(*r))
                .map(str::to_owned)
        });
    let base_oid = base_ref.as_ref().and_then(|r| remote_oids.get(r)).copied();

    for (name, full_ref, local_oid, is_head) in local_entries {
        let upstream_full = resolve_upstream_ref(&config, &name)
            .filter(|r| remote_oids.contains_key(r))
            .or_else(|| {
                let fallback = format!("refs/remotes/origin/{name}");
                remote_oids.contains_key(&fallback).then_some(fallback)
            });

        let (ahead, behind) = if let Some(up_ref) = upstream_full {
            if let Some(&up_oid) = remote_oids.get(&up_ref) {
                compute_ahead_behind(&repo, local_oid, up_oid)
            } else {
                (0, 0)
            }
        } else {
            (0, 0)
        };

        // The default branch itself is trivially "merged"; don't flag it.
        let is_default_branch = base_ref
            .as_deref()
            .and_then(|r| r.strip_prefix("refs/remotes/origin/"))
            .is_some_and(|base_name| base_name == name);
        let is_merged = !is_head
            && !is_default_branch
            && !is_untouched_new_branch(&repo, &full_ref, &remote_oids, base_ref.as_deref())
            && base_oid.is_some_and(|base| is_fully_merged(&repo, local_oid, base));

        branches.push(BranchInfo {
            name,
            full_ref,
            is_remote: false,
            is_head,
            target_oid_hex: local_oid.to_hex().to_string(),
            ahead,
            behind,
            is_merged,
        });
    }

    for (name, full_ref, oid) in remote_entries {
        branches.push(BranchInfo {
            name,
            full_ref,
            is_remote: true,
            is_head: false,
            target_oid_hex: oid.to_hex().to_string(),
            ahead: 0,
            behind: 0,
            is_merged: false,
        });
    }

    branches.sort_by(|a, b| {
        a.is_remote
            .cmp(&b.is_remote)
            .then_with(|| b.is_head.cmp(&a.is_head))
            .then_with(|| a.name.cmp(&b.name))
    });

    Ok(branches)
}

pub fn list_tags(sync_repo: &gix::ThreadSafeRepository) -> Result<Vec<TagInfo>, GitCraftError> {
    let repo = sync_repo.to_thread_local();
    let references = repo
        .references()
        .map_err(|e| GitCraftError::message(e.to_string()))?;
    let all_refs = references
        .all()
        .map_err(|e| GitCraftError::message(e.to_string()))?;

    let mut tags = Vec::new();
    for reference_res in all_refs {
        let reference = match reference_res {
            Ok(r) => r,
            Err(_) => continue,
        };
        let full_name = reference.name().as_bstr().to_str_lossy().into_owned();
        if let Some(name) = full_name.strip_prefix("refs/tags/") {
            let direct_id = reference.id().detach();
            if let Ok(peeled) = reference.into_fully_peeled_id() {
                let peeled_id = peeled.detach();
                tags.push(TagInfo {
                    name: name.to_owned(),
                    full_ref: full_name,
                    target_oid_hex: peeled_id.to_hex().to_string(),
                    created_timestamp: tag_created_seconds(&repo, direct_id, peeled_id),
                });
            }
        }
    }

    // Newest first; fall back to name so ties are stable.
    tags.sort_by(|a, b| {
        b.created_timestamp
            .cmp(&a.created_timestamp)
            .then_with(|| b.name.cmp(&a.name))
    });
    Ok(tags)
}

/// When a tag was created: the tagger date of an annotated tag, otherwise the
/// date of the commit a lightweight tag points at.
fn tag_created_seconds(
    repo: &gix::Repository,
    direct_id: gix::ObjectId,
    peeled_id: gix::ObjectId,
) -> i64 {
    if direct_id != peeled_id {
        if let Ok(object) = repo.find_object(direct_id) {
            if let Ok(tag) = object.try_into_tag() {
                if let Ok(Some(tagger)) = tag.tagger() {
                    if let Ok(time) = tagger.time() {
                        return time.seconds;
                    }
                }
            }
        }
    }
    repo.find_commit(peeled_id)
        .ok()
        .and_then(|c| c.time().ok())
        .map(|t| t.seconds)
        .unwrap_or_default()
}

fn resolve_upstream_ref(config: &gix::config::Snapshot<'_>, branch_name: &str) -> Option<String> {
    let remote = config
        .string(&format!("branch.{branch_name}.remote"))?
        .to_str_lossy()
        .into_owned();
    let merge = config
        .string(&format!("branch.{branch_name}.merge"))?
        .to_str_lossy()
        .into_owned();
    let short_merge = merge.strip_prefix("refs/heads/").unwrap_or(&merge);
    Some(format!("refs/remotes/{remote}/{short_merge}"))
}

/// True when the branch's reflog shows it was only ever created and never moved
/// (no commits, resets, merges or pulls), so "merged" would be misleading.
///
/// Branches created from a remote-tracking ref other than the default branch
/// (e.g. `git checkout -b topic origin/topic`) are not exempt: they carry the
/// remote's feature commits, which may since have been merged.
/// Without a reflog (e.g. fetched or cloned branches) we can't tell, so false.
fn is_untouched_new_branch(
    repo: &gix::Repository,
    full_ref: &str,
    remote_oids: &HashMap<String, gix::ObjectId>,
    base_ref: Option<&str>,
) -> bool {
    use std::io::{BufRead, BufReader};

    let Ok(file) = std::fs::File::open(repo.common_dir().join("logs").join(full_ref)) else {
        return false;
    };
    let mut seen_entry = false;
    for line in BufReader::new(file).lines() {
        let Ok(line) = line else { return false };
        if line.trim().is_empty() {
            continue;
        }
        let Some(source) = line
            .split_once('\t')
            .and_then(|(_, msg)| msg.strip_prefix("branch: Created from "))
        else {
            // First non-creation entry: the branch has moved, stop reading.
            return false;
        };
        let remote_ref = format!("refs/remotes/{}", source.trim());
        if remote_oids.contains_key(&remote_ref) && Some(remote_ref.as_str()) != base_ref {
            return false;
        }
        seen_entry = true;
    }
    seen_entry
}

/// True when every commit reachable from `tip` is already reachable from `base`.
fn is_fully_merged(repo: &gix::Repository, tip: gix::ObjectId, base: gix::ObjectId) -> bool {
    if tip == base {
        return true;
    }
    repo.rev_walk([tip])
        .with_hidden([base])
        .all()
        .map(|mut w| w.next().is_none())
        .unwrap_or(false)
}

fn compute_ahead_behind(
    repo: &gix::Repository,
    local_oid: gix::ObjectId,
    upstream_oid: gix::ObjectId,
) -> (u32, u32) {
    if local_oid == upstream_oid {
        return (0, 0);
    }
    let ahead = repo
        .rev_walk([local_oid])
        .with_hidden([upstream_oid])
        .all()
        .map(|w| w.count() as u32)
        .unwrap_or(0);
    let behind = repo
        .rev_walk([upstream_oid])
        .with_hidden([local_oid])
        .all()
        .map(|w| w.count() as u32)
        .unwrap_or(0);
    (ahead, behind)
}

pub fn get_commit_detail(
    repo_path: &std::path::Path,
    sync_repo: &gix::ThreadSafeRepository,
    oid_hex: &str,
) -> Result<crate::CommitDetail, GitCraftError> {
    let oid = gix::ObjectId::from_hex(oid_hex.as_bytes())
        .map_err(|e| GitCraftError::message(e.to_string()))?;
    let repo = sync_repo.to_thread_local();
    let commit = repo
        .find_commit(oid)
        .map_err(|e| GitCraftError::message(e.to_string()))?;

    let raw_msg = commit.message_raw_sloppy().to_str_lossy().into_owned();
    let mut lines = raw_msg.lines();
    let summary = lines.next().unwrap_or_default().trim().to_owned();
    let body = lines.collect::<Vec<_>>().join("\n").trim().to_owned();

    let (author_name, author_email) = commit
        .author()
        .map(|a| {
            (
                a.name.to_str_lossy().into_owned(),
                a.email.to_str_lossy().into_owned(),
            )
        })
        .unwrap_or_default();

    let timestamp = commit.time().map(|t| t.seconds).unwrap_or_default();
    let parent_oids = commit
        .parent_ids()
        .map(|p| p.detach().to_hex().to_string())
        .collect();

    let files_output = crate::git_cli::run(
        repo_path,
        &[
            "diff-tree",
            "--no-commit-id",
            "--name-status",
            "-z",
            "-r",
            "--root",
            oid_hex,
        ],
    )?;

    // -z output is "<status>\0<path>\0" per file, with no quoting of unusual paths.
    let mut files = Vec::new();
    let mut fields = files_output.split('\0');
    while let (Some(status), Some(path)) = (fields.next(), fields.next()) {
        let status = status.trim();
        if status.is_empty() || path.is_empty() {
            continue;
        }
        files.push(crate::FileChange {
            path: path.to_owned(),
            status: status.chars().next().unwrap_or('M').to_string(),
            staged: false,
        });
    }

    Ok(crate::CommitDetail {
        oid_hex: oid_hex.to_owned(),
        short_oid: oid_hex.chars().take(7).collect(),
        summary,
        body,
        author_name,
        author_email,
        timestamp,
        parent_oids,
        files,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn oid(byte: u8) -> gix::ObjectId {
        gix::ObjectId::from_bytes_or_panic(&[byte; 20])
    }

    fn raw(id: u8, parents: &[u8], summary: &str) -> RawCommit {
        RawCommit {
            oid: oid(id),
            parents: parents.iter().map(|&p| oid(p)).collect(),
            summary: summary.to_owned(),
            author_name: "Tester".to_owned(),
            timestamp: 1_700_000_000 + id as i64,
        }
    }

    #[test]
    fn linear_history_uses_single_straight_lane() {
        let mut active_lanes = Vec::new();
        let mut lane_colors = Vec::new();
        let mut next_color = 0;

        let c3 = assign_commit_lane(
            &raw(3, &[2], "c3"),
            vec![],
            &mut active_lanes,
            &mut lane_colors,
            &mut next_color,
        );
        let c2 = assign_commit_lane(
            &raw(2, &[1], "c2"),
            vec![],
            &mut active_lanes,
            &mut lane_colors,
            &mut next_color,
        );
        let c1 = assign_commit_lane(
            &raw(1, &[], "c1"),
            vec![],
            &mut active_lanes,
            &mut lane_colors,
            &mut next_color,
        );

        assert_eq!(c3.lane, 0);
        assert_eq!(c3.max_lanes, 1);
        assert_eq!(c3.color_idx, c2.color_idx);
        assert_eq!(c2.lane, 0);
        assert_eq!(c2.max_lanes, 1);
        assert_eq!(c1.lane, 0);
        assert_eq!(c1.color_idx, c3.color_idx);
        assert!(active_lanes.is_empty());
    }

    #[test]
    fn branch_creation_and_merge_convergence_lane_geometry() {
        // History (newest first):
        //   c4 (merge: parents [c3, c2]) on main
        //   c3 (parent [c1]) on main
        //   c2 (parent [c1]) on feature
        //   c1 (root)
        let mut active_lanes = Vec::new();
        let mut lane_colors = Vec::new();
        let mut next_color = 0;

        let c4 = assign_commit_lane(
            &raw(4, &[3, 2], "Merge feature"),
            vec![],
            &mut active_lanes,
            &mut lane_colors,
            &mut next_color,
        );
        assert_eq!(c4.lane, 0);
        assert_eq!(c4.max_lanes, 2);
        // Outgoing merge edge from lane 0 -> lane 1
        assert!(c4
            .edges
            .iter()
            .any(|e| e.from_lane == 0 && e.to_lane == 1 && e.is_merge));

        let c3 = assign_commit_lane(
            &raw(3, &[1], "Main work"),
            vec![],
            &mut active_lanes,
            &mut lane_colors,
            &mut next_color,
        );
        assert_eq!(c3.lane, 0);
        assert_eq!(c3.max_lanes, 2);
        // Lane 1 should pass straight through while lane 0 is at c3
        assert!(c3
            .edges
            .iter()
            .any(|e| e.from_lane == 1 && e.to_lane == 1 && !e.is_merge));

        let c2 = assign_commit_lane(
            &raw(2, &[1], "Feature work"),
            vec![],
            &mut active_lanes,
            &mut lane_colors,
            &mut next_color,
        );
        assert_eq!(c2.lane, 1);
        assert_eq!(c2.max_lanes, 2);

        // Now both lane 0 and lane 1 point to c1: should converge onto lane 0.
        let c1 = assign_commit_lane(
            &raw(1, &[], "Initial"),
            vec![],
            &mut active_lanes,
            &mut lane_colors,
            &mut next_color,
        );
        assert_eq!(c1.lane, 0);
        assert_eq!(c1.max_lanes, 2);
        assert!(c1
            .edges
            .iter()
            .any(|e| e.from_lane == 1 && e.to_lane == 0 && e.is_merge));
        assert!(active_lanes.is_empty());
    }

    #[test]
    fn gix_repo_walk_pagination_search_and_branches() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();

        let run_git = |args: &[&str], ts: i64| {
            let date = format!("{ts} +0000");
            let out = Command::new("git")
                .args(args)
                .current_dir(p)
                .env("GIT_AUTHOR_NAME", "Alice")
                .env("GIT_AUTHOR_EMAIL", "alice@example.com")
                .env("GIT_COMMITTER_NAME", "Alice")
                .env("GIT_COMMITTER_EMAIL", "alice@example.com")
                .env("GIT_AUTHOR_DATE", &date)
                .env("GIT_COMMITTER_DATE", &date)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "git {:?} failed: {}",
                args,
                String::from_utf8_lossy(&out.stderr)
            );
        };

        run_git(&["init", "-b", "main"], 1_700_000_000);
        std::fs::write(p.join("a.txt"), "1\n").unwrap();
        run_git(&["add", "."], 1_700_000_000);
        run_git(&["commit", "-m", "Initial commit"], 1_700_000_001);

        run_git(&["checkout", "-b", "feature/ui"], 1_700_000_001);
        std::fs::write(p.join("b.txt"), "2\n").unwrap();
        run_git(&["add", "."], 1_700_000_001);
        run_git(&["commit", "-m", "Add UI feature"], 1_700_000_002);

        run_git(&["checkout", "main"], 1_700_000_002);
        run_git(
            &["merge", "--no-ff", "feature/ui", "-m", "Merge UI"],
            1_700_000_003,
        );
        run_git(&["tag", "v0.1.0"], 1_700_000_003);

        let sync_repo = gix::ThreadSafeRepository::open(p).unwrap();

        let all_rows = get_commit_graph(&sync_repo, 0, 50, None, CommitSort::ByDate).unwrap();
        assert_eq!(all_rows.len(), 3);
        assert_eq!(all_rows[0].summary, "Merge UI");
        assert!(all_rows[0]
            .refs
            .iter()
            .any(|r| r.name == "main" && r.is_current));
        assert!(all_rows[0]
            .refs
            .iter()
            .any(|r| r.name == "v0.1.0" && matches!(r.kind, RefKind::Tag)));

        let page2 = get_commit_graph(&sync_repo, 1, 1, None, CommitSort::ByDate).unwrap();
        assert_eq!(page2.len(), 1);
        assert_eq!(page2[0].oid_hex, all_rows[1].oid_hex);

        let filtered = get_commit_graph(
            &sync_repo,
            0,
            10,
            Some("UI feature".into()),
            CommitSort::ByDate,
        )
        .unwrap();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].summary, "Add UI feature");

        let branches = list_branches(&sync_repo).unwrap();
        assert_eq!(branches.len(), 2);
        assert!(branches.iter().any(|b| b.name == "main" && b.is_head));
        assert!(branches
            .iter()
            .any(|b| b.name == "feature/ui" && !b.is_head));

        let tags = list_tags(&sync_repo).unwrap();
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].name, "v0.1.0");
    }
}
