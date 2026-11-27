use super::sync::PorcelainRef;
use crate::{
    git_cli,
    validation::{ref_exists, resolve_default_remote, validate_ref_arg, validate_remote_arg},
    ForcePushPlan, GitCraftError, PushCommit, PushResult, RepoSession,
};

const HEAD_MOVED: &str = "The branch has changed since then. Push again.";
const REMOTE_MOVED: &str = "The remote has new commits. Fetch, then try again.";

impl RepoSession {
    /// The force push that publishing the checked-out branch needs, because commits that are on
    /// the remote were rewritten here. `None` means an ordinary push will do. Fails when the
    /// remote holds commits this branch never had. Uses what was last fetched.
    pub fn force_push_plan(&self) -> Result<Option<ForcePushPlan>, GitCraftError> {
        let Some(head) = self.head_position() else {
            return Ok(None);
        };
        let Some(branch) = head
            .branch
            .as_deref()
            .and_then(|b| b.strip_prefix("refs/heads/"))
            .map(str::to_owned)
        else {
            return Ok(None);
        };
        let remote = self.push_remote(&branch);
        let Some(tracking) = self.push_tracking_ref(&branch, &remote) else {
            return Ok(None);
        };
        let Some(name) = tracking.strip_prefix(&format!("refs/remotes/{remote}/")) else {
            return Ok(None);
        };
        let tip = git_cli::run(&self.path, &["rev-parse", "--verify", &tracking])?
            .trim()
            .to_owned();
        let ancestry = git_cli::run_status(
            &self.path,
            &["merge-base", "--is-ancestor", &tip, &head.oid],
        )?;
        match ancestry.status.code() {
            Some(0) => return Ok(None),
            Some(1) => {}
            _ => return Err(GitCraftError::message(ancestry.stderr.trim().to_owned())),
        }
        let destination = format!("{remote}/{name}");
        if !self.was_in_branch(&branch, &tip)? {
            return Err(GitCraftError::message(format!(
                "{destination} has commits your branch doesn't. Pull first."
            )));
        }
        let is_default_branch = self
            .list_branches()?
            .iter()
            .any(|b| b.is_remote && b.is_default && b.name == destination);
        Ok(Some(ForcePushPlan {
            removed: self.commits_between(&head.oid, &tip)?,
            added: self.commits_between(&tip, &head.oid)?,
            destination_ref: format!("refs/heads/{name}"),
            expected_remote_oid: tip,
            branch,
            remote,
            destination,
            head,
            is_default_branch,
        }))
    }

    /// Replaces the remote branch with the checked-out one, as planned. Only overwrites the
    /// remote commit the plan names, and only while HEAD is where the plan saw it.
    pub fn force_push(&self, plan: ForcePushPlan) -> Result<PushResult, GitCraftError> {
        let remote = validate_remote_arg(&plan.remote)?;
        let branch = validate_ref_arg(&plan.branch)?;
        let destination_ref = validate_ref_arg(&plan.destination_ref)?;
        let expected = validate_ref_arg(&plan.expected_remote_oid)?;
        self.with_mutation_lock(|| {
            if self.head_position().as_ref() != Some(&plan.head) {
                return Err(GitCraftError::message(HEAD_MOVED));
            }
            let lease = format!("--force-with-lease={destination_ref}:{expected}");
            let refspec = format!("refs/heads/{branch}:{destination_ref}");
            let output = git_cli::mutate_status(
                &self.path,
                &["push", "--porcelain", &lease, &remote, &refspec],
            )?;
            let status = PorcelainRef::find(&output.stdout, &branch);
            if !output.status.success() {
                let rejection = status.filter(|s| s.flag == '!').map(|s| s.summary);
                if rejection
                    .as_deref()
                    .is_some_and(|s| s.contains("stale info"))
                {
                    return Err(GitCraftError::message(REMOTE_MOVED));
                }
                let message = [Some(output.stderr.trim().to_owned()), rejection]
                    .into_iter()
                    .flatten()
                    .filter(|part| !part.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n");
                return Err(GitCraftError::message(if message.is_empty() {
                    format!("git push failed ({})", output.status)
                } else {
                    message
                }));
            }
            let flag = status.as_ref().map(|s| s.flag);
            let commits = match &status {
                Some(s) if matches!(s.flag, ' ' | '+') => self.count_range(&s.summary),
                _ => 0,
            };
            Ok(PushResult {
                branch,
                destination: plan.destination,
                commits,
                published: flag == Some('*'),
                up_to_date: flag == Some('='),
                forced: flag == Some('+'),
                included_branch: status.is_some(),
            })
        })
    }

    /// The remote-tracking ref a push of `branch` updates, if it exists here. A branch with no
    /// upstream uses the same-named branch of `remote`.
    fn push_tracking_ref(&self, branch: &str, remote: &str) -> Option<String> {
        let resolve = |rev: &str| {
            git_cli::run(
                &self.path,
                &["rev-parse", "--verify", "--symbolic-full-name", rev],
            )
            .ok()
            .map(|r| r.trim().to_owned())
            .filter(|r| !r.is_empty())
        };
        let tracking = match resolve(&format!("{branch}@{{push}}")) {
            Some(tracking) => tracking,
            // With an upstream, git couldn't say where a push goes; let the push explain.
            None if resolve(&format!("{branch}@{{u}}")).is_some() => return None,
            None => {
                let remote = if remote.is_empty() {
                    resolve_default_remote(&self.path)
                } else {
                    remote.to_owned()
                };
                format!("refs/remotes/{remote}/{branch}")
            }
        };
        ref_exists(&self.path, &tracking).then_some(tracking)
    }

    /// True when `tip` was once part of `branch`, going by its reflog.
    fn was_in_branch(&self, branch: &str, tip: &str) -> Result<bool, GitCraftError> {
        let reflog = git_cli::run(
            &self.path,
            &[
                "reflog",
                "show",
                "--format=%H",
                &format!("refs/heads/{branch}"),
                "--",
            ],
        )?;
        if reflog.trim().is_empty() {
            return Ok(false);
        }
        // Anything left after excluding every past position was never in the branch.
        let mut revisions = format!("{tip}\n");
        for oid in reflog.lines() {
            revisions.push_str(&format!("^{oid}\n"));
        }
        let out = git_cli::run_status_with_input(
            &self.path,
            &["rev-list", "--ignore-missing", "--max-count=1", "--stdin"],
            revisions.into_bytes(),
        )?;
        if !out.status.success() {
            return Err(GitCraftError::message(out.stderr.trim().to_owned()));
        }
        Ok(out.stdout.trim().is_empty())
    }

    /// The commits in `to` that `from` doesn't have, newest first.
    fn commits_between(&self, from: &str, to: &str) -> Result<Vec<PushCommit>, GitCraftError> {
        let range = format!("{from}..{to}");
        let output = git_cli::run(
            &self.path,
            &["log", "-z", "--format=%H%x00%h%x00%s", &range, "--"],
        )?;
        let mut fields = output.split('\0');
        let mut commits = Vec::new();
        while let (Some(oid), Some(short), Some(summary)) =
            (fields.next(), fields.next(), fields.next())
        {
            commits.push(PushCommit {
                oid_hex: oid.to_owned(),
                short_oid: short.to_owned(),
                summary: summary.to_owned(),
            });
        }
        Ok(commits)
    }
}
