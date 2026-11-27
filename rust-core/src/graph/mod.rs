mod detail;
mod lanes;
mod refs;

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use gix::bstr::ByteSlice;

use crate::{CommitRow, CommitSort, GitCraftError, GraphIndexSummary, RefBadge, RefKind};

pub use detail::get_commit_detail;
pub use refs::{list_branches, list_tags};

pub(crate) use detail::extract_commit_metadata;
use lanes::{CommitParents, LaneState, RawCommit};
use refs::{collect_refs_and_tips, default_base, upstream_is_gone};

/// A commit SHA abbreviated to seven characters, as git shows it.
pub(crate) fn short_oid(oid_hex: &str) -> String {
    oid_hex.chars().take(7).collect()
}

const FLAG_REMOTE_ONLY: u8 = 1 << 0;
const FLAG_UNPUSHED: u8 = 1 << 1;

/// Compact per-commit entry stored in [`CachedWalk::Indexed`] (~22 B vs ~375 B for `CommitRow`).
#[derive(Clone, Copy)]
struct IndexedCommit {
    oid: gix::ObjectId,
    flags: u8,
}

/// Snapshot [`LaneState`] every this many commits so any page can jump near `offset` and
/// replay at most `CHECKPOINT_STRIDE - 1` commits.
const CHECKPOINT_STRIDE: usize = 256;

/// Upper bound on indexed unfiltered commits (~11 MiB at 22 B/commit).
const MAX_INDEXED_COMMITS: usize = 500_000;

/// Upper bound on cached search-result rows (search walks skip non-matching commits that still
/// affect lane state, so search caches materialized rows directly).
const MAX_CACHED_SEARCH_ROWS: usize = 5_000;

#[derive(Default)]
enum CachedWalk {
    #[default]
    Empty,
    Indexed {
        commits: Vec<IndexedCommit>,
        checkpoints: Vec<LaneState>,
        exhausted: bool,
    },
    Rows {
        rows: Vec<CommitRow>,
        exhausted: bool,
    },
}

/// State from the last graph walk, kept so that paging down doesn't re-walk history from the
/// tips for every page. It holds one walk, identified by `key` (refs, HEAD, query, scope and
/// sort); any change to those starts a new walk.
#[derive(Default)]
pub(crate) struct GraphCache {
    key: String,
    walk: CachedWalk,
}

pub(crate) type SharedGraphCache = Mutex<GraphCache>;

pub fn get_commit_graph(
    sync_repo: &gix::ThreadSafeRepository,
    cache: &SharedGraphCache,
    offset: u32,
    limit: u32,
    search_query: Option<String>,
    sort: CommitSort,
) -> Result<Vec<CommitRow>, GitCraftError> {
    graph_walk(sync_repo, cache, offset, limit, search_query, false, sort)
}

/// Like [`get_commit_graph`], but limited to the checked-out branch's history.
/// Falls back to the full graph when HEAD is detached or no default branch exists.
pub fn get_branch_graph(
    sync_repo: &gix::ThreadSafeRepository,
    cache: &SharedGraphCache,
    offset: u32,
    limit: u32,
    search_query: Option<String>,
    sort: CommitSort,
) -> Result<Vec<CommitRow>, GitCraftError> {
    graph_walk(sync_repo, cache, offset, limit, search_query, true, sort)
}

/// Fingerprint of the repository's refs, HEAD, shallow boundary, scope, and sort order.
/// Callers fetching multiple pages in a batch can compare this before and after each page
/// to detect when refs moved mid-batch.
pub fn graph_state_token(
    sync_repo: &gix::ThreadSafeRepository,
    scoped: bool,
    sort: CommitSort,
) -> Result<u64, GitCraftError> {
    use std::hash::{Hash, Hasher};

    let repo = sync_repo.to_thread_local();
    let (refs_by_oid, mut tips, local_reachable) = collect_refs_and_tips(&repo)?;
    if scoped {
        if let Some((scoped_tips, _)) = branch_scope(&repo) {
            tips = scoped_tips;
        }
    }
    let key = cache_key(
        &repo,
        &refs_by_oid,
        &tips,
        &local_reachable,
        None,
        scoped,
        sort,
    );
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    key.hash(&mut hasher);
    Ok(hasher.finish())
}

/// Walk and index the unfiltered commit graph (up to `MAX_INDEXED_COMMITS`) into [`GraphCache`]
/// without materializing `CommitRow` text or edges. Returns the indexed count and whether the
/// history is exhausted.
pub fn index_commit_graph(
    sync_repo: &gix::ThreadSafeRepository,
    cache: &SharedGraphCache,
    scoped: bool,
    sort: CommitSort,
) -> Result<GraphIndexSummary, GitCraftError> {
    let mut repo = sync_repo.to_thread_local();
    repo.object_cache_size_if_unset(4 * 1024 * 1024);
    let (refs_by_oid, mut tips, mut local_reachable) = collect_refs_and_tips(&repo)?;
    if tips.is_empty() {
        return Ok(GraphIndexSummary {
            total_count: 0,
            exhausted: true,
        });
    }
    let mut hidden: Vec<gix::ObjectId> = Vec::new();
    if scoped {
        if let Some((scoped_tips, scoped_hidden)) = branch_scope(&repo) {
            tips = scoped_tips;
            hidden = scoped_hidden;
        }
    }

    let key = cache_key(
        &repo,
        &refs_by_oid,
        &tips,
        &local_reachable,
        None,
        scoped,
        sort,
    );

    if let Ok(guard) = cache.lock() {
        if guard.key == key {
            if let CachedWalk::Indexed {
                commits, exhausted, ..
            } = &guard.walk
            {
                if *exhausted || commits.len() >= MAX_INDEXED_COMMITS {
                    return Ok(GraphIndexSummary {
                        total_count: commits.len() as u32,
                        exhausted: *exhausted,
                    });
                }
            }
        }
    }

    let has_local_refs = !local_reachable.is_empty();
    let unpushed = unpushed_head_commits(&repo, &refs_by_oid);

    let ids: Box<dyn Iterator<Item = Result<gix::ObjectId, GitCraftError>>> = match sort {
        CommitSort::ByDate => {
            let walk = repo
                .rev_walk(tips)
                .with_hidden(hidden)
                .sorting(gix::revision::walk::Sorting::ByCommitTime(
                    gix::traverse::commit::simple::CommitTimeOrder::NewestFirst,
                ))
                .all()
                .map_err(GitCraftError::from_display)?;
            Box::new(walk.map(|entry| {
                entry
                    .map(|info| info.id)
                    .map_err(GitCraftError::from_display)
            }))
        }
        CommitSort::Topological => {
            let commit_graph = repo.commit_graph_if_enabled().ok().flatten();
            let topo =
                gix::traverse::commit::topo::Builder::from_iters(&repo.objects, tips, Some(hidden))
                    .with_commit_graph(commit_graph)
                    .sorting(gix::traverse::commit::topo::Sorting::TopoOrder)
                    .parents(gix::traverse::commit::Parents::All)
                    .build()
                    .map_err(GitCraftError::from_display)?;
            Box::new(topo.map(|entry| {
                entry
                    .map(|info| info.id)
                    .map_err(GitCraftError::from_display)
            }))
        }
    };

    let mut lanes = LaneState::default();
    let mut indexed_commits: Vec<IndexedCommit> = Vec::new();
    let mut checkpoints: Vec<LaneState> = Vec::new();
    let mut exhausted = true;

    for entry in ids {
        if indexed_commits.len() >= MAX_INDEXED_COMMITS {
            exhausted = false;
            break;
        }
        let oid = entry?;
        let commit = repo.find_commit(oid).map_err(GitCraftError::from_display)?;
        let parents = CommitParents::from_iter(commit.parent_ids().map(|id| id.detach()));

        let is_local = !has_local_refs || local_reachable.remove(&oid);
        if is_local {
            for &p in parents.iter() {
                local_reachable.insert(p);
            }
        }

        let idx = indexed_commits.len();
        if idx.is_multiple_of(CHECKPOINT_STRIDE) {
            checkpoints.push(lanes.clone());
        }
        let mut flags = 0u8;
        if !is_local {
            flags |= FLAG_REMOTE_ONLY;
        }
        if unpushed.contains(&oid) {
            flags |= FLAG_UNPUSHED;
        }
        indexed_commits.push(IndexedCommit { oid, flags });
        lanes.advance_commit(oid, &parents);
    }

    let total_count = indexed_commits.len() as u32;
    if let Ok(mut guard) = cache.lock() {
        *guard = GraphCache {
            key,
            walk: CachedWalk::Indexed {
                commits: indexed_commits,
                checkpoints,
                exhausted,
            },
        };
    }
    Ok(GraphIndexSummary {
        total_count,
        exhausted,
    })
}

/// Finds the 0-based row index of `oid_hex` in the unfiltered graph, indexing the graph first
/// if it isn't already cached.
pub fn find_commit_index(
    sync_repo: &gix::ThreadSafeRepository,
    cache: &SharedGraphCache,
    oid_hex: &str,
    scoped: bool,
    sort: CommitSort,
) -> Result<Option<u32>, GitCraftError> {
    let Ok(target_oid) = gix::ObjectId::from_hex(oid_hex.as_bytes()) else {
        return Ok(None);
    };

    let repo = sync_repo.to_thread_local();
    let (refs_by_oid, mut tips, local_reachable) = collect_refs_and_tips(&repo)?;
    if tips.is_empty() {
        return Ok(None);
    }
    if scoped {
        if let Some((scoped_tips, _)) = branch_scope(&repo) {
            tips = scoped_tips;
        }
    }
    let key = cache_key(
        &repo,
        &refs_by_oid,
        &tips,
        &local_reachable,
        None,
        scoped,
        sort,
    );

    if let Ok(guard) = cache.lock() {
        if guard.key == key {
            if let CachedWalk::Indexed {
                commits, exhausted, ..
            } = &guard.walk
            {
                if let Some(idx) = commits.iter().position(|c| c.oid == target_oid) {
                    return Ok(Some(idx as u32));
                }
                if *exhausted || commits.len() >= MAX_INDEXED_COMMITS {
                    return Ok(None);
                }
            }
        }
    }

    index_commit_graph(sync_repo, cache, scoped, sort)?;

    if let Ok(guard) = cache.lock() {
        if guard.key == key {
            if let CachedWalk::Indexed { commits, .. } = &guard.walk {
                return Ok(commits
                    .iter()
                    .position(|c| c.oid == target_oid)
                    .map(|idx| idx as u32));
            }
        }
    }
    Ok(None)
}

/// Tips and hidden commits for the branch view, or `None` when the full graph should be
/// shown (detached HEAD, or no default branch to compare against). The view walks only from
/// the checked-out branch, so it shows that branch's whole history and leaves out other
/// branches. This holds on the default branch too.
fn branch_scope(repo: &gix::Repository) -> Option<(Vec<gix::ObjectId>, Vec<gix::ObjectId>)> {
    let head = repo.head().ok()?;
    head.referent_name()?;
    let head_id = head.id()?.detach();
    default_base(repo)?;
    Some((vec![head_id], Vec::new()))
}

fn graph_walk(
    sync_repo: &gix::ThreadSafeRepository,
    cache: &SharedGraphCache,
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
    let query = search_query
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty());

    let start = offset as usize;
    let target_count = offset.saturating_add(limit) as usize;
    let key = cache_key(
        &repo,
        &refs_by_oid,
        &tips,
        &local_reachable,
        query.as_deref(),
        scoped,
        sort,
    );
    let mut cached_len = 0;
    if let Ok(mut guard) = cache.lock() {
        if guard.key == key {
            match &guard.walk {
                CachedWalk::Indexed {
                    commits,
                    checkpoints,
                    exhausted,
                } => {
                    if commits.len() >= target_count || *exhausted {
                        return materialize_indexed_page(
                            &repo,
                            &refs_by_oid,
                            commits,
                            checkpoints,
                            offset,
                            limit,
                        );
                    }
                    cached_len = commits.len();
                }
                CachedWalk::Rows { rows, exhausted } => {
                    if rows.len() >= target_count || *exhausted {
                        return Ok(page(rows, offset, limit));
                    }
                    cached_len = rows.len();
                }
                CachedWalk::Empty => {}
            }
        }
        // Drop the previous walk before allocating a new one so stale cached data doesn't
        // coexist in memory with the replacement walk.
        *guard = GraphCache::default();
    }

    // Walking further than asked, in steps that double, keeps the total cost of paging down
    // proportional to the history shown rather than to pages times history.
    let cache_cap = if query.is_none() {
        MAX_INDEXED_COMMITS
    } else {
        MAX_CACHED_SEARCH_ROWS
    };
    let will_cache = target_count <= cache_cap;
    let walk_count = if will_cache {
        target_count
            .max(cached_len.saturating_mul(2))
            .min(cache_cap)
    } else {
        target_count
    };
    let use_index = query.is_none() && will_cache;

    let has_local_refs = !local_reachable.is_empty();
    let unpushed = unpushed_head_commits(&repo, &refs_by_oid);

    let ids: Box<dyn Iterator<Item = Result<gix::ObjectId, GitCraftError>>> = match sort {
        CommitSort::ByDate => {
            let walk = repo
                .rev_walk(tips)
                .with_hidden(hidden)
                .sorting(gix::revision::walk::Sorting::ByCommitTime(
                    gix::traverse::commit::simple::CommitTimeOrder::NewestFirst,
                ))
                .all()
                .map_err(GitCraftError::from_display)?;
            Box::new(walk.map(|entry| {
                entry
                    .map(|info| info.id)
                    .map_err(GitCraftError::from_display)
            }))
        }
        CommitSort::Topological => {
            // Like `git log --topo-order`: a parent never appears before its children and
            // commits of one line of history are not interleaved with another's.
            let commit_graph = repo.commit_graph_if_enabled().ok().flatten();
            let topo =
                gix::traverse::commit::topo::Builder::from_iters(&repo.objects, tips, Some(hidden))
                    .with_commit_graph(commit_graph)
                    .sorting(gix::traverse::commit::topo::Sorting::TopoOrder)
                    .parents(gix::traverse::commit::Parents::All)
                    .build()
                    .map_err(GitCraftError::from_display)?;
            Box::new(topo.map(|entry| {
                entry
                    .map(|info| info.id)
                    .map_err(GitCraftError::from_display)
            }))
        }
    };

    let mut lanes = LaneState::default();
    let mut indexed_commits: Vec<IndexedCommit> = Vec::new();
    let mut checkpoints: Vec<LaneState> = Vec::new();
    let mut cached_rows: Vec<CommitRow> = Vec::new();
    let mut page_out: Vec<CommitRow> = Vec::new();
    let mut matched_count: usize = 0;

    // Set when the walk fails after the requested range is already filled. The extra rows
    // were only a lookahead for the cache, so the page is still returned, but the partial
    // walk is not cached.
    let mut lookahead_failed = false;

    for entry in ids {
        let step = entry.and_then(|oid| {
            repo.find_commit(oid)
                .map(|commit| (oid, commit))
                .map_err(GitCraftError::from_display)
        });
        let (oid, commit) = match step {
            Ok(found) => found,
            Err(_) if matched_count >= target_count => {
                lookahead_failed = true;
                break;
            }
            Err(e) => return Err(e),
        };

        let parents = CommitParents::from_iter(commit.parent_ids().map(|id| id.detach()));

        // Removing visited OIDs keeps `local_reachable` proportional to the active branch
        // frontier instead of growing with total walked commits.
        let is_local = !has_local_refs || local_reachable.remove(&oid);
        if is_local {
            for &p in parents.iter() {
                local_reachable.insert(p);
            }
        }

        if let Some(q) = query.as_deref() {
            if !commit_matches_query(&commit, oid, q) {
                lanes.advance_commit(oid, &parents);
                continue;
            }
        }

        let idx = matched_count;
        let is_remote_only = !is_local;
        let is_unpushed = unpushed.contains(&oid);

        if use_index {
            if idx.is_multiple_of(CHECKPOINT_STRIDE) {
                checkpoints.push(lanes.clone());
            }
            let mut flags = 0u8;
            if is_remote_only {
                flags |= FLAG_REMOTE_ONLY;
            }
            if is_unpushed {
                flags |= FLAG_UNPUSHED;
            }
            indexed_commits.push(IndexedCommit { oid, flags });

            if idx >= start && idx < target_count {
                let row = build_commit_row(
                    &commit,
                    oid,
                    parents,
                    &mut lanes,
                    &refs_by_oid,
                    is_remote_only,
                    is_unpushed,
                );
                page_out.push(row);
            } else {
                lanes.advance_commit(oid, &parents);
            }
        } else if will_cache {
            // Search walk within cache cap: materialize rows for caching.
            let row = build_commit_row(
                &commit,
                oid,
                parents,
                &mut lanes,
                &refs_by_oid,
                is_remote_only,
                is_unpushed,
            );
            cached_rows.push(row);
        } else if idx < start {
            lanes.advance_commit(oid, &parents);
        } else {
            let row = build_commit_row(
                &commit,
                oid,
                parents,
                &mut lanes,
                &refs_by_oid,
                is_remote_only,
                is_unpushed,
            );
            page_out.push(row);
        }

        matched_count += 1;
        if matched_count >= walk_count {
            break;
        }
    }

    if !will_cache {
        return Ok(page_out);
    }

    let exhausted = matched_count < walk_count;
    let out = if use_index {
        page_out
    } else {
        page(&cached_rows, offset, limit)
    };
    if lookahead_failed {
        return Ok(out);
    }
    if let Ok(mut guard) = cache.lock() {
        *guard = GraphCache {
            key,
            walk: if use_index {
                CachedWalk::Indexed {
                    commits: indexed_commits,
                    checkpoints,
                    exhausted,
                }
            } else {
                CachedWalk::Rows {
                    rows: cached_rows,
                    exhausted,
                }
            },
        };
    }
    Ok(out)
}

fn build_commit_row(
    commit: &gix::Commit<'_>,
    oid: gix::ObjectId,
    parents: CommitParents,
    lanes: &mut LaneState,
    refs_by_oid: &HashMap<gix::ObjectId, Vec<RefBadge>>,
    is_remote_only: bool,
    is_unpushed: bool,
) -> CommitRow {
    let meta = extract_commit_metadata(commit, false);
    let raw = RawCommit {
        oid,
        parents,
        summary: meta.summary,
        author_name: meta.author_name,
        author_email: meta.author_email,
        timestamp: meta.timestamp,
    };
    let badges = refs_by_oid.get(&oid).cloned().unwrap_or_default();
    let mut row = lanes.assign_commit(raw, badges);
    row.is_remote_only = is_remote_only;
    row.is_unpushed = is_unpushed;
    row
}

fn materialize_indexed_page(
    repo: &gix::Repository,
    refs_by_oid: &HashMap<gix::ObjectId, Vec<RefBadge>>,
    commits: &[IndexedCommit],
    checkpoints: &[LaneState],
    offset: u32,
    limit: u32,
) -> Result<Vec<CommitRow>, GitCraftError> {
    let start = offset as usize;
    if start >= commits.len() || limit == 0 {
        return Ok(Vec::new());
    }
    let end = start.saturating_add(limit as usize).min(commits.len());
    let cp_idx = start / CHECKPOINT_STRIDE;
    let cp_start = cp_idx * CHECKPOINT_STRIDE;
    let mut lanes = checkpoints[cp_idx].clone();

    for entry in &commits[cp_start..start] {
        let commit = repo
            .find_commit(entry.oid)
            .map_err(GitCraftError::from_display)?;
        let parents = CommitParents::from_iter(commit.parent_ids().map(|id| id.detach()));
        lanes.advance_commit(entry.oid, &parents);
    }

    let mut out = Vec::with_capacity(end - start);
    for entry in &commits[start..end] {
        let commit = repo
            .find_commit(entry.oid)
            .map_err(GitCraftError::from_display)?;
        let parents = CommitParents::from_iter(commit.parent_ids().map(|id| id.detach()));
        let row = build_commit_row(
            &commit,
            entry.oid,
            parents,
            &mut lanes,
            refs_by_oid,
            (entry.flags & FLAG_REMOTE_ONLY) != 0,
            (entry.flags & FLAG_UNPUSHED) != 0,
        );
        out.push(row);
    }
    Ok(out)
}

/// Matches a commit against an already-lowercased search query without allocating `String`s
/// for the common ASCII case.
fn commit_matches_query(commit: &gix::Commit<'_>, oid: gix::ObjectId, query_lower: &str) -> bool {
    let raw_msg = commit.message_raw_sloppy();
    let first_line = raw_msg
        .split(|&b| b == b'\n')
        .next()
        .unwrap_or_default()
        .trim();
    if bytes_contain_ignore_case(first_line, query_lower) {
        return true;
    }
    if let Ok(author) = commit.author() {
        if bytes_contain_ignore_case(author.name.as_ref(), query_lower) {
            return true;
        }
    }
    let (hex_buf, hex_len) = oid_hex_bytes(oid);
    bytes_contain_ignore_case(&hex_buf[..hex_len], query_lower)
}

fn bytes_contain_ignore_case(haystack: &[u8], needle_lower: &str) -> bool {
    if needle_lower.is_ascii() && haystack.is_ascii() {
        let needle = needle_lower.as_bytes();
        if needle.is_empty() {
            return true;
        }
        return haystack
            .windows(needle.len())
            .any(|window| window.eq_ignore_ascii_case(needle));
    }
    haystack
        .to_str_lossy()
        .to_lowercase()
        .contains(needle_lower)
}

fn oid_hex_bytes(oid: gix::ObjectId) -> ([u8; 64], usize) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let raw = oid.as_bytes();
    let mut buf = [0u8; 64];
    for (i, &b) in raw.iter().enumerate() {
        buf[i * 2] = HEX[(b >> 4) as usize];
        buf[i * 2 + 1] = HEX[(b & 0x0f) as usize];
    }
    (buf, raw.len() * 2)
}

fn page(rows: &[CommitRow], offset: u32, limit: u32) -> Vec<CommitRow> {
    rows.iter()
        .skip(offset as usize)
        .take(limit as usize)
        .cloned()
        .collect()
}

/// Everything the rows depend on besides the commits themselves, which never change: the
/// refs (badges, tips, which commits count as local), HEAD, whether the upstream is gone,
/// and how the walk was asked for.
fn cache_key(
    repo: &gix::Repository,
    refs_by_oid: &HashMap<gix::ObjectId, Vec<RefBadge>>,
    tips: &[gix::ObjectId],
    local_tips: &HashSet<gix::ObjectId>,
    query: Option<&str>,
    scoped: bool,
    sort: CommitSort,
) -> String {
    let mut refs: Vec<String> = refs_by_oid
        .iter()
        .map(|(oid, badges)| format!("{oid}{badges:?}"))
        .collect();
    refs.sort();
    // Which commits count as local also depends on checked-out detached worktrees, whose
    // HEAD can sit on a commit that no ref names.
    let mut local: Vec<String> = local_tips.iter().map(|oid| oid.to_string()).collect();
    local.sort();
    // Deepening or unshallowing a clone adds history without touching any ref.
    let shallow = std::fs::metadata(repo.common_dir().join("shallow"))
        .ok()
        .map(|m| (m.len(), m.modified().ok()));
    let head = repo.head().ok();
    let head_state = head.as_ref().map(|h| {
        let name = refs::head_ref_name(h);
        let gone = name
            .as_deref()
            .and_then(|n| n.strip_prefix("refs/heads/"))
            .is_some_and(|b| upstream_is_gone(repo, b));
        (name, h.id().map(|id| id.detach()), gone)
    });
    format!("{refs:?}|{tips:?}|{local:?}|{shallow:?}|{head_state:?}|{query:?}|{scoped}|{sort:?}")
}

/// Upper bound on how many unpushed commits we mark, so a never-pushed branch with a huge
/// history doesn't cost a full walk on every graph query.
const MAX_UNPUSHED_MARKED: usize = 5_000;

/// Commits on the checked-out branch that no remote branch contains. Empty when HEAD is
/// detached or the repository has no remote branches at all (otherwise everything would
/// count as unpushed, which is just noise).
fn unpushed_head_commits(
    repo: &gix::Repository,
    refs_by_oid: &HashMap<gix::ObjectId, Vec<RefBadge>>,
) -> HashSet<gix::ObjectId> {
    let remote_tips: Vec<gix::ObjectId> = refs_by_oid
        .iter()
        .filter(|(_, badges)| badges.iter().any(|b| b.kind == RefKind::RemoteBranch))
        .map(|(oid, _)| *oid)
        .collect();
    if remote_tips.is_empty() {
        return HashSet::new();
    }
    let Ok(head) = repo.head() else {
        return HashSet::new();
    };
    let Some(branch) = refs::head_ref_name(&head) else {
        return HashSet::new();
    };
    // A deleted upstream usually means the branch was merged (and perhaps squashed, so its
    // commits never reach a remote branch). Marking them unpushed would be misleading.
    if let Some(name) = branch.strip_prefix("refs/heads/") {
        if upstream_is_gone(repo, name) {
            return HashSet::new();
        }
    }
    let Some(head_id) = head.id() else {
        return HashSet::new();
    };
    let head_oid = head_id.detach();
    // Fast path: when HEAD already matches any remote tip, nothing on HEAD is unpushed.
    if remote_tips.contains(&head_oid) {
        return HashSet::new();
    }
    repo.rev_walk([head_oid])
        .with_hidden(remote_tips)
        .all()
        .map(|walk| {
            walk.filter_map(|entry| entry.ok().map(|info| info.id))
                .take(MAX_UNPUSHED_MARKED)
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

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

        let all_rows = get_commit_graph(
            &sync_repo,
            &SharedGraphCache::default(),
            0,
            50,
            None,
            CommitSort::ByDate,
        )
        .unwrap();
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

        let page2 = get_commit_graph(
            &sync_repo,
            &SharedGraphCache::default(),
            1,
            1,
            None,
            CommitSort::ByDate,
        )
        .unwrap();
        assert_eq!(page2.len(), 1);
        assert_eq!(page2[0].oid_hex, all_rows[1].oid_hex);

        let filtered = get_commit_graph(
            &sync_repo,
            &SharedGraphCache::default(),
            0,
            10,
            Some("UI feature".into()),
            CommitSort::ByDate,
        )
        .unwrap();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].summary, "Add UI feature");

        let branches = list_branches(p, &sync_repo).unwrap();
        assert_eq!(branches.len(), 2);
        assert!(branches.iter().any(|b| b.name == "main" && b.is_head));
        assert!(branches
            .iter()
            .any(|b| b.name == "feature/ui" && !b.is_head));

        let tags = list_tags(&sync_repo).unwrap();
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].name, "v0.1.0");
    }

    #[test]
    fn unicode_haystack_matches_ascii_query_case_insensitively() {
        assert!(bytes_contain_ignore_case(
            "Kelvin scale".as_bytes(),
            "kelvin"
        ));
        assert!(bytes_contain_ignore_case("İpek".as_bytes(), "i"));
        assert!(bytes_contain_ignore_case(b"Add UI Feature", "ui feature"));
        assert!(!bytes_contain_ignore_case("İpek".as_bytes(), "xyz"));
    }
}
