use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
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
            Change::Irrelevant
        };
    }
    // Changes under another linked worktree's metadata (e.g. its index or reflogs) don't
    // affect this checkout's working state; structural changes (HEAD, locked, new/removed
    // worktrees) still refresh the graph and worktree list.
    if !is_active_worktree
        && inside.starts_with("worktrees/")
        && (inside.ends_with("/index")
            || inside.ends_with("/MERGE_HEAD")
            || inside.ends_with("/MERGE_MSG")
            || inside.contains("/logs/"))
    {
        return Change::Irrelevant;
    }
    Change::Graph
}

fn classify_path(path: &Path, git_dir: &Path, common_dir: &Path) -> Change {
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
    // Fallback for uncanonicalized event paths containing `/.git/`.
    let text = path.to_string_lossy();
    if let Some((_, inside)) = text.split_once("/.git/") {
        return classify_inside_git_dir(inside, common_dir == git_dir);
    }
    Change::Status
}

/// Watches the checkout (plus its gitdir and commondir when opened on a linked worktree)
/// and raises `status_dirty` for any relevant change, plus `graph_dirty` when refs, HEAD,
/// config, or worktree metadata changed.
pub fn spawn_dirty_watcher(
    repo: &Path,
    git_dir: &Path,
    common_dir: &Path,
    status_dirty: Arc<AtomicBool>,
    graph_dirty: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
) {
    let worktree = canonical_or_owned(repo);
    let git_dir = canonical_or_owned(git_dir);
    let common_dir = canonical_or_owned(common_dir);
    thread::spawn(move || {
        let cb_git_dir = git_dir.clone();
        let cb_common_dir = common_dir.clone();
        let callback = move |result: notify::Result<Event>| {
            let Ok(event) = result else { return };
            for p in &event.paths {
                match classify_path(p, &cb_git_dir, &cb_common_dir) {
                    Change::Irrelevant => {}
                    Change::Status => status_dirty.store(true, Ordering::Release),
                    Change::Graph => {
                        status_dirty.store(true, Ordering::Release);
                        graph_dirty.store(true, Ordering::Release);
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
        while !stopped.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(500));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_events_in_primary_checkout() {
        let git_dir = Path::new("/r/.git");
        let classify = |p: &str| classify_path(Path::new(p), git_dir, git_dir);

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
    }

    #[test]
    fn classifies_events_in_linked_worktree() {
        let common_dir = Path::new("/repo/.git");
        let git_dir = Path::new("/repo/.git/worktrees/feature");
        let classify = |p: &str| classify_path(Path::new(p), git_dir, common_dir);

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
        // Primary checkout and sibling worktree index churn should not dirty this checkout.
        assert_eq!(classify("/repo/.git/index"), Change::Irrelevant);
        assert_eq!(
            classify("/repo/.git/worktrees/other/index"),
            Change::Irrelevant
        );
        assert_eq!(classify("/repo/.git/worktrees/other/HEAD"), Change::Graph);
    }
}
