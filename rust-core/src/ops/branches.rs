use crate::{
    git_cli,
    validation::{
        format_ref_display, ref_exists, resolve_commit, validate_ref_arg, validate_remote_arg,
    },
    worktree, BranchConfigEntry, GitCraftError, HeadMove, HeadPosition, MergeType, RefMove,
    RepoSession, ResetMode,
};

impl RepoSession {
    /// Executes a pinned drop plan. Rechecks HEAD, source ref and working state under the
    /// session mutation lock, so another app action cannot retarget a confirmed operation.
    pub fn integrate_drop(
        &self,
        commit: String,
        source_ref: Option<String>,
        action: crate::DropIntegration,
        expected: HeadPosition,
    ) -> Result<Option<HeadMove>, GitCraftError> {
        let oid = gix::ObjectId::from_hex(commit.as_bytes())
            .map_err(GitCraftError::from_display)?
            .to_string();
        self.with_mutation_lock(|| {
            if expected.branch.is_none() || self.head_position().as_ref() != Some(&expected) {
                return Err(GitCraftError::warning(
                    "The branch changed. Start the drag again.",
                ));
            }
            if let Some(source) = source_ref {
                if !(source.starts_with("refs/heads/") || source.starts_with("refs/remotes/"))
                    || self.ref_oid(source).as_deref() != Some(oid.as_str())
                {
                    return Err(GitCraftError::warning(
                        "The source branch changed. Start the drag again.",
                    ));
                }
            }
            let status = self.status()?;
            if status.is_merging
                || status.is_rebasing
                || status.is_cherry_picking
                || status.is_reverting
                || status.has_conflicts
            {
                return Err(GitCraftError::warning("Finish the current operation first"));
            }
            if !status.is_clean {
                return Err(GitCraftError::warning("Commit or stash your changes first"));
            }
            let command = match action {
                crate::DropIntegration::Merge => "merge",
                crate::DropIntegration::Rebase => "rebase",
                crate::DropIntegration::CherryPick => "cherry-pick",
            };
            // Resolve before mutating to reject non-commit objects.
            resolve_commit(&self.path, &oid)?;
            if action == crate::DropIntegration::Merge
                && git_cli::run(&self.path, &["merge-base", "--is-ancestor", &oid, "HEAD"]).is_ok()
            {
                return Err(GitCraftError::warning(format!(
                    "{} is already in the current branch's history, so there is nothing to merge",
                    format_ref_display(&oid)
                )));
            }
            let mut args = vec![command];
            // Undo records only HEAD; never move other branch refs through user config.
            if action == crate::DropIntegration::Rebase {
                args.push("--no-update-refs");
            }
            args.push(&oid);
            git_cli::mutate(&self.path, &args)?;
            Ok(Self::head_move_if_changed(
                Some(expected),
                self.head_position(),
            ))
        })
    }

    pub fn checkout_branch(&self, branch_name: String) -> Result<Option<HeadMove>, GitCraftError> {
        let branch_name = validate_ref_arg(&branch_name)?;
        self.with_mutation_lock(|| {
            let before = self.head_position();
            // Only record undo when tracked index/worktree state is clean; otherwise checkout can
            // absorb staged or modified files into the destination branch in ways a reverse
            // checkout would lose.
            let has_tracked_changes = git_cli::run(
                &self.path,
                &["status", "--porcelain", "--untracked-files=no"],
            )
            .map(|out| !out.trim().is_empty())
            .unwrap_or(true);
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
            } else {
                git_cli::mutate(&self.path, &["checkout", &branch_name, "--"])?;
            }
            if has_tracked_changes {
                return Ok(None);
            }
            let after = self.head_position();
            Ok(Self::head_move_if_changed(before, after))
        })
    }

    pub fn create_branch(
        &self,
        branch_name: String,
        start_point: Option<String>,
        checkout: bool,
    ) -> Result<Option<RefMove>, GitCraftError> {
        let branch_name = validate_ref_arg(&branch_name)?;
        let start_point = start_point.as_deref().map(validate_ref_arg).transpose()?;
        self.with_mutation_lock(|| {
            let mut args = if checkout {
                vec!["checkout", "-b", &branch_name]
            } else {
                vec!["branch", &branch_name]
            };
            if let Some(ref sp) = start_point {
                args.push(sp.as_str());
            }
            git_cli::mutate(&self.path, &args)?;
            if checkout {
                return Ok(None);
            }
            let full_ref = format!("refs/heads/{branch_name}");
            let after_oid = self.ref_oid(full_ref.clone());
            let branch_config = self.read_branch_config(&branch_name);
            Ok(after_oid.map(|oid| RefMove {
                full_ref,
                before_oid: None,
                after_oid: Some(oid),
                branch_config,
            }))
        })
    }

    pub fn delete_branch(
        &self,
        branch_name: String,
        force: bool,
    ) -> Result<Option<RefMove>, GitCraftError> {
        let branch_name = validate_ref_arg(&branch_name)?;
        let flag = if force { "-D" } else { "-d" };
        self.with_mutation_lock(|| {
            let full_ref = format!("refs/heads/{branch_name}");
            let before_oid = self.ref_oid(full_ref.clone());
            let branch_config = self.read_branch_config(&branch_name);
            git_cli::mutate(&self.path, &["branch", flag, &branch_name])?;
            Ok(before_oid.map(|oid| RefMove {
                full_ref,
                before_oid: Some(oid),
                after_oid: None,
                branch_config,
            }))
        })
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
    pub fn fast_forward_branch(
        &self,
        branch_name: String,
    ) -> Result<Option<RefMove>, GitCraftError> {
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
            )?;
            Ok(Some(RefMove {
                full_ref: local_ref,
                before_oid: Some(local_oid),
                after_oid: Some(upstream_oid),
                branch_config: Vec::new(),
            }))
        })
    }

    pub fn merge_branch(&self, branch_name: String) -> Result<Option<HeadMove>, GitCraftError> {
        self.merge_commit(branch_name, MergeType::Default)
    }

    pub fn abort_merge(&self) -> Result<(), GitCraftError> {
        self.abort_op("merge")
    }

    /// Merges `commit` into the checked-out branch, joined as `merge_type` says.
    pub fn merge_commit(
        &self,
        commit: String,
        merge_type: MergeType,
    ) -> Result<Option<HeadMove>, GitCraftError> {
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
            let before = self.head_position();
            let mut args = vec!["merge"];
            match merge_type {
                MergeType::Default => {}
                MergeType::NoFastForward => args.push("--no-ff"),
                MergeType::FastForwardOnly => args.push("--ff-only"),
                MergeType::Squash => args.push("--squash"),
            }
            args.push(commit.as_str());
            git_cli::mutate(&self.path, &args)?;
            let after = self.head_position();
            Ok(Self::head_move_if_changed(before, after))
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
    pub fn rebase_onto(&self, commit: String) -> Result<Option<HeadMove>, GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.mutate_tracking_head(&["rebase", &commit])
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
    /// Returns how HEAD moved, or nil if it didn't (resetting to the commit it is on).
    pub fn reset_to(
        &self,
        commit: String,
        mode: ResetMode,
    ) -> Result<Option<HeadMove>, GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.mutate_tracking_head(&["reset", reset_flag(mode), &commit])
    }

    fn head_move_if_changed(
        before: Option<HeadPosition>,
        after: Option<HeadPosition>,
    ) -> Option<HeadMove> {
        match (before, after) {
            (Some(before), Some(after)) if before != after => Some(HeadMove { before, after }),
            _ => None,
        }
    }

    /// Runs the mutating git command `args` under the mutation lock and reports how it moved
    /// HEAD. Both positions are read under the same lock, so nothing else can slip in between.
    pub(crate) fn mutate_tracking_head(
        &self,
        args: &[&str],
    ) -> Result<Option<HeadMove>, GitCraftError> {
        self.with_mutation_lock(|| {
            let before = self.head_position();
            git_cli::mutate(&self.path, args)?;
            let after = self.head_position();
            Ok(Self::head_move_if_changed(before, after))
        })
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
            // `reset --keep` resets the index even for files the move doesn't touch, which
            // would quietly unstage them.
            if mode == ResetMode::Keep
                && git_cli::run(&self.path, &["diff", "--cached", "--quiet"]).is_err()
            {
                return Err(GitCraftError::message(
                    "Commit or unstage your staged changes first: this would unstage them.",
                ));
            }
            git_cli::mutate(&self.path, &["reset", reset_flag(mode), &target])
        })
    }

    /// Undoes a checkout by switching back to `target`, only while HEAD is still at `expected`
    /// and (when `target` is a branch) that branch still points to `target.oid`.
    pub fn undo_checkout(
        &self,
        expected: HeadPosition,
        target: HeadPosition,
    ) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            if self.head_position().as_ref() != Some(&expected) {
                return Err(GitCraftError::message(
                    "HEAD has changed since then, so there's nothing to undo.",
                ));
            }
            if let Some(branch_ref) = target.branch.as_deref() {
                if self.ref_oid(branch_ref.to_owned()).as_deref() != Some(target.oid.as_str()) {
                    return Err(GitCraftError::message(
                        "The target branch has changed since then, so there's nothing to undo.",
                    ));
                }
                let branch = branch_ref.strip_prefix("refs/heads/").unwrap_or(branch_ref);
                let branch = validate_ref_arg(branch)?;
                git_cli::mutate(&self.path, &["checkout", &branch, "--"])
            } else {
                let oid = validate_ref_arg(&target.oid)?;
                git_cli::mutate(&self.path, &["checkout", "--detach", &oid, "--"])
            }
        })
    }

    /// Resolves `full_ref` (e.g. `refs/heads/main` or `refs/tags/v1.0`) to its direct object OID,
    /// or `None` if it does not exist.
    pub fn ref_oid(&self, full_ref: String) -> Option<String> {
        let full_ref = validate_ref_arg(&full_ref).ok()?;
        git_cli::run(&self.path, &["rev-parse", "--verify", "-q", &full_ref])
            .ok()
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
    }

    /// Undoes a ref creation, deletion, or update on `full_ref`, atomically verifying it still
    /// points to `expected_oid` (or is absent when `expected_oid` is `None`).
    pub fn undo_ref_move(
        &self,
        expected_oid: Option<String>,
        full_ref: String,
        target_oid: Option<String>,
        branch_config: Vec<BranchConfigEntry>,
    ) -> Result<(), GitCraftError> {
        let full_ref = validate_ref_arg(&full_ref)?;
        let expected_oid = expected_oid.as_deref().map(validate_ref_arg).transpose()?;
        let target_oid = target_oid.as_deref().map(validate_ref_arg).transpose()?;
        self.with_mutation_lock(|| {
            if self.ref_oid(full_ref.clone()) != expected_oid {
                return Err(GitCraftError::message(
                    "The ref has changed since then, so there's nothing to undo.",
                ));
            }
            if let Some(branch_name) = full_ref.strip_prefix("refs/heads/") {
                if self.head_position().and_then(|h| h.branch).as_deref() == Some(full_ref.as_str())
                {
                    return Err(GitCraftError::message(
                        "Cannot modify the currently checked-out branch.",
                    ));
                }
                let worktrees = worktree::list_entries(&self.path)?;
                if worktrees
                    .iter()
                    .any(|wt| wt.branch.as_deref() == Some(branch_name))
                {
                    return Err(GitCraftError::message(format!(
                        "Cannot modify '{branch_name}' while it is checked out in another worktree."
                    )));
                }
            }
            let old_arg = expected_oid.as_deref().unwrap_or("");
            if let Some(oid) = target_oid {
                git_cli::mutate(&self.path, &["update-ref", &full_ref, &oid, old_arg])?;
                if expected_oid.is_none() {
                    if let Err(err) = self.restore_branch_config(&branch_config) {
                        let _ = git_cli::mutate(&self.path, &["update-ref", "-d", &full_ref, &oid]);
                        if let Some(branch_name) = full_ref.strip_prefix("refs/heads/") {
                            let _ = self.remove_branch_config(branch_name);
                        }
                        return Err(err);
                    }
                }
                Ok(())
            } else {
                let old_oid = expected_oid
                    .as_deref()
                    .ok_or_else(|| GitCraftError::message("The ref has already been deleted."))?;
                let has_branch_config = full_ref
                    .strip_prefix("refs/heads/")
                    .is_some_and(|b| !self.read_branch_config(b).is_empty());
                git_cli::mutate(&self.path, &["update-ref", "-d", &full_ref, old_oid])?;
                if has_branch_config {
                    if let Some(branch_name) = full_ref.strip_prefix("refs/heads/") {
                        if let Err(err) = self.remove_branch_config(branch_name) {
                            let _ = git_cli::mutate(
                                &self.path,
                                &["update-ref", &full_ref, old_oid, ""],
                            );
                            return Err(err);
                        }
                    }
                }
                Ok(())
            }
        })
    }

    fn read_branch_config(&self, branch_name: &str) -> Vec<BranchConfigEntry> {
        let Ok(output) = git_cli::run(&self.path, &["config", "--local", "--null", "--list"])
        else {
            return Vec::new();
        };
        let prefix = format!("branch.{branch_name}.");
        output
            .split('\0')
            .filter_map(|entry| {
                if entry.is_empty() {
                    return None;
                }
                // Valueless entries (e.g. bare `rebase` in `[branch "x"]`) have no `\n` and
                // mean `true` in Git config.
                let (key, value) = entry.split_once('\n').unwrap_or((entry, "true"));
                key.strip_prefix(&prefix)
                    .filter(|var| !var.contains('.'))
                    .map(|_| BranchConfigEntry {
                        key: key.to_owned(),
                        value: value.to_owned(),
                    })
            })
            .collect()
    }

    fn restore_branch_config(&self, entries: &[BranchConfigEntry]) -> Result<(), GitCraftError> {
        for entry in entries {
            git_cli::mutate(
                &self.path,
                &["config", "--local", "--add", &entry.key, &entry.value],
            )?;
        }
        Ok(())
    }

    fn remove_branch_config(&self, branch_name: &str) -> Result<(), GitCraftError> {
        let section = format!("branch.{branch_name}");
        git_cli::mutate(
            &self.path,
            &["config", "--local", "--remove-section", &section],
        )
    }

    /// Applies `commit`'s changes on top of the checked-out branch. Returns how HEAD moved.
    pub fn cherry_pick(&self, commit: String) -> Result<Option<HeadMove>, GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.mutate_tracking_head(&["cherry-pick", &commit])
    }

    /// Creates a commit that undoes `commit`, keeping git's default message. Returns how HEAD
    /// moved.
    pub fn revert_commit(&self, commit: String) -> Result<Option<HeadMove>, GitCraftError> {
        let commit = validate_ref_arg(&commit)?;
        self.mutate_tracking_head(&["revert", "--no-edit", &commit])
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
