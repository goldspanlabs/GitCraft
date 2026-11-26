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
mod worktree;

pub use models::*;
pub use ops::{clone_repository, init_repository};
pub use worktree::WorktreeInfo;

/// Checks whether the `git` CLI is installed and runnable.
pub fn check_git_availability() -> GitAvailability {
    git_cli::check_availability()
}

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU8, Ordering},
        Arc, Mutex, OnceLock,
    },
};

/// One mutation lock per repository (keyed by its canonical common dir), shared by every
/// session that opens it. A session per checkout or window would otherwise each hold its own
/// lock and race on refs and `.git/index.lock`.
fn mutation_lock_for(common_dir: PathBuf) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
    let key = std::fs::canonicalize(&common_dir).unwrap_or(common_dir);
    let mut locks = LOCKS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    Arc::clone(locks.entry(key).or_default())
}

pub struct RepoSession {
    pub(crate) path: PathBuf,
    pub(crate) sync_repo: gix::ThreadSafeRepository,
    mutation_lock: Arc<Mutex<()>>,
    dirty: Arc<AtomicBool>,
    graph_dirty: Arc<AtomicBool>,
    worktrees_dirty: Arc<AtomicBool>,
    watcher_ready: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
    commit_sort: AtomicU8,
    graph_cache: graph::SharedGraphCache,
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

    /// The canonical path of the repository's shared Git directory. Every checkout of one
    /// repository reports the same value, so it identifies the repository itself and stays
    /// valid after a linked worktree is deleted or pruned.
    pub fn common_dir(&self) -> String {
        let dir = self.sync_repo.to_thread_local().common_dir().to_owned();
        std::fs::canonicalize(&dir)
            .unwrap_or(dir)
            .to_string_lossy()
            .into_owned()
    }

    pub fn open(path: impl Into<PathBuf>) -> Result<Self, GitCraftError> {
        let path = path.into();
        if !path.join(".git").exists() {
            return Err(GitCraftError::message("not a Git repository"));
        }
        let sync_repo = gix::ThreadSafeRepository::open(&path)
            .map_err(|e| GitCraftError::message(e.to_string()))?;
        let (git_dir, common_dir) = {
            let repo = sync_repo.to_thread_local();
            (repo.git_dir().to_owned(), repo.common_dir().to_owned())
        };
        let dirty = Arc::new(AtomicBool::new(false));
        let graph_dirty = Arc::new(AtomicBool::new(false));
        let worktrees_dirty = Arc::new(AtomicBool::new(false));
        let watcher_ready = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(AtomicBool::new(false));
        watcher::spawn_dirty_watcher(
            &path,
            &git_dir,
            &common_dir,
            watcher::WatchFlags {
                status_dirty: Arc::clone(&dirty),
                graph_dirty: Arc::clone(&graph_dirty),
                worktrees_dirty: Arc::clone(&worktrees_dirty),
                ready: Arc::clone(&watcher_ready),
                stopped: Arc::clone(&stopped),
            },
        );
        Ok(Self {
            path,
            sync_repo,
            mutation_lock: mutation_lock_for(common_dir),
            dirty,
            graph_dirty,
            worktrees_dirty,
            watcher_ready,
            stopped,
            commit_sort: AtomicU8::new(0),
            graph_cache: Default::default(),
        })
    }

    /// Whether the background watcher has set up its watches. Not part of the app's API:
    /// tests wait for this before making the change they expect to be noticed.
    #[doc(hidden)]
    pub fn is_watcher_ready(&self) -> bool {
        self.watcher_ready.load(Ordering::Acquire)
    }

    /// Serializes mutating git operations on this repository so concurrent UI requests, even
    /// from different sessions, never race on `.git/index.lock` or ref updates.
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

    /// True if an inactive sibling worktree's working tree or index changed, so sidebar
    /// dirty counts need refreshing without touching the active checkout's status or graph.
    pub fn take_worktrees_dirty(&self) -> bool {
        self.worktrees_dirty.swap(false, Ordering::AcqRel)
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
            &self.graph_cache,
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
            &self.graph_cache,
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
        diff::commit_diff(&self.path, &oid_hex, path.as_deref())
    }

    pub fn get_working_diff(
        &self,
        path: Option<String>,
        staged: bool,
    ) -> Result<Vec<DiffRow>, GitCraftError> {
        diff::working_tree_file(&self.path, path.as_deref(), staged)
    }

    pub fn list_branches(&self) -> Result<Vec<BranchInfo>, GitCraftError> {
        graph::list_branches(&self.path, &self.sync_repo)
    }

    pub fn list_tags(&self) -> Result<Vec<TagInfo>, GitCraftError> {
        graph::list_tags(&self.sync_repo)
    }

    pub fn highlight(&self, text: &str, extension: &str) -> Vec<StyleSpan> {
        highlight::highlight(text, extension)
    }
}

uniffi::include_scaffolding!("gitcraft_core");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_of_one_repository_share_a_mutation_lock() {
        let dir = tempfile::tempdir().unwrap();
        let git_dir = dir.path().join(".git");
        std::fs::create_dir(&git_dir).unwrap();
        let other = tempfile::tempdir().unwrap();
        let a = mutation_lock_for(git_dir.clone());
        let b = mutation_lock_for(git_dir.join("../.git"));
        let c = mutation_lock_for(other.path().to_path_buf());
        assert!(Arc::ptr_eq(&a, &b));
        assert!(!Arc::ptr_eq(&a, &c));
    }
}
