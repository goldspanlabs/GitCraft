use crate::{
    git_cli,
    validation::{resolve_default_remote, validate_remote_arg},
    GitCraftError, PullStrategy, PushResult, RemoteInfo, RepoSession,
};

impl RepoSession {
    pub fn list_remotes(&self) -> Result<Vec<RemoteInfo>, GitCraftError> {
        let output = git_cli::run(&self.path, &["remote", "-v"])?;
        let mut remotes: Vec<RemoteInfo> = Vec::new();
        for line in output.lines() {
            // "<name>\t<url> (fetch|push)"
            let Some((name, rest)) = line.split_once('\t') else {
                continue;
            };
            let (url, kind) = match rest.rsplit_once(' ') {
                Some((url, kind)) => (url.to_owned(), kind),
                None => continue,
            };
            let idx = match remotes.iter().position(|r| r.name == name) {
                Some(i) => i,
                None => {
                    remotes.push(RemoteInfo {
                        name: name.to_owned(),
                        fetch_url: String::new(),
                        push_url: String::new(),
                    });
                    remotes.len() - 1
                }
            };
            match kind {
                "(fetch)" => remotes[idx].fetch_url = url,
                "(push)" => remotes[idx].push_url = url,
                _ => {}
            }
        }
        Ok(remotes)
    }

    pub fn add_remote(&self, name: String, url: String) -> Result<(), GitCraftError> {
        let (name, url) = (validate_remote_arg(&name)?, validate_remote_arg(&url)?);
        self.mutate(&["remote", "add", &name, &url])
    }

    pub fn set_remote_url(&self, name: String, url: String) -> Result<(), GitCraftError> {
        let (name, url) = (validate_remote_arg(&name)?, validate_remote_arg(&url)?);
        self.mutate(&["remote", "set-url", &name, &url])
    }

    pub fn rename_remote(&self, old_name: String, new_name: String) -> Result<(), GitCraftError> {
        let (old_name, new_name) = (
            validate_remote_arg(&old_name)?,
            validate_remote_arg(&new_name)?,
        );
        self.mutate(&["remote", "rename", &old_name, &new_name])
    }

    pub fn remove_remote(&self, name: String) -> Result<(), GitCraftError> {
        let name = validate_remote_arg(&name)?;
        self.mutate(&["remote", "remove", &name])
    }

    pub fn test_remote_connection(&self, url: String) -> Result<(), GitCraftError> {
        let url = validate_remote_arg(&url)?;
        git_cli::run(&self.path, &["ls-remote", "--heads", &url]).map(|_| ())
    }

    fn fetch_impl(&self, remote: Option<&str>, include_tags: bool) -> Result<(), GitCraftError> {
        // `--no-write-fetch-head` keeps this unlocked fetch from rewriting FETCH_HEAD under a
        // `pull` that is reading it (nothing here uses FETCH_HEAD).
        let mut args = vec!["fetch", "--prune", "--no-write-fetch-head"];
        if include_tags {
            args.push("--tags");
        }
        if let Some(name) = remote {
            args.push(name);
        }
        // No mutation lock: fetch only updates remote-tracking refs (git locks those itself) and
        // can run for minutes, which must not hold up staging or committing.
        git_cli::mutate(&self.path, &args)
    }

    pub fn fetch_remote(&self, name: String, include_tags: bool) -> Result<(), GitCraftError> {
        let name = validate_remote_arg(&name)?;
        self.fetch_impl(Some(&name), include_tags)
    }

    pub fn fetch(&self, include_tags: bool) -> Result<(), GitCraftError> {
        self.fetch_impl(None, include_tags)
    }

    pub fn pull(&self, strategy: PullStrategy) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| match strategy {
            PullStrategy::GitConfig => match git_cli::mutate(&self.path, &["pull"]) {
                // With no pull.rebase/pull.ff configured, git refuses diverged pulls. Fall
                // back to a merge, which is what git did before it started asking.
                Err(e) if e.to_string().contains("divergent branches") => {
                    git_cli::mutate(&self.path, &["pull", "--no-rebase"])
                }
                result => result,
            },
            PullStrategy::Merge => git_cli::mutate(&self.path, &["pull", "--no-rebase"]),
            PullStrategy::Rebase => git_cli::mutate(&self.path, &["pull", "--rebase"]),
            PullStrategy::FastForwardOnly => git_cli::mutate(&self.path, &["pull", "--ff-only"]),
        })
    }

    /// Pushes the checked-out branch, publishing it (and setting its upstream) on its first
    /// push. Reports what happened from git's own per-ref result (`push --porcelain`), so a
    /// stale or missing remote-tracking ref can't make the summary wrong.
    pub fn push(&self) -> Result<PushResult, GitCraftError> {
        self.with_mutation_lock(|| {
            let branch = git_cli::run(&self.path, &["symbolic-ref", "--short", "-q", "HEAD"])
                .map(|b| b.trim().to_owned())
                .ok()
                .filter(|b| !b.is_empty())
                .ok_or_else(|| {
                    GitCraftError::message("HEAD is detached; check out a branch to push")
                })?;
            let has_upstream = git_cli::run(
                &self.path,
                &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            )
            .is_ok();

            let (remote, output) = if has_upstream {
                // Where a plain `git push` goes, which may be a separate push remote.
                let remote = self.push_remote(&branch);
                let output = git_cli::mutate_output(&self.path, &["push", "--porcelain"])?;
                (remote, output)
            } else {
                // First push of this branch: publish it and set its upstream.
                let remote = resolve_default_remote(&self.path);
                let output = git_cli::mutate_output(
                    &self.path,
                    &["push", "--porcelain", "--set-upstream", &remote, &branch],
                )?;
                (remote, output)
            };

            let status = PorcelainRef::find(&output, &branch);
            let destination_branch = status
                .as_ref()
                .and_then(|s| s.to.strip_prefix("refs/heads/"))
                .unwrap_or(&branch)
                .to_owned();
            let (commits, published) = match &status {
                Some(s) if s.flag == '*' => (0, true),
                Some(s) if s.flag == '=' => (0, false),
                Some(s) => (self.count_range(&s.summary), false),
                None => (0, false),
            };
            Ok(PushResult {
                branch,
                destination: format!("{remote}/{destination_branch}"),
                commits,
                published,
            })
        })
    }

    /// Commits in a push summary's `old..new` (or forced `old...new`) range, or 0 when git
    /// can't count them here.
    fn count_range(&self, summary: &str) -> u32 {
        let range = summary.split_whitespace().next().unwrap_or("");
        let Some((old, new)) = range.split_once("...").or_else(|| range.split_once("..")) else {
            return 0;
        };
        git_cli::run(
            &self.path,
            &["rev-list", "--count", &format!("{old}..{new}")],
        )
        .ok()
        .and_then(|n| n.trim().parse().ok())
        .unwrap_or(0)
    }

    /// The remote `branch` pushes to, as git chooses it: the branch's `pushRemote`, then
    /// `remote.pushDefault`, then the remote it pulls from, then the default remote.
    fn push_remote(&self, branch: &str) -> String {
        let config = |key: String| {
            git_cli::run(&self.path, &["config", "--get", &key])
                .ok()
                .map(|v| v.trim().to_owned())
                .filter(|v| !v.is_empty())
        };
        config(format!("branch.{branch}.pushRemote"))
            .or_else(|| config("remote.pushDefault".to_owned()))
            .or_else(|| config(format!("branch.{branch}.remote")))
            .unwrap_or_else(|| resolve_default_remote(&self.path))
    }
}

/// One ref's line from `git push --porcelain`: `<flag>\t<from>:<to>\t<summary>`.
struct PorcelainRef {
    /// `*` created, `=` already up to date, ` ` fast-forward, `+` forced, `!` rejected.
    flag: char,
    to: String,
    summary: String,
}

impl PorcelainRef {
    /// The line for `branch`, or the first ref line when none names it.
    fn find(output: &str, branch: &str) -> Option<Self> {
        let refs: Vec<Self> = output.lines().filter_map(Self::parse).collect();
        let wanted = format!("refs/heads/{branch}");
        let index = refs.iter().position(|r| r.to == wanted).unwrap_or(0);
        refs.into_iter().nth(index)
    }

    fn parse(line: &str) -> Option<Self> {
        let mut fields = line.splitn(3, '\t');
        let flag = fields.next()?.chars().next()?;
        let (_, to) = fields.next()?.split_once(':')?;
        Some(Self {
            flag,
            to: to.to_owned(),
            summary: fields.next().unwrap_or("").to_owned(),
        })
    }
}
