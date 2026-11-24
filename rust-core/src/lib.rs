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

/// Order in which the commit graph lists commits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommitSort {
    /// Newest commit time first (the default).
    ByDate,
    /// Children before parents without interleaving separate lines of history.
    Topological,
}

/// How `pull` reconciles diverged branches.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PullStrategy {
    /// Follow the repository's git config (`pull.rebase` / `pull.ff`); when neither is
    /// set, merge, as git did before it started asking.
    GitConfig,
    Merge,
    Rebase,
    /// Refuse to create a merge commit or rewrite history; fail if branches diverged.
    FastForwardOnly,
}

/// How far `reset_to` moves the branch and what happens to the working tree.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResetMode {
    /// Move the branch; keep all changes staged.
    Soft,
    /// Move the branch; keep changes in the working tree, unstaged.
    Mixed,
    /// Move the branch and discard all uncommitted changes.
    Hard,
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
    pub author_email: String,
    pub timestamp: i64,
    pub lane: u32,
    pub color_idx: u8,
    pub max_lanes: u32,
    pub edges: Vec<GraphEdge>,
    pub refs: Vec<RefBadge>,
    pub is_remote_only: bool,
    /// On the checked-out branch and not contained in any remote branch.
    pub is_unpushed: bool,
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
    /// The local branch pinned to the top of the sidebar: origin's default branch, else main or master.
    pub is_default: bool,
}

#[derive(Clone, Debug)]
pub struct TagInfo {
    pub name: String,
    pub full_ref: String,
    pub target_oid_hex: String,
    pub created_timestamp: i64,
}

#[derive(Clone, Debug)]
pub struct RemoteInfo {
    pub name: String,
    pub fetch_url: String,
    pub push_url: String,
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
    pub is_rebasing: bool,
    pub has_conflicts: bool,
}

pub struct RepoSession {
    path: PathBuf,
    sync_repo: gix::ThreadSafeRepository,
    mutation_lock: Arc<Mutex<()>>,
    dirty: Arc<AtomicBool>,
    graph_dirty: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
    commit_sort: std::sync::atomic::AtomicU8,
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
        let graph_dirty = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(AtomicBool::new(false));
        watcher::spawn_dirty_watcher(
            &path,
            Arc::clone(&dirty),
            Arc::clone(&graph_dirty),
            Arc::clone(&stopped),
        );
        Ok(Self {
            path,
            sync_repo,
            mutation_lock: Arc::new(Mutex::new(())),
            dirty,
            graph_dirty,
            stopped,
            commit_sort: std::sync::atomic::AtomicU8::new(0),
        })
    }

    /// True if anything relevant changed (working tree, index, refs) since the last call.
    pub fn take_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::AcqRel)
    }

    /// True if refs, HEAD or config changed, so the graph and ref lists need reloading.
    /// Plain working-tree edits only need a status refresh.
    pub fn take_graph_dirty(&self) -> bool {
        self.graph_dirty.swap(false, Ordering::AcqRel)
    }

    /// Whether `<git dir>/<name>` exists. Asks git for the location so it also works when
    /// `.git` is a file (linked worktrees, submodules).
    fn git_path_exists(&self, name: &str) -> bool {
        git_cli::run(&self.path, &["rev-parse", "--git-path", name])
            .map(|out| {
                let p = PathBuf::from(out.trim());
                if p.is_absolute() {
                    p
                } else {
                    self.path.join(p)
                }
                .exists()
            })
            .unwrap_or(false)
    }

    pub fn status(&self) -> Result<RepoStatus, GitCraftError> {
        // -z: NUL-separated, paths are never quoted or escaped (non-ASCII, spaces, quotes).
        let output = git_cli::run(&self.path, &["status", "--porcelain=v1", "-z", "--branch"])?;
        let mut entries = output.split('\0');
        let branch = clean_branch_header(entries.next().unwrap_or_default());

        let mut all_paths = BTreeSet::new();
        let mut staged_files = Vec::new();
        let mut unstaged_files = Vec::new();
        let mut has_conflicts = false;

        while let Some(entry) = entries.next() {
            if entry.len() < 4 {
                continue;
            }
            let bytes = entry.as_bytes();
            let x = bytes[0] as char;
            let y = bytes[1] as char;
            if x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D') {
                has_conflicts = true;
            }
            let path = entry[3..].to_owned();
            // Renames and copies carry the original path as an extra entry; skip it.
            if matches!(x, 'R' | 'C') || matches!(y, 'R' | 'C') {
                entries.next();
            }

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

        let is_merging = self.git_path_exists("MERGE_HEAD");
        let is_rebasing =
            self.git_path_exists("rebase-merge") || self.git_path_exists("rebase-apply");
        let files: Vec<String> = all_paths.into_iter().collect();
        Ok(RepoStatus {
            is_clean: staged_files.is_empty() && unstaged_files.is_empty(),
            files,
            staged_files,
            unstaged_files,
            branch,
            is_merging,
            is_rebasing,
            has_conflicts,
        })
    }

    /// Chooses the order used by the graph queries. Takes effect on the next query.
    pub fn set_commit_sort(&self, sort: CommitSort) {
        let value = match sort {
            CommitSort::ByDate => 0,
            CommitSort::Topological => 1,
        };
        self.commit_sort.store(value, Ordering::Release);
    }

    fn commit_sort(&self) -> CommitSort {
        match self.commit_sort.load(Ordering::Acquire) {
            1 => CommitSort::Topological,
            _ => CommitSort::ByDate,
        }
    }

    pub fn get_commit_graph(
        &self,
        offset: u32,
        limit: u32,
        search_query: Option<String>,
    ) -> Result<Vec<CommitRow>, GitCraftError> {
        graph::get_commit_graph(
            &self.sync_repo,
            offset,
            limit,
            search_query,
            self.commit_sort(),
        )
    }

    pub fn get_branch_graph(
        &self,
        offset: u32,
        limit: u32,
        search_query: Option<String>,
    ) -> Result<Vec<CommitRow>, GitCraftError> {
        graph::get_branch_graph(
            &self.sync_repo,
            offset,
            limit,
            search_query,
            self.commit_sort(),
        )
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
        validate_ref_arg(trimmed_name)?;
        let target = target.as_deref().map(validate_ref_arg).transpose()?;

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
        let tag_name = validate_ref_arg(&tag_name)?;
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
        let tag_name = validate_ref_arg(&tag_name)?;
        let remote = resolve_default_remote(&self.path);
        let refspec = format!("refs/tags/{tag_name}");
        git_cli::mutate(&self.path, &["push", &remote, &refspec])?;
        Ok(())
    }

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
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["remote", "add", &name, &url])?;
        Ok(())
    }

    pub fn set_remote_url(&self, name: String, url: String) -> Result<(), GitCraftError> {
        let (name, url) = (validate_remote_arg(&name)?, validate_remote_arg(&url)?);
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["remote", "set-url", &name, &url])?;
        Ok(())
    }

    pub fn rename_remote(&self, old_name: String, new_name: String) -> Result<(), GitCraftError> {
        let (old_name, new_name) = (
            validate_remote_arg(&old_name)?,
            validate_remote_arg(&new_name)?,
        );
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["remote", "rename", &old_name, &new_name])?;
        Ok(())
    }

    pub fn remove_remote(&self, name: String) -> Result<(), GitCraftError> {
        let name = validate_remote_arg(&name)?;
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["remote", "remove", &name])?;
        Ok(())
    }

    pub fn fetch_remote(&self, name: String, include_tags: bool) -> Result<(), GitCraftError> {
        let name = validate_remote_arg(&name)?;
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let mut args = vec!["fetch", "--prune"];
        if include_tags {
            args.push("--tags");
        }
        args.push(&name);
        git_cli::mutate(&self.path, &args)?;
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
        let branch_name = validate_ref_arg(&branch_name)?;
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
        git_cli::mutate(&self.path, &args)?;
        Ok(())
    }

    pub fn delete_branch(&self, branch_name: String, force: bool) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let branch_name = validate_ref_arg(&branch_name)?;
        let flag = if force { "-D" } else { "-d" };
        git_cli::mutate(&self.path, &["branch", flag, &branch_name])?;
        Ok(())
    }

    /// Deletes `remote/branch` on its remote with `git push <remote> --delete <branch>`.
    /// The local remote-tracking ref is pruned by git as part of the push.
    pub fn delete_remote_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let branch_name = validate_ref_arg(&branch_name)?;
        let (remote, branch) = branch_name
            .split_once('/')
            .ok_or_else(|| GitCraftError::message("not a remote branch"))?;
        let remote = validate_remote_arg(remote)?;
        let branch = validate_ref_arg(branch)?;
        git_cli::mutate(&self.path, &["push", &remote, "--delete", &branch])?;
        Ok(())
    }

    pub fn merge_branch(&self, branch_name: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let branch_name = validate_ref_arg(&branch_name)?;
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

    /// Rebases the checked-out branch onto `commit`.
    pub fn rebase_onto(&self, commit: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let commit = validate_ref_arg(&commit)?;
        git_cli::mutate(&self.path, &["rebase", &commit])?;
        Ok(())
    }

    /// Moves the checked-out branch to `commit`, as `git reset --<mode>`.
    pub fn reset_to(&self, commit: String, mode: ResetMode) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let commit = validate_ref_arg(&commit)?;
        let flag = match mode {
            ResetMode::Soft => "--soft",
            ResetMode::Mixed => "--mixed",
            ResetMode::Hard => "--hard",
        };
        git_cli::mutate(&self.path, &["reset", flag, &commit])?;
        Ok(())
    }

    /// Applies `commit`'s changes on top of the checked-out branch.
    pub fn cherry_pick(&self, commit: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let commit = validate_ref_arg(&commit)?;
        git_cli::mutate(&self.path, &["cherry-pick", &commit])?;
        Ok(())
    }

    /// Creates a commit that undoes `commit`, keeping git's default message.
    pub fn revert_commit(&self, commit: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let commit = validate_ref_arg(&commit)?;
        git_cli::mutate(&self.path, &["revert", "--no-edit", &commit])?;
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
        git_cli::mutate(&self.path, &["--literal-pathspecs", "add", "--", &path])?;
        Ok(())
    }

    pub fn unstage(&self, path: String) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
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
        if has_head(&self.path) {
            git_cli::mutate(&self.path, &["reset", "HEAD"])?;
        } else {
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

    /// Commits with the Skip Hooks (`--no-verify`) and Amend (`--amend`) options.
    pub fn commit_with_options(
        &self,
        message: String,
        skip_hooks: bool,
        amend: bool,
    ) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let mut args = vec!["commit", "-m", &message];
        if skip_hooks {
            args.push("--no-verify");
        }
        if amend {
            args.push("--amend");
        }
        git_cli::mutate(&self.path, &args)?;
        Ok(())
    }

    /// The full message of HEAD, used to fill the composer when amending.
    pub fn head_commit_message(&self) -> Result<String, GitCraftError> {
        let output = git_cli::run(&self.path, &["log", "-1", "--format=%B"])?;
        Ok(output.trim_end().to_owned())
    }

    pub fn fetch(&self, include_tags: bool) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        let mut args = vec!["fetch", "--prune"];
        if include_tags {
            args.push("--tags");
        }
        git_cli::mutate(&self.path, &args)?;
        Ok(())
    }

    pub fn pull(&self, strategy: PullStrategy) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        match strategy {
            PullStrategy::GitConfig => match git_cli::mutate(&self.path, &["pull"]) {
                Ok(()) => Ok(()),
                // With no pull.rebase/pull.ff configured, git refuses diverged pulls. Fall
                // back to a merge, which is what git did before it started asking.
                Err(e) if e.to_string().contains("divergent branches") => {
                    git_cli::mutate(&self.path, &["pull", "--no-rebase"])?;
                    Ok(())
                }
                Err(e) => Err(e.into()),
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
        }
    }

    pub fn abort_rebase(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["rebase", "--abort"])?;
        Ok(())
    }

    /// Continues a stopped rebase after conflicts were resolved and staged. The editor is
    /// disabled so git keeps the existing commit message instead of waiting on one.
    pub fn continue_rebase(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        git_cli::mutate(
            &self.path,
            &["-c", "core.editor=true", "rebase", "--continue"],
        )?;
        Ok(())
    }

    pub fn push(&self) -> Result<(), GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
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
        let needs_escape =
            matches!(c, '*' | '?' | '[' | '\\') || (i == 0 && matches!(c, '#' | '!'));
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

/// True when `full_ref` (e.g. `refs/heads/main`) exists.
fn ref_exists(repo: &std::path::Path, full_ref: &str) -> bool {
    git_cli::run(repo, &["show-ref", "--verify", "-q", full_ref]).is_ok()
}

/// Turns the `## ...` header of `git status --branch` into a plain branch string:
/// "No commits yet on main" -> "main", "HEAD (no branch)" -> "HEAD (detached)".
/// An upstream (`main...origin/main [ahead 1]`) is left for callers to split off.
fn clean_branch_header(header: &str) -> String {
    let header = header.trim_start_matches("## ");
    for prefix in ["No commits yet on ", "Initial commit on "] {
        if let Some(rest) = header.strip_prefix(prefix) {
            return rest.to_owned();
        }
    }
    if header.starts_with("HEAD (no branch)") {
        return "HEAD (detached)".to_owned();
    }
    header.to_owned()
}

/// True when HEAD resolves to a commit (false in a repository with no commits yet).
fn has_head(repo: &std::path::Path) -> bool {
    git_cli::run(repo, &["rev-parse", "--verify", "-q", "HEAD"]).is_ok()
}

/// Trims a branch/tag/revision argument and rejects empty values or ones git would
/// parse as command-line options (e.g. a branch named `--force`).
fn validate_ref_arg(value: &str) -> Result<String, GitCraftError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(GitCraftError::message("name must not be empty"));
    }
    if value.starts_with('-') {
        return Err(GitCraftError::message(format!(
            "invalid name \"{value}\": it must not start with \"-\""
        )));
    }
    Ok(value.to_owned())
}

/// Trims a remote name/URL and rejects empty values or ones git would parse as options.
fn validate_remote_arg(value: &str) -> Result<String, GitCraftError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(GitCraftError::message(
            "remote name and URL must not be empty",
        ));
    }
    if value.starts_with('-') {
        return Err(GitCraftError::message(format!(
            "invalid remote value \"{value}\""
        )));
    }
    Ok(value.to_owned())
}
