use std::path::Path;

use crate::{
    git_cli,
    validation::{trim_optional_text, validate_ref_arg},
    worktree, GitCraftError, RepoSession, WorktreeInfo,
};

impl RepoSession {
    pub fn list_worktrees(&self) -> Result<Vec<WorktreeInfo>, GitCraftError> {
        worktree::list(&self.path)
    }

    /// Creates a linked worktree at `path`.
    ///
    /// - `detach == true`: checks out `start_point` (or `HEAD`) as a detached HEAD (`branch_name` must be `None`).
    /// - `branch_name == Some(name)`: creates a new branch `name` at `start_point` (or `HEAD`).
    /// - `branch_name == None` and `detach == false`: checks out the existing branch `start_point`.
    pub fn add_worktree(
        &self,
        path: String,
        branch_name: Option<String>,
        start_point: Option<String>,
        detach: bool,
    ) -> Result<(), GitCraftError> {
        let path = path.trim().to_owned();
        if path.is_empty() {
            return Err(GitCraftError::message("worktree path cannot be empty"));
        }
        let branch_name = trim_optional_text(branch_name.as_deref())
            .map(|b| validate_ref_arg(&b))
            .transpose()?;
        let start_point = trim_optional_text(start_point.as_deref())
            .map(|s| validate_ref_arg(&s))
            .transpose()?;

        if detach && branch_name.is_some() {
            return Err(GitCraftError::message(
                "cannot specify both a new branch name and detached HEAD",
            ));
        }
        if !detach && branch_name.is_none() && start_point.is_none() {
            return Err(GitCraftError::message(
                "specify a branch or start point for the new worktree",
            ));
        }

        self.with_mutation_lock(|| {
            let mut args = vec!["worktree", "add"];
            if detach {
                args.push("--detach");
            } else if let Some(ref branch) = branch_name {
                args.push("-b");
                args.push(branch.as_str());
            }
            args.push("--");
            args.push(path.as_str());
            if let Some(ref start) = start_point {
                args.push(start.as_str());
            }
            git_cli::mutate(&self.path, &args)?;
            Ok(())
        })
    }

    /// Removes a linked worktree from disk and unregisters it from git.
    ///
    /// Refuses to remove the primary checkout, unlisted paths, or locked worktrees.
    /// When `force` is false, git refuses if the worktree has modified, staged, or
    /// untracked files. Runs from the primary checkout so removing the session's own
    /// linked worktree never deletes its working directory out from under `git`.
    pub fn remove_worktree(&self, path: String, force: bool) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            let entries = worktree::list_entries(&self.path)?;
            let target = entries.iter().find(|w| w.path == path).ok_or_else(|| {
                GitCraftError::message(format!("{path} is not a worktree of this repository"))
            })?;
            if target.is_main {
                return Err(GitCraftError::message("cannot remove the primary checkout"));
            }
            if target.is_locked {
                return Err(GitCraftError::message(
                    "worktree is locked; unlock it before removing",
                ));
            }
            let primary = entries
                .first()
                .map(|w| Path::new(w.path.as_str()))
                .unwrap_or(&self.path);
            let mut args = vec!["worktree", "remove"];
            if force {
                args.push("--force");
            }
            args.push("--");
            args.push(path.as_str());
            git_cli::mutate(primary, &args)?;
            Ok(())
        })
    }

    /// Locks a linked worktree so git will not prune it, with an optional reason.
    pub fn lock_worktree(&self, path: String, reason: Option<String>) -> Result<(), GitCraftError> {
        let reason = trim_optional_text(reason.as_deref());
        self.with_mutation_lock(|| {
            self.require_listed_worktree(&path)?;
            let mut args = vec!["worktree", "lock"];
            if let Some(ref r) = reason {
                args.push("--reason");
                args.push(r.as_str());
            }
            args.push(path.as_str());
            git_cli::mutate(&self.path, &args)?;
            Ok(())
        })
    }

    pub fn unlock_worktree(&self, path: String) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            self.require_listed_worktree(&path)?;
            git_cli::mutate(&self.path, &["worktree", "unlock", path.as_str()])?;
            Ok(())
        })
    }

    /// Forgets worktrees whose folders no longer exist. Existing folders are never touched.
    pub fn prune_worktrees(&self) -> Result<(), GitCraftError> {
        self.mutate(&["worktree", "prune"])
    }

    /// Rejects paths git does not list as a worktree of this repository.
    fn require_listed_worktree(&self, path: &str) -> Result<(), GitCraftError> {
        if worktree::contains_path(&self.path, path)? {
            Ok(())
        } else {
            Err(GitCraftError::message(format!(
                "{path} is not a worktree of this repository"
            )))
        }
    }
}
