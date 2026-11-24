#![allow(clippy::empty_line_after_doc_comments)]

mod diff;
mod git_cli;
mod graph;
mod highlight;
mod watcher;

use std::{
    collections::BTreeSet,
    io,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

#[derive(Debug, thiserror::Error)]
pub enum GitCraftError {
    #[error("{msg}")]
    Message { msg: String },
}

impl GitCraftError {
    pub fn message(msg: impl Into<String>) -> Self {
        Self::Message { msg: msg.into() }
    }
}

impl From<io::Error> for GitCraftError {
    fn from(err: io::Error) -> Self {
        Self::Message {
            msg: err.to_string(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RefKind {
    LocalBranch,
    RemoteBranch,
    Tag,
    Head,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RefBadge {
    pub name: String,
    pub kind: RefKind,
    pub is_current: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GraphEdge {
    pub from_lane: u32,
    pub to_lane: u32,
    pub is_merge: bool,
    pub color_idx: u8,
}

#[derive(Clone, Debug)]
pub struct StyleSpan {
    pub start_utf16: u32,
    pub len_utf16: u32,
    pub foreground: String,
}

#[derive(Clone, Debug)]
pub struct DiffRow {
    pub kind: String,
    pub text: String,
    pub old_line: Option<u32>,
    pub new_line: Option<u32>,
    pub spans: Vec<StyleSpan>,
}

#[derive(Clone, Debug)]
pub struct FileChange {
    pub path: String,
    pub status: String,
    pub staged: bool,
}

#[derive(Clone, Debug)]
pub struct CommitRow {
    pub oid_hex: String,
    pub short_oid: String,
    pub summary: String,
    pub author_name: String,
    pub timestamp: i64,
    pub lane: u32,
    pub color_idx: u8,
    pub max_lanes: u32,
    pub edges: Vec<GraphEdge>,
    pub refs: Vec<RefBadge>,
    pub is_remote_only: bool,
}

#[derive(Clone, Debug)]
pub struct CommitDetail {
    pub oid_hex: String,
    pub short_oid: String,
    pub summary: String,
    pub body: String,
    pub author_name: String,
    pub author_email: String,
    pub timestamp: i64,
    pub parent_oids: Vec<String>,
    pub files: Vec<FileChange>,
}

#[derive(Clone, Debug)]
pub struct BranchInfo {
    pub name: String,
    pub full_ref: String,
    pub is_remote: bool,
    pub is_head: bool,
    pub target_oid_hex: String,
    pub ahead: u32,
    pub behind: u32,
    pub is_merged: bool,
}

#[derive(Clone, Debug)]
pub struct TagInfo {
    pub name: String,
    pub full_ref: String,
    pub target_oid_hex: String,
}

#[derive(Clone, Debug)]
pub struct StashInfo {
    pub index: u32,
    pub name: String,
    pub message: String,
}

#[derive(Clone, Debug)]
pub struct RepoStatus {
    pub files: Vec<String>,
    pub staged_files: Vec<FileChange>,
    pub unstaged_files: Vec<FileChange>,
    pub branch: String,
    pub is_clean: bool,
    pub is_merging: bool,
    pub has_conflicts: bool,
}

pub struct RepoSession {
    path: PathBuf,
    sync_repo: gix::ThreadSafeRepository,
    mutation_lock: Arc<Mutex<()>>,
    dirty: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
}

impl Drop for RepoSession {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Release);
    }
}

impl RepoSession {
    pub fn new(path: String) -> Result<Self, GitCraftError> {
        Self::open(path)
    }

    pub fn open(path: impl Into<PathBuf>) -> Result<Self, GitCraftError> {
        let path = path.into();
        if !path.join(".git").exists() {
            return Err(GitCraftError::message("not a Git repository"));
        }
        let sync_repo = gix::ThreadSafeRepository::open(&path)
            .map_err(|e| GitCraftError::message(e.to_string()))?;
        let dirty = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(AtomicBool::new(false));
        watcher::spawn_dirty_watcher(&path, Arc::clone(&dirty), Arc::clone(&stopped));
        Ok(Self {
            path,
            sync_repo,
            mutation_lock: Arc::new(Mutex::new(())),
            dirty,
            stopped,
        })
    }

    pub fn take_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::AcqRel)
    }

    pub fn status(&self) -> Result<RepoStatus, GitCraftError> {
        let output = git_cli::run(&self.path, &["status", "--porcelain=v1", "--branch"])?;
        let mut lines = output.lines();
        let branch = lines
            .next()
            .unwrap_or_default()
            .trim_start_matches("## ")
            .to_owned();

        let mut all_paths = BTreeSet::new();
        let mut staged_files = Vec::new();
        let mut unstaged_files = Vec::new();
        let mut has_conflicts = false;

        for line in lines {
            if line.len() < 4 {
                continue;
            }
            let bytes = line.as_bytes();
            let x = bytes[0] as char;
            let y = bytes[1] as char;
            if x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D') {
                has_conflicts = true;
            }
            let raw_path = &line[3..];
            let path = raw_path
                .split(" -> ")
                .last()
                .unwrap_or(raw_path)
                .trim_matches('"')
                .to_owned();

            all_paths.insert(path.clone());

            if x != ' ' && x != '?' {
                staged_files.push(FileChange {
                    path: path.clone(),
                    status: x.to_string(),
                    staged: true,
                });
            }
            if y != ' ' {
                let status = if x == '?' && y == '?' {
                    "?".to_owned()
                } else {
                    y.to_string()
                };
                unstaged_files.push(FileChange {
                    path,
                    status,
                    staged: false,
                });
            }
        }

        let is_merging = self.path.join(".git/MERGE_HEAD").exists();
        let files: Vec<String> = all_paths.into_iter().collect();
        Ok(RepoStatus {
            is_clean: staged_files.is_empty() && unstaged_files.is_empty(),
            files,
            staged_files,
            unstaged_files,
            branch,
            is_merging,
            has_conflicts,
        })
    }

    pub fn get_commit_graph(
        &self,
        offset: u32,
        limit: u32,
        search_query: Option<String>,
    ) -> Result<Vec<CommitRow>, GitCraftError> {
        graph::get_commit_graph(&self.sync_repo, offset, limit, search_query)
    }

    pub fn get_branch_graph(
        &self,
        offset: u32,
        limit: u32,
        search_query: Option<String>,
    ) -> Result<Vec<CommitRow>, GitCraftError> {
        graph::get_branch_graph(&self.sync_repo, offset, limit, search_query)
    }

    pub fn get_commit_detail(&self, oid_hex: String) -> Result<CommitDetail, GitCraftError> {
        graph::get_commit_detail(&self.path, &self.sync_repo, &oid_hex)
    }

    pub fn get_commit_diff(
        &self,
        oid_hex: String,
        path: Option<String>,
    ) -> Result<Vec<DiffRow>, GitCraftError> {
        Ok(diff::commit_diff(&self.path, &oid_hex, path.as_deref())?)
    }

    pub fn get_working_diff(
        &self,
        path: Option<String>,
        staged: bool,
    ) -> Result<Vec<DiffRow>, GitCraftError> {
        Ok(diff::working_tree_file(
            &self.path,
            path.as_deref(),
            staged,
        )?)
    }

    pub fn list_branches(&self) -> Result<Vec<BranchInfo>, GitCraftError> {
        graph::list_branches(&self.sync_repo)
    }

    pub fn list_tags(&self) -> Result<Vec<TagInfo>, GitCraftError> {
        graph::list_tags(&self.sync_repo)
    }

    pub fn create_tag(
        &self,
        tag_name: String,
        target: Option<String>,
        message: Option<String>,
        push_to_remote: bool,
    ) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let trimmed_name = tag_name.trim();
        if trimmed_name.is_empty() {
            return Err(GitCraftError::message("tag name cannot be empty"));
        }

        let trimmed_msg = message
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);

        let mut args = vec!["tag"];
        if let Some(ref msg) = trimmed_msg {
            args.push("-a");
            args.push(trimmed_name);
            args.push("-m");
            args.push(msg.as_str());
        } else {
            args.push(trimmed_name);
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
    }

    pub fn delete_tag(&self, tag_name: String, delete_remote: bool) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["tag", "-d", &tag_name])?;
        if delete_remote {
            let remote = resolve_default_remote(&self.path);
            let refspec = format!(":refs/tags/{tag_name}");
            git_cli::mutate(&self.path, &["push", &remote, &refspec])?;
        }
        Ok(())
    }

    pub fn push_tag(&self, tag_name: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let remote = resolve_default_remote(&self.path);
        let refspec = format!("refs/tags/{tag_name}");
        git_cli::mutate(&self.path, &["push", &remote, &refspec])?;
        Ok(())
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
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let mut args = vec!["stash", "push"];
        if include_untracked {
            args.push("-u");
        }
        let trimmed = message
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        if let Some(ref msg) = trimmed {
            args.push("-m");
            args.push(msg.as_str());
        }
        git_cli::mutate(&self.path, &args)?;
        Ok(())
    }

    pub fn stash_apply(&self, index: u32) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let target = format!("stash@{{{index}}}");
        git_cli::mutate(&self.path, &["stash", "apply", &target])?;
        Ok(())
    }

    pub fn stash_pop(&self, index: u32) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let target = format!("stash@{{{index}}}");
        git_cli::mutate(&self.path, &["stash", "pop", &target])?;
        Ok(())
    }

    pub fn stash_drop(&self, index: u32) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let target = format!("stash@{{{index}}}");
        git_cli::mutate(&self.path, &["stash", "drop", &target])?;
        Ok(())
    }

    pub fn checkout_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["checkout", &branch_name])?;
        Ok(())
    }

    pub fn create_branch(
        &self,
        branch_name: String,
        start_point: Option<String>,
        checkout: bool,
    ) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let mut args = if checkout {
            vec!["checkout", "-b", &branch_name]
        } else {
            vec!["branch", &branch_name]
        };
        if let Some(ref sp) = start_point {
            args.push(sp.as_str());
        }
        git_cli::mutate(&self.path, &args)?;
        Ok(())
    }

    pub fn delete_branch(&self, branch_name: String, force: bool) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let flag = if force { "-D" } else { "-d" };
        git_cli::mutate(&self.path, &["branch", flag, &branch_name])?;
        Ok(())
    }

    pub fn merge_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["merge", &branch_name])?;
        Ok(())
    }

    pub fn abort_merge(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["merge", "--abort"])?;
        Ok(())
    }

    pub fn diff(&self) -> Result<Vec<DiffRow>, GitCraftError> {
        Ok(diff::working_tree(&self.path)?)
    }

    pub fn stage(&self, path: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["add", "--", &path])?;
        Ok(())
    }

    pub fn unstage(&self, path: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        if git_cli::mutate(&self.path, &["reset", "HEAD", "--", &path]).is_err() {
            git_cli::mutate(&self.path, &["rm", "--cached", "--", &path])?;
        }
        Ok(())
    }

    pub fn stage_all(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["add", "-A"])?;
        Ok(())
    }

    pub fn unstage_all(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        if git_cli::mutate(&self.path, &["reset", "HEAD"]).is_err() {
            git_cli::mutate(&self.path, &["rm", "--cached", "-r", "--", "."])?;
        }
        Ok(())
    }

    pub fn discard_file(&self, path: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        // Try checkout -- first; if untracked, fall back to git clean -fd --.
        if git_cli::mutate(&self.path, &["checkout", "--", &path]).is_err() {
            git_cli::mutate(&self.path, &["clean", "-fd", "--", &path])?;
        }
        Ok(())
    }

    /// Adds `path` to `.gitignore` (shared) or `.git/info/exclude` (local only).
    /// The rule is anchored to the repo root; duplicates are not re-added.
    pub fn ignore_path(&self, path: String, local_only: bool) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let target = if local_only {
            let out = git_cli::run(&self.path, &["rev-parse", "--git-path", "info/exclude"])?;
            let p = PathBuf::from(out.trim());
            if p.is_absolute() {
                p
            } else {
                self.path.join(p)
            }
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
    }

    pub fn commit(&self, message: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["commit", "-m", &message])?;
        Ok(())
    }

    pub fn fetch(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["fetch"])?;
        Ok(())
    }

    pub fn pull(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["pull"])?;
        Ok(())
    }

    pub fn push(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["push"])?;
        Ok(())
    }

    pub fn highlight(&self, text: &str, extension: &str) -> Vec<StyleSpan> {
        highlight::highlight(text, extension)
    }
}

uniffi::include_scaffolding!("gitcraft_core");

fn resolve_default_remote(repo: &std::path::Path) -> String {
    if let Ok(output) = git_cli::run(repo, &["remote"]) {
        let remotes: Vec<&str> = output
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect();
        if remotes.contains(&"origin") {
            return "origin".to_owned();
        }
        if let Some(&first) = remotes.first() {
            return first.to_owned();
        }
    }
    "origin".to_owned()
}

/// Builds a root-anchored gitignore pattern for a literal path.
fn ignore_rule(path: &str) -> String {
    let trimmed = path.trim_start_matches("./").trim_start_matches('/');
    let mut rule = String::from("/");
    for (i, c) in trimmed.chars().enumerate() {
        let needs_escape = matches!(c, '*' | '?' | '[' | '\\')
            || (i == 0 && matches!(c, '#' | '!'));
        if needs_escape {
            rule.push('\\');
        }
        rule.push(c);
    }
    // Trailing spaces are significant only when escaped.
    if rule.ends_with(' ') {
        rule.pop();
        rule.push_str("\\ ");
    }
    rule
}
