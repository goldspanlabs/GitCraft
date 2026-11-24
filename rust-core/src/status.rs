use std::{collections::BTreeSet, path::PathBuf};

use crate::{git_cli, FileChange, GitCraftError, RepoSession, RepoStatus};

impl RepoSession {
    /// Resolves `<git dir>/<name>` via `git rev-parse --git-path`, so it works even when
    /// `.git` is a file (linked worktrees, submodules).
    pub(crate) fn git_path(&self, name: &str) -> Result<PathBuf, GitCraftError> {
        let out = git_cli::run(&self.path, &["rev-parse", "--git-path", name])?;
        let p = PathBuf::from(out.trim());
        Ok(if p.is_absolute() {
            p
        } else {
            self.path.join(p)
        })
    }

    fn git_path_exists(&self, name: &str) -> bool {
        self.git_path(name).map(|p| p.exists()).unwrap_or(false)
    }

    pub fn status(&self) -> Result<RepoStatus, GitCraftError> {
        // -z: NUL-separated, paths are never quoted or escaped (non-ASCII, spaces, quotes).
        let output = git_cli::run(&self.path, &["status", "--porcelain=v1", "-z", "--branch"])?;
        let mut entries = output.split('\0');
        let branch = clean_branch_header(entries.next().unwrap_or_default());

        let mut all_paths = BTreeSet::new();
        let mut staged_files = Vec::new();
        let mut unstaged_files = Vec::new();
        let mut has_conflicts = false;

        while let Some(entry) = entries.next() {
            if entry.len() < 4 {
                continue;
            }
            let bytes = entry.as_bytes();
            let x = bytes[0] as char;
            let y = bytes[1] as char;
            if x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D') {
                has_conflicts = true;
            }
            let path = entry[3..].to_owned();
            // Renames and copies carry the original path as an extra entry; skip it.
            if matches!(x, 'R' | 'C') || matches!(y, 'R' | 'C') {
                entries.next();
            }

            all_paths.insert(path.clone());

            if x != ' ' && x != '?' {
                staged_files.push(FileChange {
                    path: path.clone(),
                    status: x.to_string(),
                    staged: true,
                });
            }
            if y != ' ' {
                let status = if x == '?' && y == '?' {
                    "?".to_owned()
                } else {
                    y.to_string()
                };
                unstaged_files.push(FileChange {
                    path,
                    status,
                    staged: false,
                });
            }
        }

        let is_merging = self.git_path_exists("MERGE_HEAD");
        let is_rebasing =
            self.git_path_exists("rebase-merge") || self.git_path_exists("rebase-apply");
        let files: Vec<String> = all_paths.into_iter().collect();
        Ok(RepoStatus {
            is_clean: staged_files.is_empty() && unstaged_files.is_empty(),
            files,
            staged_files,
            unstaged_files,
            branch,
            is_merging,
            is_rebasing,
            has_conflicts,
        })
    }
}

/// Turns the `## ...` header of `git status --branch` into a plain branch string:
/// "No commits yet on main" -> "main", "HEAD (no branch)" -> "HEAD (detached)".
/// An upstream (`main...origin/main [ahead 1]`) is left for callers to split off.
fn clean_branch_header(header: &str) -> String {
    let header = header.trim_start_matches("## ");
    for prefix in ["No commits yet on ", "Initial commit on "] {
        if let Some(rest) = header.strip_prefix(prefix) {
            return rest.to_owned();
        }
    }
    if header.starts_with("HEAD (no branch)") {
        return "HEAD (detached)".to_owned();
    }
    header.to_owned()
}
