use std::io;

use crate::{
    diff, git_cli,
    validation::{has_head, ignore_rule},
    DiffRow, GitCraftError, RepoSession,
};

impl RepoSession {
    pub fn diff(&self) -> Result<Vec<DiffRow>, GitCraftError> {
        Ok(diff::working_tree(&self.path)?)
    }

    pub fn stage(&self, path: String) -> Result<(), GitCraftError> {
        self.mutate(&["--literal-pathspecs", "add", "--", &path])
    }

    pub fn unstage(&self, path: String) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            if has_head(&self.path) {
                git_cli::mutate(
                    &self.path,
                    &["--literal-pathspecs", "reset", "HEAD", "--", &path],
                )?;
            } else {
                // No commits yet: there is no HEAD to reset to, so drop the entry from the index.
                git_cli::mutate(
                    &self.path,
                    &["--literal-pathspecs", "rm", "--cached", "--", &path],
                )?;
            }
            Ok(())
        })
    }

    pub fn stage_all(&self) -> Result<(), GitCraftError> {
        self.mutate(&["add", "-A"])
    }

    pub fn unstage_all(&self) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            if has_head(&self.path) {
                git_cli::mutate(&self.path, &["reset", "HEAD"])?;
            } else {
                git_cli::mutate(&self.path, &["rm", "--cached", "-r", "--", "."])?;
            }
            Ok(())
        })
    }

    pub fn discard_file(&self, path: String) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            // Try checkout -- first; if untracked, fall back to git clean -fd --.
            if git_cli::mutate(
                &self.path,
                &["--literal-pathspecs", "checkout", "--", &path],
            )
            .is_err()
            {
                git_cli::mutate(
                    &self.path,
                    &["--literal-pathspecs", "clean", "-fd", "--", &path],
                )?;
            }
            Ok(())
        })
    }

    /// Discards all staged, unstaged, and untracked local changes without altering
    /// single-file `discard_file` semantics. Handles unborn HEAD explicitly.
    pub fn discard_all(&self) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            if has_head(&self.path) {
                git_cli::mutate(&self.path, &["reset", "--hard", "HEAD"])?;
            } else {
                git_cli::mutate(
                    &self.path,
                    &["rm", "--cached", "-rf", "--ignore-unmatch", "--", "."],
                )?;
            }
            git_cli::mutate(&self.path, &["clean", "-fd"])?;
            Ok(())
        })
    }

    /// Adds `path` to `.gitignore` (shared) or `.git/info/exclude` (local only).
    /// The rule is anchored to the repo root; duplicates are not re-added.
    pub fn ignore_path(&self, path: String, local_only: bool) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            let target = if local_only {
                self.git_path("info/exclude")?
            } else {
                self.path.join(".gitignore")
            };
            let rule = ignore_rule(&path);
            let existing = match std::fs::read_to_string(&target) {
                Ok(text) => text,
                Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
                Err(e) => return Err(e.into()),
            };
            if existing.lines().any(|l| l.trim_end() == rule) {
                return Ok(());
            }
            if let Some(dir) = target.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let mut updated = existing;
            if !updated.is_empty() && !updated.ends_with('\n') {
                updated.push('\n');
            }
            updated.push_str(&rule);
            updated.push('\n');
            std::fs::write(&target, updated)?;
            Ok(())
        })
    }

    pub fn commit(&self, message: String) -> Result<(), GitCraftError> {
        self.commit_with_options(message, false, false)
    }

    /// Commits with the Skip Hooks (`--no-verify`) and Amend (`--amend`) options.
    pub fn commit_with_options(
        &self,
        message: String,
        skip_hooks: bool,
        amend: bool,
    ) -> Result<(), GitCraftError> {
        let mut args = vec!["commit", "-m", &message];
        if skip_hooks {
            args.push("--no-verify");
        }
        if amend {
            args.push("--amend");
        }
        self.mutate(&args)
    }

    /// True when HEAD is contained in a remote-tracking branch. Amending such a commit
    /// rewrites history that has already been published.
    pub fn head_is_pushed(&self) -> Result<bool, GitCraftError> {
        let output = git_cli::run(&self.path, &["branch", "-r", "--contains", "HEAD"])?;
        Ok(!output.trim().is_empty())
    }

    /// The full message of HEAD, used to fill the composer when amending.
    pub fn head_commit_message(&self) -> Result<String, GitCraftError> {
        let output = git_cli::run(&self.path, &["log", "-1", "--format=%B"])?;
        Ok(output.trim_end().to_owned())
    }
}
