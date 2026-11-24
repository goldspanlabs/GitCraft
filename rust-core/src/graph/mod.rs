mod detail;
mod lanes;
mod refs;

use std::collections::{HashMap, HashSet};

use crate::{CommitRow, CommitSort, GitCraftError, RefBadge, RefKind};

pub use detail::get_commit_detail;
pub use refs::{list_branches, list_tags};

use detail::extract_commit_metadata;
use lanes::{LaneState, RawCommit};
use refs::{collect_refs_and_tips, default_base};

pub fn get_commit_graph(
    sync_repo: &gix::ThreadSafeRepository,
    offset: u32,
    limit: u32,
    search_query: Option<String>,
    sort: CommitSort,
) -> Result<Vec<CommitRow>, GitCraftError> {
    graph_walk(sync_repo, offset, limit, search_query, false, sort)
}

/// Like [`get_commit_graph`], but limited to the checked-out branch's history.
/// Falls back to the full graph when HEAD is detached or no default branch exists.
pub fn get_branch_graph(
    sync_repo: &gix::ThreadSafeRepository,
    offset: u32,
    limit: u32,
    search_query: Option<String>,
    sort: CommitSort,
) -> Result<Vec<CommitRow>, GitCraftError> {
    graph_walk(sync_repo, offset, limit, search_query, true, sort)
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
    let unpushed = unpushed_head_commits(&repo, &refs_by_oid);

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

    let mut lanes = LaneState::default();
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

        let meta = extract_commit_metadata(&commit, false);
        let raw = RawCommit {
            oid,
            parents,
            summary: meta.summary,
            author_name: meta.author_name,
            author_email: meta.author_email,
            timestamp: meta.timestamp,
        };

        let badges = refs_by_oid.get(&oid).cloned().unwrap_or_default();
        let mut row = lanes.assign_commit(&raw, badges);
        row.is_remote_only = is_remote_only;
        row.is_unpushed = unpushed.contains(&oid);

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
    if head.referent_name().is_none() {
        return HashSet::new();
    }
    let Some(head_id) = head.id() else {
        return HashSet::new();
    };
    repo.rev_walk([head_id.detach()])
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
