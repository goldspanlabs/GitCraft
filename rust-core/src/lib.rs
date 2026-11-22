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

#[derive(Clone, Debug)]
pub struct GraphEdge {
    pub from_lane: u32,
    pub to_lane: u32,
    pub is_merge: bool,
    pub color_idx: usize,
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
    pub hash: String,
    pub author: String,
    pub timestamp: i64,
    pub summary: String,
    pub lane: u32,
    pub max_lanes: u32,
    pub edges: Vec<GraphEdge>,
}
#[derive(Clone, Debug)]
pub struct RepoStatus {
    pub files: Vec<String>,
    pub branch: String,
    pub is_clean: bool,
}

pub struct RepoSession {
    path: PathBuf,
    mutation_lock: Arc<Mutex<()>>,
}
impl RepoSession {
    pub fn open(path: impl Into<PathBuf>) -> io::Result<Self> {
        let path = path.into();
        if !path.join(".git").exists() {
            return Err(io::Error::other("not a Git repository"));
        }
        Ok(Self {
            path,
            mutation_lock: Arc::new(Mutex::new(())),
        })
    }
    pub fn status(&self) -> io::Result<RepoStatus> {
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
    pub fn history(&self, limit: usize) -> io::Result<Vec<CommitRow>> {
        graph::history(&self.path, limit)
    }
    pub fn diff(&self) -> io::Result<Vec<DiffRow>> {
        diff::working_tree(&self.path)
    }
    pub fn stage(&self, path: &str) -> io::Result<()> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| io::Error::other("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["add", "--", path])
    }
    pub fn unstage(&self, path: &str) -> io::Result<()> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| io::Error::other("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["reset", "HEAD", "--", path])
    }
    pub fn commit(&self, message: &str) -> io::Result<()> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| io::Error::other("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["commit", "-m", message])
    }
    pub fn checkout(&self, branch: &str) -> io::Result<()> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| io::Error::other("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["checkout", branch])
    }
    pub fn fetch(&self) -> io::Result<()> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| io::Error::other("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["fetch"])
    }
    pub fn pull(&self) -> io::Result<()> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| io::Error::other("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["pull"])
    }
    pub fn push(&self) -> io::Result<()> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| io::Error::other("mutation queue poisoned"))?;
        git_cli::mutate(&self.path, &["push"])
    }
    pub fn highlight(&self, text: &str, extension: &str) -> Vec<StyleSpan> {
        highlight::highlight(text, extension)
    }
    pub fn watch(&self, events: std::sync::mpsc::Sender<()>) -> io::Result<()> {
        watcher::watch(&self.path, events)
    }
}
