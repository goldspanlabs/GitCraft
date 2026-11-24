#![allow(clippy::empty_line_after_doc_comments)]

mod diff;
mod git_cli;
mod graph;
mod highlight;
mod models;
mod ops;
mod status;
mod validation;
mod watcher;

pub use models::*;

use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU8, Ordering},
        Arc, Mutex,
    },
};

pub struct RepoSession {
    pub(crate) path: PathBuf,
    sync_repo: gix::ThreadSafeRepository,
    mutation_lock: Arc<Mutex<()>>,
    dirty: Arc<AtomicBool>,
    graph_dirty: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
    commit_sort: AtomicU8,
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
            commit_sort: AtomicU8::new(0),
        })
    }

    /// Serializes mutating git operations against this session so concurrent UI requests
    /// never race on `.git/index.lock` or ref updates.
    pub(crate) fn with_mutation_lock<T>(
        &self,
        f: impl FnOnce() -> Result<T, GitCraftError>,
    ) -> Result<T, GitCraftError> {
        let _guard = self
            .mutation_lock
            .lock()
            .map_err(|_| GitCraftError::message("mutation queue poisoned"))?;
        f()
    }

    /// Acquires the session mutation lock and executes a single mutating git CLI command.
    pub(crate) fn mutate(&self, args: &[&str]) -> Result<(), GitCraftError> {
        self.with_mutation_lock(|| {
            git_cli::mutate(&self.path, args)?;
            Ok(())
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

    pub fn highlight(&self, text: &str, extension: &str) -> Vec<StyleSpan> {
        highlight::highlight(text, extension)
    }
}

uniffi::include_scaffolding!("gitcraft_core");
