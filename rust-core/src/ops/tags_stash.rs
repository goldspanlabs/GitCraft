use crate::{
    git_cli,
    validation::{resolve_default_remote, trim_optional_text, validate_ref_arg},
    GitCraftError, RepoSession, StashInfo,
};

impl RepoSession {
    pub fn create_tag(
        &self,
        tag_name: String,
        target: Option<String>,
        message: Option<String>,
        push_to_remote: bool,
    ) -> Result<(), GitCraftError> {
        let trimmed_name = validate_ref_arg(&tag_name)?;
        let target = target.as_deref().map(validate_ref_arg).transpose()?;
        let trimmed_msg = trim_optional_text(message.as_deref());

        self.with_mutation_lock(|| {
            let mut args = vec!["tag"];
            if let Some(ref msg) = trimmed_msg {
                args.push("-a");
                args.push(&trimmed_name);
                args.push("-m");
                args.push(msg.as_str());
            } else {
                args.push(&trimmed_name);
            }
            if let Some(ref t) = target {
                args.push(t.as_str());
            }
            git_cli::mutate(&self.path, &args)?;

            if push_to_remote {
                let remote = resolve_default_remote(&self.path);
                let refspec = format!("refs/tags/{trimmed_name}");
                git_cli::mutate(&self.path, &["push", &remote, &refspec])?;
            }
            Ok(())
        })
    }

    pub fn delete_tag(&self, tag_name: String, delete_remote: bool) -> Result<(), GitCraftError> {
        let tag_name = validate_ref_arg(&tag_name)?;
        self.with_mutation_lock(|| {
            git_cli::mutate(&self.path, &["tag", "-d", &tag_name])?;
            if delete_remote {
                let remote = resolve_default_remote(&self.path);
                let refspec = format!(":refs/tags/{tag_name}");
                git_cli::mutate(&self.path, &["push", &remote, &refspec])?;
            }
            Ok(())
        })
    }

    pub fn push_tag(&self, tag_name: String) -> Result<(), GitCraftError> {
        let tag_name = validate_ref_arg(&tag_name)?;
        self.with_mutation_lock(|| {
            let remote = resolve_default_remote(&self.path);
            let refspec = format!("refs/tags/{tag_name}");
            git_cli::mutate(&self.path, &["push", &remote, &refspec])?;
            Ok(())
        })
    }

    pub fn list_stashes(&self) -> Result<Vec<StashInfo>, GitCraftError> {
        let output = git_cli::run(&self.path, &["stash", "list", "--format=%gd\x1f%gs"])?;
        let stashes = output
            .lines()
            .filter_map(|line| {
                let mut parts = line.splitn(2, '\x1f');
                let name = parts.next()?.trim();
                let message = parts.next().unwrap_or_default().trim();
                let index = name
                    .strip_prefix("stash@{")
                    .and_then(|s| s.strip_suffix('}'))
                    .and_then(|s| s.parse::<u32>().ok())?;
                Some(StashInfo {
                    index,
                    name: name.to_owned(),
                    message: message.to_owned(),
                })
            })
            .collect();
        Ok(stashes)
    }

    pub fn stash_push(
        &self,
        message: Option<String>,
        include_untracked: bool,
    ) -> Result<(), GitCraftError> {
        let trimmed = trim_optional_text(message.as_deref());
        let mut args = vec!["stash", "push"];
        if include_untracked {
            args.push("-u");
        }
        if let Some(ref msg) = trimmed {
            args.push("-m");
            args.push(msg.as_str());
        }
        self.mutate(&args)
    }

    fn stash_op(&self, subcmd: &str, index: u32) -> Result<(), GitCraftError> {
        let target = format!("stash@{{{index}}}");
        self.mutate(&["stash", subcmd, &target])
    }

    pub fn stash_apply(&self, index: u32) -> Result<(), GitCraftError> {
        self.stash_op("apply", index)
    }

    pub fn stash_pop(&self, index: u32) -> Result<(), GitCraftError> {
        self.stash_op("pop", index)
    }

    pub fn stash_drop(&self, index: u32) -> Result<(), GitCraftError> {
        self.stash_op("drop", index)
    }
}
