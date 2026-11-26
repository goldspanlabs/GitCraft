use crate::{
    git_cli,
    validation::{resolve_default_remote, validate_remote_arg},
    GitCraftError, PullStrategy, RemoteInfo, RepoSession,
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
        git_cli::mutate(&self.path, &args)?;
        Ok(())
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
                Ok(()) => Ok(()),
                // With no pull.rebase/pull.ff configured, git refuses diverged pulls. Fall
                // back to a merge, which is what git did before it started asking.
                Err(e) if e.to_string().contains("divergent branches") => {
                    git_cli::mutate(&self.path, &["pull", "--no-rebase"])?;
                    Ok(())
                }
                Err(e) => Err(e),
            },
            PullStrategy::Merge => {
                git_cli::mutate(&self.path, &["pull", "--no-rebase"])?;
                Ok(())
            }
            PullStrategy::Rebase => {
                git_cli::mutate(&self.path, &["pull", "--rebase"])?;
                Ok(())
            }
            PullStrategy::FastForwardOnly => {
                git_cli::mutate(&self.path, &["pull", "--ff-only"])?;
                Ok(())
            }
        })
    }

    pub fn push(&self) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            let has_upstream = git_cli::run(
                &self.path,
                &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            )
            .is_ok();
            if has_upstream {
                git_cli::mutate(&self.path, &["push"])?;
            } else {
                // First push of this branch: publish it and set its upstream.
                let branch = git_cli::run(&self.path, &["symbolic-ref", "--short", "-q", "HEAD"])
                    .map(|b| b.trim().to_owned())
                    .ok()
                    .filter(|b| !b.is_empty())
                    .ok_or_else(|| {
                        GitCraftError::message("HEAD is detached; check out a branch to push")
                    })?;
                let remote = resolve_default_remote(&self.path);
                git_cli::mutate(&self.path, &["push", "--set-upstream", &remote, &branch])?;
            }
            Ok(())
        })
    }
}
