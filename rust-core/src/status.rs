use std::{collections::BTreeSet, path::PathBuf};

use crate::{git_cli, FileChange, GitCraftError, RepoSession, RepoStatus};

impl RepoSession {
    /// Resolves `<git dir>/<name>` via `git rev-parse --git-path`, so it works even when
    /// `.git` is a file (linked worktrees, submodules). Only the final newline is dropped, so a
    /// path that itself contains a newline stays in one piece.
    pub(crate) fn git_path(&self, name: &str) -> Result<PathBuf, GitCraftError> {
        let out = git_cli::run(&self.path, &["rev-parse", "--git-path", name])?;
        Ok(self.resolve_git_path(out.strip_suffix('\n').unwrap_or(&out)))
    }

    /// Resolves several names in one git call. If the output doesn't split into exactly one
    /// line per name (a path containing a newline), falls back to one call per name.
    pub(crate) fn git_paths(&self, names: &[&str]) -> Result<Vec<PathBuf>, GitCraftError> {
        let mut args = vec!["rev-parse"];
        for name in names {
            args.push("--git-path");
            args.push(name);
        }
        let out = git_cli::run(&self.path, &args)?;
        let lines: Vec<&str> = out.lines().collect();
        if lines.len() == names.len() {
            return Ok(lines
                .into_iter()
                .map(|l| self.resolve_git_path(l))
                .collect());
        }
        names.iter().map(|name| self.git_path(name)).collect()
    }

    fn resolve_git_path(&self, line: &str) -> PathBuf {
        let p = PathBuf::from(line);
        if p.is_absolute() {
            p
        } else {
            self.path.join(p)
        }
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

        // One git call for all in-progress markers instead of one per marker.
        let markers = self
            .git_paths(&[
                "MERGE_HEAD",
                "rebase-merge",
                "rebase-apply",
                "CHERRY_PICK_HEAD",
                "REVERT_HEAD",
            ])
            .unwrap_or_default();
        let exists = |i: usize| markers.get(i).is_some_and(|p| p.exists());
        let is_merging = exists(0);
        let is_rebasing = exists(1) || exists(2);
        let is_cherry_picking = exists(3);
        let is_reverting = exists(4);
        let files: Vec<String> = all_paths.into_iter().collect();
        Ok(RepoStatus {
            is_clean: staged_files.is_empty() && unstaged_files.is_empty(),
            files,
            staged_files,
            unstaged_files,
            branch,
            is_merging,
            is_rebasing,
            is_cherry_picking,
            is_reverting,
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
