use std::collections::{HashMap, HashSet};

use gix::bstr::ByteSlice;

use crate::{BranchInfo, GitCraftError, RefBadge, RefKind, TagInfo};

pub(crate) type RefsAndTips = (
    HashMap<gix::ObjectId, Vec<RefBadge>>,
    Vec<gix::ObjectId>,
    HashSet<gix::ObjectId>,
);

const DEFAULT_BRANCH_FALLBACKS: [&str; 2] = ["main", "master"];

/// Iterates every valid reference in `repo`, invoking `visit` with the decoded full ref name
/// and the `gix::Reference`. Centralizes reference-enumeration error handling.
fn for_each_ref(
    repo: &gix::Repository,
    mut visit: impl FnMut(String, gix::Reference<'_>),
) -> Result<(), GitCraftError> {
    let references = repo
        .references()
        .map_err(|e| GitCraftError::message(e.to_string()))?;
    let all_refs = references
        .all()
        .map_err(|e| GitCraftError::message(e.to_string()))?;

    for reference_res in all_refs {
        let Ok(reference) = reference_res else {
            continue;
        };
        let full_name = reference.name().as_bstr().to_str_lossy().into_owned();
        visit(full_name, reference);
    }
    Ok(())
}

/// Returns the full ref name that `refs/remotes/origin/HEAD` points to, if symbolic.
fn origin_head_target(repo: &gix::Repository) -> Option<String> {
    let r = repo
        .try_find_reference("refs/remotes/origin/HEAD")
        .ok()
        .flatten()?;
    match r.target() {
        gix::refs::TargetRef::Symbolic(name) => Some(name.as_bstr().to_str_lossy().into_owned()),
        _ => None,
    }
}

/// Resolves the default branch: `origin/HEAD`'s target, else `main`/`master`
/// (local branch preferred over `origin/`). Returns its full ref name and tip.
pub(crate) fn default_base(repo: &gix::Repository) -> Option<(String, gix::ObjectId)> {
    let mut candidates: Vec<String> = Vec::new();
    if let Some(remote) = origin_head_target(repo) {
        // Prefer the local branch of the same name (it may hold unpushed work).
        if let Some(short) = remote.strip_prefix("refs/remotes/origin/") {
            candidates.push(format!("refs/heads/{short}"));
        }
        candidates.push(remote);
    }
    for n in DEFAULT_BRANCH_FALLBACKS {
        candidates.push(format!("refs/heads/{n}"));
        candidates.push(format!("refs/remotes/origin/{n}"));
    }
    candidates.into_iter().find_map(|name| {
        let r = repo.try_find_reference(name.as_str()).ok().flatten()?;
        let id = r.into_fully_peeled_id().ok()?.detach();
        Some((name, id))
    })
}

pub(crate) fn collect_refs_and_tips(repo: &gix::Repository) -> Result<RefsAndTips, GitCraftError> {
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

    for_each_ref(repo, |full_name, reference| {
        let (kind, short_name) = if let Some(name) = full_name.strip_prefix("refs/heads/") {
            (RefKind::LocalBranch, name.to_owned())
        } else if let Some(name) = full_name.strip_prefix("refs/remotes/") {
            if name.ends_with("/HEAD") {
                return;
            }
            (RefKind::RemoteBranch, name.to_owned())
        } else if let Some(name) = full_name.strip_prefix("refs/tags/") {
            (RefKind::Tag, name.to_owned())
        } else {
            return;
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
    })?;

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

    let mut remote_oids: HashMap<String, gix::ObjectId> = HashMap::new();
    let mut remote_head_targets: HashMap<String, String> = HashMap::new();
    let mut local_entries: Vec<(String, String, gix::ObjectId, bool)> = Vec::new();
    let mut remote_entries: Vec<(String, String, gix::ObjectId)> = Vec::new();

    for_each_ref(&repo, |full_name, reference| {
        if let Some(name) = full_name.strip_prefix("refs/heads/") {
            let is_head = head_referent.as_deref() == Some(full_name.as_str());
            if let Ok(peeled) = reference.into_fully_peeled_id() {
                local_entries.push((name.to_owned(), full_name, peeled.detach(), is_head));
            }
        } else if let Some(name) = full_name.strip_prefix("refs/remotes/") {
            if name.ends_with("/HEAD") {
                // e.g. refs/remotes/origin/HEAD -> refs/remotes/origin/main
                if let gix::refs::TargetRef::Symbolic(target) = reference.target() {
                    remote_head_targets
                        .insert(full_name, target.as_bstr().to_str_lossy().into_owned());
                }
                return;
            }
            if let Ok(peeled) = reference.into_fully_peeled_id() {
                let oid = peeled.detach();
                remote_oids.insert(full_name.clone(), oid);
                remote_entries.push((name.to_owned(), full_name, oid));
            }
        }
    })?;

    let config = repo.config_snapshot();
    let mut branches = Vec::with_capacity(local_entries.len() + remote_entries.len());

    // Branches are "merged" when fully contained in origin's default branch.
    let base_ref = remote_head_targets
        .get("refs/remotes/origin/HEAD")
        .cloned()
        .filter(|r| remote_oids.contains_key(r))
        .or_else(|| {
            DEFAULT_BRANCH_FALLBACKS
                .into_iter()
                .map(|n| format!("refs/remotes/origin/{n}"))
                .find(|r| remote_oids.contains_key(r))
        });
    let base_oid = base_ref.as_ref().and_then(|r| remote_oids.get(r)).copied();

    // The local branch the sidebar pins first: the one origin's default branch names,
    // else a local `main`, else `master`.
    let default_local: Option<String> = base_ref
        .as_deref()
        .and_then(|r| r.strip_prefix("refs/remotes/origin/"))
        .map(str::to_owned)
        .into_iter()
        .chain(DEFAULT_BRANCH_FALLBACKS.into_iter().map(str::to_owned))
        .find(|candidate| local_entries.iter().any(|(name, ..)| name == candidate));

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

        let is_default = default_local.as_deref() == Some(name.as_str());
        branches.push(BranchInfo {
            name,
            full_ref,
            is_remote: false,
            is_head,
            target_oid_hex: local_oid.to_hex().to_string(),
            ahead,
            behind,
            is_merged,
            is_default,
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
            is_default: false,
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
    let mut tags = Vec::new();

    for_each_ref(&repo, |full_name, reference| {
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
    })?;

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
