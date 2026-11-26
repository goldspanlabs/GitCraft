use crate::{git_cli, worktree};
use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    collections::HashSet,
    fs,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};

/// What a filesystem event means for the UI.
#[derive(Debug, PartialEq, Eq)]
enum Change {
    /// Nothing the UI shows depends on it (objects, logs, lock files).
    Irrelevant,
    /// Working tree or index changed: only `git status` needs re-reading.
    Status,
    /// Refs, HEAD or config changed: the graph, branches, tags and remotes may differ too.
    Graph,
    /// Files or index changed in an inactive sibling worktree: only sidebar dirty counts need re-reading.
    Worktrees,
}

fn canonical_or_owned(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_owned())
}

/// Normalizes a relative path under a git directory to forward-slash components so
/// classification is independent of platform path separators.
fn relative_slash_path(path: &Path, base: &Path) -> Option<String> {
    let rel = path.strip_prefix(base).ok()?;
    let joined = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/");
    if joined.is_empty() {
        None
    } else {
        Some(joined)
    }
}

fn classify_inside_git_dir(inside: &str, is_active_worktree: bool) -> Change {
    // Git's own lock files (`index.lock`, `HEAD.lock`, ...) only exist mid-write. Working-tree
    // files such as `Cargo.lock` are real content and are classified by the caller.
    if inside.ends_with(".lock") {
        return Change::Irrelevant;
    }
    if inside.starts_with("objects/") || inside.starts_with("logs/") {
        return Change::Irrelevant;
    }
    // Bookkeeping files that git rewrites next to a change that is already seen through its
    // own file (a ref, HEAD or the index), or that the app refreshes after itself (fetch).
    if matches!(inside, "FETCH_HEAD" | "ORIG_HEAD" | "COMMIT_EDITMSG") {
        return Change::Irrelevant;
    }
    if inside == "index" || inside == "MERGE_HEAD" || inside == "MERGE_MSG" {
        return if is_active_worktree {
            Change::Status
        } else {
            Change::Worktrees
        };
    }
    // Changes under another linked worktree's metadata: reflogs are ignored, index/merge
    // edits refresh sidebar worktree dirty counts, and structural changes (HEAD, locked,
    // new/removed worktrees) still refresh the graph and worktree list. This applies in the
    // primary checkout too, where `worktrees/` sits inside the active git dir. A linked
    // session's own metadata never reaches here as `worktrees/...`, because it matches its
    // own git dir first.
    if inside.starts_with("worktrees/") {
        if inside.contains("/logs/") {
            return Change::Irrelevant;
        }
        if inside.ends_with("/index")
            || inside.ends_with("/MERGE_HEAD")
            || inside.ends_with("/MERGE_MSG")
        {
            return Change::Worktrees;
        }
    }
    Change::Graph
}

fn classify_path(
    path: &Path,
    worktree: &Path,
    git_dir: &Path,
    common_dir: &Path,
    sibling_worktrees: &[PathBuf],
) -> Change {
    if let Some(inside) = relative_slash_path(path, git_dir) {
        return classify_inside_git_dir(&inside, true);
    }
    if common_dir != git_dir {
        if let Some(inside) = relative_slash_path(path, common_dir) {
            return classify_inside_git_dir(&inside, false);
        }
    }
    if path.starts_with(worktree) {
        // A linked checkout nested inside the active one (e.g. `.worktrees/feature`) is still
        // its own sibling: the active checkout's recursive watch sees its edits too, but only
        // its sidebar dirty count should refresh. Ancestor siblings never match here, so the
        // active checkout keeps precedence over them.
        if sibling_worktrees
            .iter()
            .any(|s| s.starts_with(worktree) && path.starts_with(s))
        {
            return Change::Worktrees;
        }
        // Fallback for uncanonicalized event paths containing `/.git/`.
        let text = path.to_string_lossy();
        if let Some((_, inside)) = text.split_once("/.git/") {
            return classify_inside_git_dir(inside, common_dir == git_dir);
        }
        return Change::Status;
    }
    if sibling_worktrees.iter().any(|s| path.starts_with(s)) {
        return Change::Worktrees;
    }
    // Fallback for uncanonicalized event paths containing `/.git/`.
    let text = path.to_string_lossy();
    if let Some((_, inside)) = text.split_once("/.git/") {
        return classify_inside_git_dir(inside, common_dir == git_dir);
    }
    Change::Status
}

/// Checkout folders registered under `common_dir/worktrees/<name>/gitdir`. Each `gitdir` file
/// holds the path of that checkout's `.git` file, so its parent is the checkout folder.
fn registered_worktree_paths(common_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(common_dir.join("worktrees")) else {
        return Vec::new();
    };
    entries
        .filter_map(Result::ok)
        .filter_map(|entry| fs::read_to_string(entry.path().join("gitdir")).ok())
        .filter_map(|text| Path::new(text.trim_end()).parent().map(Path::to_path_buf))
        .map(|p| canonical_or_owned(&p))
        .collect()
}

/// The sibling checkouts to classify and watch: the ones known when the session opened, plus
/// any registered since. Entries whose folder is gone are dropped.
fn current_siblings(worktree: &Path, initial: &[PathBuf], common_dir: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = initial.to_vec();
    paths.extend(registered_worktree_paths(common_dir));
    paths.sort();
    paths.dedup();
    paths
        .into_iter()
        .filter(|p| p != worktree && p.is_dir())
        .collect()
}

/// Brings the sibling watches in line with `siblings`: drops watches for checkouts that are
/// gone, so one re-created at the same path is watched afresh, and adds watches for new ones.
/// Siblings inside the active checkout are already covered by its recursive watch.
fn sync_sibling_watches(
    watcher: &mut RecommendedWatcher,
    watched: &mut Vec<PathBuf>,
    worktree: &Path,
    siblings: &[PathBuf],
) {
    watched.retain(|path| {
        if siblings.contains(path) {
            return true;
        }
        // The backend may already have dropped the watch when the folder was deleted.
        let _ = watcher.unwatch(path);
        false
    });
    for sibling in siblings {
        if sibling.starts_with(worktree) || watched.contains(sibling) {
            continue;
        }
        if watcher.watch(sibling, RecursiveMode::Recursive).is_ok() {
            watched.push(sibling.clone());
        }
    }
}

/// Shared atomic flags raised by the background filesystem watcher.
pub struct WatchFlags {
    pub status_dirty: Arc<AtomicBool>,
    pub graph_dirty: Arc<AtomicBool>,
    pub worktrees_dirty: Arc<AtomicBool>,
    /// Set once the watches are in place; changes made before that can go unnoticed.
    pub ready: Arc<AtomicBool>,
    pub stopped: Arc<AtomicBool>,
}

/// How often the polling fallback marks everything dirty.
const POLL_FALLBACK_INTERVAL: Duration = Duration::from_secs(3);

/// Used when file watching can't start: marks status and graph dirty on a timer, so the UI
/// still refreshes (at the cost of a periodic reload) instead of silently going stale.
fn poll_until_stopped(
    (status_dirty, graph_dirty, stopped): (Arc<AtomicBool>, Arc<AtomicBool>, Arc<AtomicBool>),
    interval: Duration,
) {
    while !stopped.load(Ordering::Acquire) {
        thread::sleep(interval);
        status_dirty.store(true, Ordering::Release);
        graph_dirty.store(true, Ordering::Release);
    }
}

/// Past this many changed files between two looks, they are not checked against the ignore
/// rules: the checkout is simply reported as changed.
const MAX_PENDING_FILES: usize = 20_000;

/// True unless git ignores every one of `files`, so none can appear in `git status`. Tracked
/// files are never ignored, whatever the rules say. Any doubt counts as a visible change.
fn any_visible_to_git(worktree: &Path, files: &HashSet<PathBuf>) -> bool {
    let mut input = Vec::new();
    for file in files {
        match file.strip_prefix(worktree) {
            Ok(relative) if !relative.as_os_str().is_empty() => {
                input.extend_from_slice(relative.as_os_str().as_bytes());
                input.push(0);
            }
            _ => return true,
        }
    }
    match git_cli::run_status_with_input(worktree, &["check-ignore", "--stdin", "-z"], input) {
        // Exit status 0 lists the ignored paths; 1 means none are, and anything else is a failure.
        Ok(output) if output.status.success() => output.stdout.matches('\0').count() < files.len(),
        _ => true,
    }
}

/// Watches the checkout (plus its gitdir, commondir, and any sibling worktrees)
/// and raises:
/// - `status_dirty` when the active checkout's index or a working-tree file that git doesn't
///   ignore changes,
/// - `graph_dirty` when refs, HEAD, config, or worktree structure changes,
/// - `worktrees_dirty` when an inactive sibling worktree's working tree or index changes.
///
/// Graph-level events also re-scan the registered worktrees, so a checkout added after the
/// session opened gets watched and classified too.
pub fn spawn_dirty_watcher(repo: &Path, git_dir: &Path, common_dir: &Path, flags: WatchFlags) {
    let worktree = canonical_or_owned(repo);
    let git_dir = canonical_or_owned(git_dir);
    let common_dir = canonical_or_owned(common_dir);
    thread::spawn(move || {
        // Asked here so that opening a repository doesn't wait for another git command.
        let initial_siblings: Vec<PathBuf> = worktree::list_entries(&worktree)
            .unwrap_or_default()
            .into_iter()
            .filter(|w| !w.is_prunable)
            .map(|w| canonical_or_owned(Path::new(&w.path)))
            .filter(|p| p != &worktree && p.is_dir())
            .collect();
        let shared_siblings = Arc::new(Mutex::new(initial_siblings.clone()));
        // Starts raised so the first loop pass registers siblings created before this thread ran.
        let reconcile = Arc::new(AtomicBool::new(true));
        let cb_worktree = worktree.clone();
        let cb_git_dir = git_dir.clone();
        let cb_common_dir = common_dir.clone();
        let cb_siblings = Arc::clone(&shared_siblings);
        let cb_reconcile = Arc::clone(&reconcile);
        let fallback = (
            Arc::clone(&flags.status_dirty),
            Arc::clone(&flags.graph_dirty),
            Arc::clone(&flags.stopped),
        );
        let status_dirty = flags.status_dirty;
        let callback_status_dirty = Arc::clone(&status_dirty);
        // Changed working-tree files waiting to be checked against the ignore rules.
        let pending = Arc::new(Mutex::new(HashSet::new()));
        let cb_pending = Arc::clone(&pending);
        let graph_dirty = flags.graph_dirty;
        let worktrees_dirty = flags.worktrees_dirty;
        let stopped = flags.stopped;
        let ready = flags.ready;
        let callback = move |result: notify::Result<Event>| {
            let Ok(event) = result else { return };
            let Ok(siblings) = cb_siblings.lock() else {
                return;
            };
            for p in &event.paths {
                match classify_path(p, &cb_worktree, &cb_git_dir, &cb_common_dir, &siblings) {
                    Change::Irrelevant => {}
                    Change::Status => {
                        let is_file = !p.starts_with(&cb_git_dir)
                            && !p.starts_with(&cb_common_dir)
                            && !p.to_string_lossy().contains("/.git/");
                        match cb_pending.lock() {
                            Ok(mut files) if is_file && files.len() < MAX_PENDING_FILES => {
                                files.insert(p.clone());
                            }
                            _ => callback_status_dirty.store(true, Ordering::Release),
                        }
                    }
                    Change::Worktrees => worktrees_dirty.store(true, Ordering::Release),
                    Change::Graph => {
                        callback_status_dirty.store(true, Ordering::Release);
                        graph_dirty.store(true, Ordering::Release);
                        cb_reconcile.store(true, Ordering::Release);
                    }
                }
            }
        };
        let mut watcher = match RecommendedWatcher::new(
            callback,
            Config::default().with_poll_interval(Duration::from_millis(500)),
        ) {
            Ok(w) => w,
            Err(_) => {
                ready.store(true, Ordering::Release);
                return poll_until_stopped(fallback, POLL_FALLBACK_INTERVAL);
            }
        };
        // Without a watch on the checkout (the OS watch limit, say) nothing would ever refresh.
        if watcher.watch(&worktree, RecursiveMode::Recursive).is_err() {
            ready.store(true, Ordering::Release);
            return poll_until_stopped(fallback, POLL_FALLBACK_INTERVAL);
        }
        // Linked worktrees keep their metadata outside the checkout folder (`.git` is a file).
        if !common_dir.starts_with(&worktree) {
            let _ = watcher.watch(&common_dir, RecursiveMode::Recursive);
        }
        if !git_dir.starts_with(&worktree) && !git_dir.starts_with(&common_dir) {
            let _ = watcher.watch(&git_dir, RecursiveMode::Recursive);
        }
        let mut watched: Vec<PathBuf> = Vec::new();
        while !stopped.load(Ordering::Acquire) {
            if reconcile.swap(false, Ordering::AcqRel) {
                let siblings = current_siblings(&worktree, &initial_siblings, &common_dir);
                sync_sibling_watches(&mut watcher, &mut watched, &worktree, &siblings);
                if let Ok(mut shared) = shared_siblings.lock() {
                    *shared = siblings;
                }
                ready.store(true, Ordering::Release);
            }
            let files = pending
                .lock()
                .map(|mut files| std::mem::take(&mut *files))
                .unwrap_or_default();
            // Nothing to find out while a change is already waiting to be picked up.
            if !files.is_empty()
                && !status_dirty.load(Ordering::Acquire)
                && any_visible_to_git(&worktree, &files)
            {
                status_dirty.store(true, Ordering::Release);
            }
            thread::sleep(Duration::from_millis(250));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_events_in_primary_checkout() {
        let worktree = Path::new("/r");
        let git_dir = Path::new("/r/.git");
        let siblings = vec![PathBuf::from("/wt/feature")];
        let classify = |p: &str| classify_path(Path::new(p), worktree, git_dir, git_dir, &siblings);

        assert_eq!(classify("/r/src/main.rs"), Change::Status);
        assert_eq!(classify("/r/target/debug/foo"), Change::Status);
        assert_eq!(classify("/r/.git/index"), Change::Status);
        assert_eq!(classify("/r/.git/index.lock"), Change::Irrelevant);
        assert_eq!(classify("/r/.git/refs/heads/main.lock"), Change::Irrelevant);
        // Lock files in the working tree are ordinary content.
        assert_eq!(classify("/r/Cargo.lock"), Change::Status);
        assert_eq!(classify("/r/app/Podfile.lock"), Change::Status);
        assert_eq!(classify("/r/.git/objects/ab/cdef"), Change::Irrelevant);
        assert_eq!(classify("/r/.git/logs/HEAD"), Change::Irrelevant);
        assert_eq!(classify("/r/.git/FETCH_HEAD"), Change::Irrelevant);
        assert_eq!(classify("/r/.git/ORIG_HEAD"), Change::Irrelevant);
        assert_eq!(classify("/r/.git/COMMIT_EDITMSG"), Change::Irrelevant);
        assert_eq!(classify("/r/.git/HEAD"), Change::Graph);
        assert_eq!(classify("/r/.git/refs/heads/main"), Change::Graph);
        assert_eq!(classify("/r/.git/packed-refs"), Change::Graph);
        assert_eq!(classify("/r/.git/config"), Change::Graph);
        assert_eq!(classify("/wt/feature/README.md"), Change::Worktrees);
        // A sibling's metadata lives inside the primary checkout's git dir: index, merge state
        // and reflogs only touch sidebar dirty counts, while structural changes still reload.
        assert_eq!(
            classify("/r/.git/worktrees/feature/index"),
            Change::Worktrees
        );
        assert_eq!(
            classify("/r/.git/worktrees/feature/MERGE_HEAD"),
            Change::Worktrees
        );
        assert_eq!(
            classify("/r/.git/worktrees/feature/MERGE_MSG"),
            Change::Worktrees
        );
        assert_eq!(
            classify("/r/.git/worktrees/feature/logs/HEAD"),
            Change::Irrelevant
        );
        assert_eq!(classify("/r/.git/worktrees/feature/HEAD"), Change::Graph);
        assert_eq!(classify("/r/.git/worktrees/feature/locked"), Change::Graph);
    }

    #[test]
    fn classifies_nested_sibling_checkout_as_worktree_not_active_status() {
        let worktree = Path::new("/repo");
        let git_dir = Path::new("/repo/.git");
        let siblings = vec![PathBuf::from("/repo/.worktrees/feature")];
        let classify = |p: &str| classify_path(Path::new(p), worktree, git_dir, git_dir, &siblings);

        assert_eq!(
            classify("/repo/.worktrees/feature/src/a.rs"),
            Change::Worktrees
        );
        assert_eq!(classify("/repo/src/a.rs"), Change::Status);
    }

    #[test]
    fn active_checkout_keeps_precedence_over_ancestor_sibling() {
        let worktree = Path::new("/wt/feature");
        let git_dir = Path::new("/repo/.git/worktrees/feature");
        let common_dir = Path::new("/repo/.git");
        let siblings = vec![PathBuf::from("/wt")];
        let classify =
            |p: &str| classify_path(Path::new(p), worktree, git_dir, common_dir, &siblings);

        assert_eq!(classify("/wt/feature/src/lib.rs"), Change::Status);
        assert_eq!(classify("/wt/other/file.txt"), Change::Worktrees);
    }

    #[test]
    fn classifies_events_in_linked_worktree() {
        let worktree = Path::new("/wt/feature");
        let common_dir = Path::new("/repo/.git");
        let git_dir = Path::new("/repo/.git/worktrees/feature");
        let siblings = vec![PathBuf::from("/repo"), PathBuf::from("/wt/other")];
        let classify =
            |p: &str| classify_path(Path::new(p), worktree, git_dir, common_dir, &siblings);

        assert_eq!(classify("/wt/feature/src/lib.rs"), Change::Status);
        assert_eq!(
            classify("/repo/.git/worktrees/feature/index"),
            Change::Status
        );
        assert_eq!(
            classify("/repo/.git/worktrees/feature/index.lock"),
            Change::Irrelevant
        );
        assert_eq!(
            classify("/repo/.git/worktrees/feature/MERGE_HEAD"),
            Change::Status
        );
        assert_eq!(classify("/repo/.git/worktrees/feature/HEAD"), Change::Graph);
        assert_eq!(
            classify("/repo/.git/worktrees/feature/locked"),
            Change::Graph
        );
        assert_eq!(classify("/repo/.git/refs/heads/feature"), Change::Graph);
        assert_eq!(classify("/repo/.git/packed-refs"), Change::Graph);
        assert_eq!(classify("/repo/.git/objects/12/3456"), Change::Irrelevant);
        assert_eq!(
            classify("/repo/.git/logs/refs/heads/feature"),
            Change::Irrelevant
        );
        // Primary checkout and sibling worktree edits/index updates refresh worktree dirty counts
        // without marking the active checkout's own status or graph dirty.
        assert_eq!(classify("/repo/.git/index"), Change::Worktrees);
        assert_eq!(
            classify("/repo/.git/worktrees/other/index"),
            Change::Worktrees
        );
        assert_eq!(classify("/repo/README.md"), Change::Worktrees);
        assert_eq!(classify("/wt/other/file.txt"), Change::Worktrees);
        assert_eq!(classify("/repo/.git/worktrees/other/HEAD"), Change::Graph);
    }

    #[test]
    fn registered_worktrees_are_found_from_gitdir_files() {
        let repo = tempfile::tempdir().unwrap();
        let checkout = tempfile::tempdir().unwrap();
        let common_dir = repo.path().join(".git");
        let meta = common_dir.join("worktrees").join("feature");
        fs::create_dir_all(&meta).unwrap();
        fs::write(
            meta.join("gitdir"),
            format!("{}\n", checkout.path().join(".git").display()),
        )
        .unwrap();

        let found = registered_worktree_paths(&common_dir);
        assert_eq!(found, vec![canonical_or_owned(checkout.path())]);

        let siblings = current_siblings(Path::new("/nowhere"), &[], &common_dir);
        assert_eq!(siblings, vec![canonical_or_owned(checkout.path())]);

        // A registration whose folder has been deleted is not watched.
        fs::remove_dir_all(checkout.path()).unwrap();
        assert!(current_siblings(Path::new("/nowhere"), &[], &common_dir).is_empty());
    }

    #[test]
    fn polling_fallback_raises_both_flags_repeatedly_and_stops() {
        let status = Arc::new(AtomicBool::new(false));
        let graph = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(AtomicBool::new(false));
        let flags = (
            Arc::clone(&status),
            Arc::clone(&graph),
            Arc::clone(&stopped),
        );
        let worker = thread::spawn(move || poll_until_stopped(flags, Duration::from_millis(10)));

        let wait_for = |flag: &AtomicBool| {
            for _ in 0..500 {
                if flag.swap(false, Ordering::AcqRel) {
                    return true;
                }
                thread::sleep(Duration::from_millis(10));
            }
            false
        };
        assert!(wait_for(&status) && wait_for(&graph));
        // Cleared flags come back on the next tick.
        assert!(wait_for(&status) && wait_for(&graph));

        stopped.store(true, Ordering::Release);
        worker.join().unwrap();
    }
}
