use super::sync::PorcelainRef;
use crate::{
    git_cli,
    validation::{ref_exists, resolve_default_remote, validate_ref_arg, validate_remote_arg},
    ForcePushPlan, GitCraftError, PushCommit, PushResult, RepoSession,
};

const HEAD_MOVED: &str = "The branch has changed since then. Push again.";
const REMOTE_MOVED: &str = "The remote has new commits. Fetch, then try again.";

/// The branch on a remote that a push updates.
struct PushTarget {
    remote: String,
    /// Its full ref on the server.
    server_ref: String,
    /// The local remote-tracking ref for it.
    tracking: String,
}

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
        let Some(target) = self.push_target(&branch) else {
            return Ok(None);
        };
        let PushTarget {
            remote,
            server_ref,
            tracking,
        } = target;
        let Some(name) = server_ref.strip_prefix("refs/heads/") else {
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
            .any(|b| b.is_remote && b.is_default && b.full_ref == tracking);
        Ok(Some(ForcePushPlan {
            removed: self.commits_between(&head.oid, &tip)?,
            added: self.commits_between(&tip, &head.oid)?,
            destination_ref: server_ref,
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
            // The commit that was confirmed, not the branch name: something outside the app
            // could move the branch before git reads it.
            let refspec = format!("{}:{destination_ref}", plan.head.oid);
            let output = git_cli::mutate_status(
                &self.path,
                &["push", "--porcelain", &lease, &remote, &refspec],
            )?;
            let status = PorcelainRef::find_destination(&output.stdout, &destination_ref);
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

    /// Where Push sends `branch`, matching [`RepoSession::push`], and the remote-tracking ref
    /// that shows what is there. `None` when there is nothing there yet, or git couldn't say.
    fn push_target(&self, branch: &str) -> Option<PushTarget> {
        let value = |args: &[&str]| {
            git_cli::run(&self.path, args)
                .ok()
                .map(|v| v.trim().to_owned())
                .filter(|v| !v.is_empty())
        };
        let resolve = |rev: String| value(&["rev-parse", "--verify", "--symbolic-full-name", &rev]);
        let same_name = format!("refs/heads/{branch}");
        let (remote, server_ref, tracking) = if resolve(format!("{branch}@{{u}}")).is_some() {
            let remote = self.push_remote(branch);
            // The local name of the ref comes from the fetch refspec, which may rename it, so
            // the name on the server is worked out separately.
            let tracking = resolve(format!("{branch}@{{push}}"))?;
            let configured = value(&["for-each-ref", "--format=%(push:remoteref)", &same_name]);
            let server_ref = configured.unwrap_or_else(|| {
                let to_upstream = value(&["config", "--get", "push.default"])
                    .is_some_and(|mode| mode == "upstream" || mode == "tracking");
                to_upstream
                    .then(|| value(&["config", "--get", &format!("branch.{branch}.merge")]))
                    .flatten()
                    .unwrap_or(same_name)
            });
            (remote, server_ref, tracking)
        } else {
            // A first push goes to the same name on the default remote, whatever push
            // settings say.
            let remote = resolve_default_remote(&self.path);
            let tracking = self.fetched_as(&remote, &same_name)?;
            (remote, same_name, tracking)
        };
        ref_exists(&self.path, &tracking).then_some(PushTarget {
            remote,
            server_ref,
            tracking,
        })
    }

    /// The local ref that `remote`'s fetch refspecs store its `server_ref` in.
    fn fetched_as(&self, remote: &str, server_ref: &str) -> Option<String> {
        let key = format!("remote.{remote}.fetch");
        let specs = git_cli::run(&self.path, &["config", "--get-all", &key]).ok()?;
        specs.lines().find_map(|spec| {
            let (from, to) = spec.trim().trim_start_matches('+').split_once(':')?;
            match from.split_once('*') {
                Some((prefix, suffix)) => {
                    let name = server_ref.strip_prefix(prefix)?.strip_suffix(suffix)?;
                    Some(to.replacen('*', name, 1))
                }
                None => (from == server_ref).then(|| to.to_owned()),
            }
        })
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
