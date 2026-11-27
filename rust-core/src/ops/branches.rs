use crate::{
    git_cli,
    validation::{
        format_ref_display, ref_exists, resolve_commit, validate_ref_arg, validate_remote_arg,
    },
    worktree, GitCraftError, HeadPosition, MergeType, RepoSession, ResetMode,
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
                return if ref_exists(&self.path, &format!("refs/heads/{local_name}")) {
                    git_cli::mutate(&self.path, &["checkout", local_name, "--"])
                } else {
                    git_cli::mutate(&self.path, &["checkout", "--track", &branch_name])
                };
            }
            git_cli::mutate(&self.path, &["checkout", &branch_name, "--"])
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

    /// Fast-forwards a non-checked-out local branch to its upstream remote-tracking ref
    /// without touching the working tree or hitting the network.
    pub fn fast_forward_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        let branch_name = validate_ref_arg(&branch_name)?;
        self.with_mutation_lock(|| {
            let local_ref = format!("refs/heads/{branch_name}");
            let local_oid = resolve_commit(&self.path, &local_ref).map_err(|_| {
                GitCraftError::message(format!("Branch '{branch_name}' does not exist"))
            })?;

            // Moving a branch that is checked out anywhere would desync that worktree's
            // index and working tree from its HEAD.
            let worktrees = worktree::list_entries(&self.path)?;
            if worktrees
                .iter()
                .any(|wt| wt.branch.as_deref() == Some(branch_name.as_str()))
            {
                return Err(GitCraftError::message(format!(
                    "Cannot fast-forward '{branch_name}' while it is checked out; pull from that checkout instead"
                )));
            }

            // Match `list_branches`'s upstream resolution: configured upstream first,
            // falling back to `refs/remotes/origin/<branch>` if present.
            let upstream_ref = git_cli::run(
                &self.path,
                &[
                    "rev-parse",
                    "--verify",
                    "--symbolic-full-name",
                    &format!("{branch_name}@{{u}}"),
                ],
            )
            .ok()
            .map(|s| s.trim().to_owned())
            .filter(|r| !r.is_empty() && ref_exists(&self.path, r))
            .or_else(|| {
                let fallback = format!("refs/remotes/origin/{branch_name}");
                ref_exists(&self.path, &fallback).then_some(fallback)
            })
            .ok_or_else(|| {
                GitCraftError::message(format!(
                    "Branch '{branch_name}' has no upstream branch to fast-forward to"
                ))
            })?;

            let upstream_oid = resolve_commit(&self.path, &upstream_ref)
                .map_err(GitCraftError::from_display)?;

            if local_oid == upstream_oid {
                return Err(GitCraftError::warning(format!(
                    "'{branch_name}' is already up to date"
                )));
            }

            if git_cli::run(
                &self.path,
                &["merge-base", "--is-ancestor", &local_oid, &upstream_oid],
            )
            .is_err()
            {
                return Err(GitCraftError::message(format!(
                    "Cannot fast-forward '{branch_name}': it has diverged from its upstream"
                )));
            }

            let upstream_display = upstream_ref
                .strip_prefix("refs/remotes/")
                .unwrap_or(&upstream_ref);
            let reflog_msg = format!("fast-forward to {upstream_display}");
            git_cli::mutate(
                &self.path,
                &[
                    "update-ref",
                    "-m",
                    &reflog_msg,
                    &local_ref,
                    &upstream_oid,
                    &local_oid,
                ],
            )
        })
    }

    pub fn merge_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        self.merge_commit(branch_name, MergeType::Default)
    }

    pub fn abort_merge(&self) -> Result<(), GitCraftError> {
        self.abort_op("merge")
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
            git_cli::mutate(&self.path, &args)
        })
    }

    /// Whether merging `commit` into HEAD would conflict. Works without touching the
    /// working tree or index (`git merge-tree --write-tree`, git 2.38+).
    pub fn merge_has_conflicts(&self, commit: String) -> Result<bool, GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        // `merge-tree` exits 1 both for a conflict and for a name it can't resolve, so
        // rule out the second first.
        // Failing to run git at all (including `GitNotFound`) is passed on as it is.
        let resolved = git_cli::run_status(
            &self.path,
            &["rev-parse", "--verify", &format!("{commit}^{{commit}}")],
        )?;
        if !resolved.status.success() {
            let label = format_ref_display(&commit);
            // A killed process says nothing, so fall back to how it exited.
            let detail = match resolved.stderr.trim() {
                "" => resolved.status.to_string(),
                stderr => stderr.to_owned(),
            };
            return Err(GitCraftError::message(format!(
                "Could not resolve {label} to a commit: {detail}"
            )));
        }
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
        self.abort_op("rebase")
    }

    /// Continues a stopped rebase after conflicts were resolved and staged. The editor is
    /// disabled so git keeps the existing commit message instead of waiting on one.
    pub fn continue_rebase(&self) -> Result<(), GitCraftError> {
        self.continue_op("rebase")
    }

    /// Moves the checked-out branch to `commit`, as `git reset --<mode>`.
    pub fn reset_to(&self, commit: String, mode: ResetMode) -> Result<(), GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.mutate(&["reset", reset_flag(mode), &commit])
    }

    /// HEAD's commit and branch, or nil before the first commit.
    pub fn head_position(&self) -> Option<HeadPosition> {
        let oid = git_cli::run(&self.path, &["rev-parse", "--verify", "-q", "HEAD"]).ok()?;
        let branch = git_cli::run(&self.path, &["symbolic-ref", "-q", "HEAD"])
            .ok()
            .map(|b| b.trim().to_owned())
            .filter(|b| !b.is_empty());
        Some(HeadPosition {
            oid: oid.trim().to_owned(),
            branch,
        })
    }

    /// Undoes a reset, cherry-pick or revert by resetting back to `target`, but only while HEAD
    /// is still where that action left it. Anything since (a commit, a checkout, another
    /// reset) makes this refuse and change nothing.
    pub fn undo_head_move(
        &self,
        expected: HeadPosition,
        target: String,
        mode: ResetMode,
    ) -> Result<(), GitCraftError> {
        let target = validate_ref_arg(&target)?;
        self.with_mutation_lock(|| {
            if self.head_position().as_ref() != Some(&expected) {
                return Err(GitCraftError::message(
                    "The branch has changed since then, so there's nothing to undo.",
                ));
            }
            git_cli::mutate(&self.path, &["reset", reset_flag(mode), &target])
        })
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
        self.abort_op("cherry-pick")
    }

    /// Commits a stopped cherry-pick once its conflicts are resolved and staged, keeping the
    /// original commit's message. The editor is skipped, as there is no terminal.
    pub fn continue_cherry_pick(&self) -> Result<(), GitCraftError> {
        self.continue_op("cherry-pick")
    }

    /// Stops a revert that stopped on a conflict, putting the branch and working tree back.
    pub fn abort_revert(&self) -> Result<(), GitCraftError> {
        self.abort_op("revert")
    }

    /// Commits a stopped revert once its conflicts are resolved and staged, keeping git's
    /// default message.
    pub fn continue_revert(&self) -> Result<(), GitCraftError> {
        self.continue_op("revert")
    }

    /// Stops the merge, rebase, cherry-pick or revert `op` that stopped on a conflict.
    fn abort_op(&self, op: &str) -> Result<(), GitCraftError> {
        self.mutate(&[op, "--abort"])
    }

    /// Continues the stopped `op` once its conflicts are resolved and staged. The editor is
    /// disabled, as there is no terminal, so git keeps the message it would have offered.
    fn continue_op(&self, op: &str) -> Result<(), GitCraftError> {
        self.mutate(&["-c", "core.editor=true", op, "--continue"])
    }
}

fn reset_flag(mode: ResetMode) -> &'static str {
    match mode {
        ResetMode::Soft => "--soft",
        ResetMode::Mixed => "--mixed",
        ResetMode::Hard => "--hard",
        ResetMode::Keep => "--keep",
    }
}
