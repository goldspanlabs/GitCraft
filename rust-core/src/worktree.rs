//! Linked worktrees: listing them and the lifecycle operations that do not change
//! branches or history (lock, unlock, prune). Creating and removing worktrees comes later.

use std::path::Path;

use crate::{git_cli, GitCraftError};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorktreeInfo {
    /// Absolute path of the checkout's working directory.
    pub path: String,
    /// Short branch name (`main`, not `refs/heads/main`), or `None` when detached.
    pub branch: Option<String>,
    pub head_oid_hex: String,
    /// The primary checkout that owns `.git/`. It is always listed first by git.
    pub is_main: bool,
    pub is_detached: bool,
    pub is_locked: bool,
    pub lock_reason: Option<String>,
    /// The folder is gone, so git can prune this entry.
    pub is_prunable: bool,
    /// Number of entries in `git status` for this checkout. Zero when the folder is missing.
    pub dirty_count: u32,
}

/// One record of `git worktree list --porcelain -z`, before the checkout-level fields are
/// filled in. Bare entries are dropped because GitCraft only opens non-bare repositories.
#[derive(Default)]
struct Draft {
    path: String,
    head_oid_hex: String,
    branch: Option<String>,
    is_detached: bool,
    is_bare: bool,
    lock: Option<String>,
    is_prunable: bool,
}

impl Draft {
    fn finish(self, is_main: bool) -> Option<WorktreeInfo> {
        if self.is_bare || self.path.is_empty() {
            return None;
        }
        Some(WorktreeInfo {
            path: self.path,
            branch: self.branch,
            head_oid_hex: self.head_oid_hex,
            is_main,
            is_detached: self.is_detached,
            is_locked: self.lock.is_some(),
            lock_reason: self.lock.filter(|reason| !reason.is_empty()),
            is_prunable: self.is_prunable,
            dirty_count: 0,
        })
    }
}

/// Parses `git worktree list --porcelain -z`. Each attribute ends with NUL and each record
/// ends with an extra NUL, so an empty token closes the current record.
pub(crate) fn parse_porcelain(output: &str) -> Vec<WorktreeInfo> {
    let mut records: Vec<Draft> = Vec::new();
    let mut current: Option<Draft> = None;

    for token in output.split('\0') {
        if token.is_empty() {
            if let Some(draft) = current.take() {
                records.push(draft);
            }
            continue;
        }
        let draft = current.get_or_insert_with(Draft::default);
        if let Some(path) = token.strip_prefix("worktree ") {
            draft.path = path.to_owned();
        } else if let Some(oid) = token.strip_prefix("HEAD ") {
            draft.head_oid_hex = oid.to_owned();
        } else if let Some(reference) = token.strip_prefix("branch ") {
            draft.branch = Some(
                reference
                    .strip_prefix("refs/heads/")
                    .unwrap_or(reference)
                    .to_owned(),
            );
        } else if token == "detached" {
            draft.is_detached = true;
        } else if token == "bare" {
            draft.is_bare = true;
        } else if token == "locked" {
            draft.lock.get_or_insert_with(String::new);
        } else if let Some(reason) = token.strip_prefix("locked ") {
            draft.lock = Some(reason.to_owned());
        } else if token == "prunable" || token.starts_with("prunable ") {
            draft.is_prunable = true;
        }
    }
    if let Some(draft) = current.take() {
        records.push(draft);
    }

    records
        .into_iter()
        .enumerate()
        .filter_map(|(index, draft)| draft.finish(index == 0))
        .collect()
}

/// Counts `git status` entries for one checkout. Any failure reads as clean, so one broken
/// checkout never hides the rest of the list.
fn dirty_count(checkout: &Path) -> u32 {
    git_cli::run(
        checkout,
        &["status", "--porcelain=v1", "--untracked-files=normal"],
    )
    .map(|out| out.lines().filter(|line| !line.is_empty()).count() as u32)
    .unwrap_or(0)
}

pub(crate) fn list(repo: &Path) -> Result<Vec<WorktreeInfo>, GitCraftError> {
    let output = git_cli::run(repo, &["worktree", "list", "--porcelain", "-z"])?;
    let mut worktrees = parse_porcelain(&output);
    for worktree in &mut worktrees {
        let checkout = Path::new(&worktree.path);
        if !worktree.is_prunable && checkout.is_dir() {
            worktree.dirty_count = dirty_count(checkout);
        }
    }
    Ok(worktrees)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_main_branch_detached_and_locked_records() {
        let output = "worktree /repo\0HEAD aaa\0branch refs/heads/main\0\0\
                      worktree /repo-feature\0HEAD bbb\0branch refs/heads/feature/x\0\0\
                      worktree /repo-detached\0HEAD ccc\0detached\0\0\
                      worktree /repo-locked\0HEAD ddd\0branch refs/heads/locked\0locked on usb\0\0";
        let parsed = parse_porcelain(output);
        assert_eq!(parsed.len(), 4);

        assert!(parsed[0].is_main);
        assert_eq!(parsed[0].branch.as_deref(), Some("main"));
        assert!(!parsed[1].is_main);
        assert_eq!(parsed[1].branch.as_deref(), Some("feature/x"));
        assert!(parsed[2].is_detached);
        assert_eq!(parsed[2].branch, None);
        assert!(parsed[3].is_locked);
        assert_eq!(parsed[3].lock_reason.as_deref(), Some("on usb"));
    }

    #[test]
    fn bare_lock_without_reason_and_prunable_entries() {
        let output = "worktree /repo\0HEAD aaa\0branch refs/heads/main\0\0\
                      worktree /gone\0HEAD bbb\0branch refs/heads/gone\0locked\0prunable gitdir file points to non-existent location\0\0";
        let parsed = parse_porcelain(output);
        assert_eq!(parsed.len(), 2);
        assert!(parsed[1].is_locked);
        assert_eq!(parsed[1].lock_reason, None);
        assert!(parsed[1].is_prunable);
    }

    #[test]
    fn bare_repository_entries_are_skipped() {
        let output = "worktree /srv/bare.git\0bare\0\0\
                      worktree /work\0HEAD aaa\0branch refs/heads/main\0\0";
        let parsed = parse_porcelain(output);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].path, "/work");
    }

    #[test]
    fn paths_with_spaces_and_newlines_survive() {
        let output = "worktree /tmp/my repo\nwith newline\0HEAD aaa\0detached\0\0";
        let parsed = parse_porcelain(output);
        assert_eq!(parsed[0].path, "/tmp/my repo\nwith newline");
    }

    #[test]
    fn empty_output_gives_no_worktrees() {
        assert!(parse_porcelain("").is_empty());
    }
}
