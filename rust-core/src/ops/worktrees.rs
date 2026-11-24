use crate::{
    git_cli, validation::trim_optional_text, worktree, GitCraftError, RepoSession, WorktreeInfo,
};

impl RepoSession {
    pub fn list_worktrees(&self) -> Result<Vec<WorktreeInfo>, GitCraftError> {
        worktree::list(&self.path)
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
