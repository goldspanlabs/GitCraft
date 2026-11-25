use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    fs,
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
    if inside.starts_with("objects/") || inside.starts_with("logs/") {
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
    if path
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.ends_with(".lock"))
    {
        return Change::Irrelevant;
    }
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
    pub stopped: Arc<AtomicBool>,
}

/// Watches the checkout (plus its gitdir, commondir, and any sibling worktrees)
/// and raises:
/// - `status_dirty` when the active checkout's working tree or index changes,
/// - `graph_dirty` when refs, HEAD, config, or worktree structure changes,
/// - `worktrees_dirty` when an inactive sibling worktree's working tree or index changes.
///
/// Graph-level events also re-scan the registered worktrees, so a checkout added after the
/// session opened gets watched and classified too.
pub fn spawn_dirty_watcher(
    repo: &Path,
    git_dir: &Path,
    common_dir: &Path,
    sibling_worktrees: Vec<PathBuf>,
    flags: WatchFlags,
) {
    let worktree = canonical_or_owned(repo);
    let git_dir = canonical_or_owned(git_dir);
    let common_dir = canonical_or_owned(common_dir);
    let initial_siblings: Vec<PathBuf> = sibling_worktrees
        .into_iter()
        .map(|p| canonical_or_owned(&p))
        .filter(|p| p != &worktree && p.is_dir())
        .collect();
    thread::spawn(move || {
        let shared_siblings = Arc::new(Mutex::new(initial_siblings.clone()));
        // Starts raised so the first loop pass registers siblings created before this thread ran.
        let reconcile = Arc::new(AtomicBool::new(true));
        let cb_worktree = worktree.clone();
        let cb_git_dir = git_dir.clone();
        let cb_common_dir = common_dir.clone();
        let cb_siblings = Arc::clone(&shared_siblings);
        let cb_reconcile = Arc::clone(&reconcile);
        let status_dirty = flags.status_dirty;
        let graph_dirty = flags.graph_dirty;
        let worktrees_dirty = flags.worktrees_dirty;
        let stopped = flags.stopped;
        let callback = move |result: notify::Result<Event>| {
            let Ok(event) = result else { return };
            let Ok(siblings) = cb_siblings.lock() else {
                return;
            };
            for p in &event.paths {
                match classify_path(p, &cb_worktree, &cb_git_dir, &cb_common_dir, &siblings) {
                    Change::Irrelevant => {}
                    Change::Status => status_dirty.store(true, Ordering::Release),
                    Change::Worktrees => worktrees_dirty.store(true, Ordering::Release),
                    Change::Graph => {
                        status_dirty.store(true, Ordering::Release);
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
            Err(_) => return,
        };
        let _ = watcher.watch(&worktree, RecursiveMode::Recursive);
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
            }
            thread::sleep(Duration::from_millis(500));
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
        assert_eq!(classify("/r/.git/objects/ab/cdef"), Change::Irrelevant);
        assert_eq!(classify("/r/.git/logs/HEAD"), Change::Irrelevant);
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
}
