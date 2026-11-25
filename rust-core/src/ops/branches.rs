use crate::{
    git_cli,
    validation::{format_ref_display, ref_exists, validate_ref_arg, validate_remote_arg},
    GitCraftError, MergeType, RepoSession, ResetMode,
};

impl RepoSession {
    pub fn checkout_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        let branch_name = validate_ref_arg(&branch_name)?;
        self.with_mutation_lock(|| {
            let remote_ref = format!("refs/remotes/{branch_name}");
            let local_ref = format!("refs/heads/{branch_name}");
            if ref_exists(&self.path, &remote_ref) && !ref_exists(&self.path, &local_ref) {
                // A remote branch such as origin/x: check out (creating) a local tracking
                // branch instead of leaving HEAD detached.
                let local_name = branch_name
                    .split_once('/')
                    .map_or(branch_name.as_str(), |(_, n)| n);
                if ref_exists(&self.path, &format!("refs/heads/{local_name}")) {
                    git_cli::mutate(&self.path, &["checkout", local_name, "--"])?;
                } else {
                    git_cli::mutate(&self.path, &["checkout", "--track", &branch_name])?;
                }
                return Ok(());
            }
            git_cli::mutate(&self.path, &["checkout", &branch_name, "--"])?;
            Ok(())
        })
    }

    pub fn create_branch(
        &self,
        branch_name: String,
        start_point: Option<String>,
        checkout: bool,
    ) -> Result<(), GitCraftError> {
        let branch_name = validate_ref_arg(&branch_name)?;
        let start_point = start_point.as_deref().map(validate_ref_arg).transpose()?;
        let mut args = if checkout {
            vec!["checkout", "-b", &branch_name]
        } else {
            vec!["branch", &branch_name]
        };
        if let Some(ref sp) = start_point {
            args.push(sp.as_str());
        }
        self.mutate(&args)
    }

    pub fn delete_branch(&self, branch_name: String, force: bool) -> Result<(), GitCraftError> {
        let branch_name = validate_ref_arg(&branch_name)?;
        let flag = if force { "-D" } else { "-d" };
        self.mutate(&["branch", flag, &branch_name])
    }

    /// Deletes `remote/branch` on its remote with `git push <remote> --delete <branch>`.
    /// The local remote-tracking ref is pruned by git as part of the push.
    pub fn delete_remote_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        let branch_name = validate_ref_arg(&branch_name)?;
        let (remote, branch) = branch_name
            .split_once('/')
            .ok_or_else(|| GitCraftError::message("not a remote branch"))?;
        let remote = validate_remote_arg(remote)?;
        let branch = validate_ref_arg(branch)?;
        self.mutate(&["push", &remote, "--delete", &branch])
    }

    pub fn merge_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        self.merge_commit(branch_name, MergeType::Default)
    }

    pub fn abort_merge(&self) -> Result<(), GitCraftError> {
        self.mutate(&["merge", "--abort"])
    }

    /// Merges `commit` into the checked-out branch, joined as `merge_type` says.
    pub fn merge_commit(&self, commit: String, merge_type: MergeType) -> Result<(), GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.with_mutation_lock(|| {
            // `git merge` quietly does nothing (and exits 0) when the commit is already
            // reachable from HEAD; say so instead of looking like the click was ignored.
            if git_cli::run(
                &self.path,
                &["merge-base", "--is-ancestor", &commit, "HEAD"],
            )
            .is_ok()
            {
                let label = format_ref_display(&commit);
                return Err(GitCraftError::warning(format!(
                    "{label} is already in the current branch's history, so there is nothing to merge"
                )));
            }
            let mut args = vec!["merge"];
            match merge_type {
                MergeType::Default => {}
                MergeType::NoFastForward => args.push("--no-ff"),
                MergeType::FastForwardOnly => args.push("--ff-only"),
                MergeType::Squash => args.push("--squash"),
            }
            args.push(commit.as_str());
            git_cli::mutate(&self.path, &args)?;
            Ok(())
        })
    }

    /// Whether merging `commit` into HEAD would conflict. Works without touching the
    /// working tree or index (`git merge-tree --write-tree`, git 2.38+).
    pub fn merge_has_conflicts(&self, commit: String) -> Result<bool, GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        let out = git_cli::run_status(
            &self.path,
            &[
                "merge-tree",
                "--write-tree",
                "--name-only",
                "HEAD",
                commit.as_str(),
            ],
        )?;
        match out.status.code() {
            Some(0) => Ok(false),
            Some(1) => Ok(true),
            _ => Err(GitCraftError::message(out.stderr.trim().to_owned())),
        }
    }

    /// Rebases the checked-out branch onto `commit`.
    pub fn rebase_onto(&self, commit: String) -> Result<(), GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.mutate(&["rebase", &commit])
    }

    pub fn abort_rebase(&self) -> Result<(), GitCraftError> {
        self.mutate(&["rebase", "--abort"])
    }

    /// Continues a stopped rebase after conflicts were resolved and staged. The editor is
    /// disabled so git keeps the existing commit message instead of waiting on one.
    pub fn continue_rebase(&self) -> Result<(), GitCraftError> {
        self.mutate(&["-c", "core.editor=true", "rebase", "--continue"])
    }

    /// Moves the checked-out branch to `commit`, as `git reset --<mode>`.
    pub fn reset_to(&self, commit: String, mode: ResetMode) -> Result<(), GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        let flag = match mode {
            ResetMode::Soft => "--soft",
            ResetMode::Mixed => "--mixed",
            ResetMode::Hard => "--hard",
        };
        self.mutate(&["reset", flag, &commit])
    }

    /// Applies `commit`'s changes on top of the checked-out branch.
    pub fn cherry_pick(&self, commit: String) -> Result<(), GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.mutate(&["cherry-pick", &commit])
    }

    /// Creates a commit that undoes `commit`, keeping git's default message.
    pub fn revert_commit(&self, commit: String) -> Result<(), GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.mutate(&["revert", "--no-edit", &commit])
    }

    /// Stops a cherry-pick that stopped on a conflict, putting the branch and working tree
    /// back as they were before it started.
    pub fn abort_cherry_pick(&self) -> Result<(), GitCraftError> {
        self.mutate(&["cherry-pick", "--abort"])
    }

    /// Commits a stopped cherry-pick once its conflicts are resolved and staged, keeping the
    /// original commit's message. The editor is skipped, as there is no terminal.
    pub fn continue_cherry_pick(&self) -> Result<(), GitCraftError> {
        self.mutate(&["-c", "core.editor=true", "cherry-pick", "--continue"])
    }

    /// Stops a revert that stopped on a conflict, putting the branch and working tree back.
    pub fn abort_revert(&self) -> Result<(), GitCraftError> {
        self.mutate(&["revert", "--abort"])
    }

    /// Commits a stopped revert once its conflicts are resolved and staged, keeping git's
    /// default message.
    pub fn continue_revert(&self) -> Result<(), GitCraftError> {
        self.mutate(&["-c", "core.editor=true", "revert", "--continue"])
    }
}
