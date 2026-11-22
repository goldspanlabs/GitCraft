mod diff;
mod git_cli;
mod graph;
mod highlight;
mod watcher;

use std::{
    io,
    path::PathBuf,
    sync::{Arc, Mutex},
};

#[derive(Debug, thiserror::Error)]
pub enum MiniGitError {
    #[error("{msg}")]
    Message { msg: String },
}

impl MiniGitError {
    pub fn message(msg: impl Into<String>) -> Self {
        Self::Message { msg: msg.into() }
    }
}

impl From<io::Error> for MiniGitError {
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
    pub spans: Vec<StyleSpan>,
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
}

#[derive(Clone, Debug)]
pub struct TagInfo {
    pub name: String,
    pub full_ref: String,
    pub target_oid_hex: String,
}

#[derive(Clone, Debug)]
pub struct RepoStatus {
    pub files: Vec<String>,
    pub branch: String,
    pub is_clean: bool,
}

pub struct RepoSession {
    path: PathBuf,
    sync_repo: gix::ThreadSafeRepository,
    mutation_lock: Arc<Mutex<()>>,
}

impl RepoSession {
    pub fn new(path: String) -> Result<Self, MiniGitError> {
        Self::open(path)
    }

    pub fn open(path: impl Into<PathBuf>) -> Result<Self, MiniGitError> {
        let path = path.into();
        if !path.join(".git").exists() {
            return Err(MiniGitError::message("not a Git repository"));
        }
        let sync_repo = gix::ThreadSafeRepository::open(&path)
            .map_err(|e| MiniGitError::message(e.to_string()))?;
        Ok(Self {
            path,
            sync_repo,
            mutation_lock: Arc::new(Mutex::new(())),
        })
    }

    pub fn status(&self) -> Result<RepoStatus, MiniGitError> {
        let output = git_cli::run(&self.path, &["status", "--short", "--branch"])?;
        let mut lines = output.lines();
        let branch = lines
            .next()
            .unwrap_or_default()
            .trim_start_matches("## ")
            .to_owned();
        let files = lines
            .filter_map(|line| line.get(3..).map(str::to_owned))
            .collect::<Vec<_>>();
        Ok(RepoStatus {
            is_clean: files.is_empty(),
            files,
            branch,
        })
    }

    pub fn get_commit_graph(
        &self,
        offset: u32,
        limit: u32,
        search_query: Option<String>,
    ) -> Result<Vec<CommitRow>, MiniGitError> {
        graph::get_commit_graph(&self.sync_repo, offset, limit, search_query)
    }

    pub fn list_branches(&self) -> Result<Vec<BranchInfo>, MiniGitError> {
        graph::list_branches(&self.sync_repo)
    }

    pub fn list_tags(&self) -> Result<Vec<TagInfo>, MiniGitError> {
        graph::list_tags(&self.sync_repo)
    }

    pub fn checkout_branch(&self, branch_name: String) -> Result<(), MiniGitError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| MiniGitError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["checkout", &branch_name])?;
        Ok(())
    }

    pub fn diff(&self) -> Result<Vec<DiffRow>, MiniGitError> {
        Ok(diff::working_tree(&self.path)?)
    }

    pub fn stage(&self, path: String) -> Result<(), MiniGitError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| MiniGitError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["add", "--", &path])?;
        Ok(())
    }

    pub fn unstage(&self, path: String) -> Result<(), MiniGitError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| MiniGitError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["reset", "HEAD", "--", &path])?;
        Ok(())
    }

    pub fn commit(&self, message: String) -> Result<(), MiniGitError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| MiniGitError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["commit", "-m", &message])?;
        Ok(())
    }

    pub fn fetch(&self) -> Result<(), MiniGitError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| MiniGitError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["fetch"])?;
        Ok(())
    }

    pub fn pull(&self) -> Result<(), MiniGitError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| MiniGitError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["pull"])?;
        Ok(())
    }

    pub fn push(&self) -> Result<(), MiniGitError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| MiniGitError::message("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["push"])?;
        Ok(())
    }

    pub fn highlight(&self, text: &str, extension: &str) -> Vec<StyleSpan> {
        highlight::highlight(text, extension)
    }

    pub fn watch(&self, events: std::sync::mpsc::Sender<()>) -> io::Result<()> {
        watcher::watch(&self.path, events)
    }
}

uniffi::include_scaffolding!("minigit_core");
