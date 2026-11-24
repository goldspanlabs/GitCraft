use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    path::Path,
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

fn classify(path: &str) -> Change {
    if path.ends_with(".lock") {
        return Change::Irrelevant;
    }
    let Some((_, inside)) = path.split_once("/.git/") else {
        return Change::Status;
    };
    if inside.starts_with("objects/") || inside.starts_with("logs/") {
        return Change::Irrelevant;
    }
    if inside == "index" || inside == "MERGE_HEAD" || inside == "MERGE_MSG" {
        return Change::Status;
    }
    Change::Graph
}

/// Watches the repository and raises `status_dirty` for any relevant change, plus
/// `graph_dirty` when refs/HEAD/config changed.
pub fn spawn_dirty_watcher(
    repo: &Path,
    status_dirty: Arc<AtomicBool>,
    graph_dirty: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
) {
    let path = repo.to_owned();
    thread::spawn(move || {
        let callback = move |result: notify::Result<Event>| {
            let Ok(event) = result else { return };
            for p in &event.paths {
                match classify(&p.to_string_lossy()) {
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
        let _ = watcher.watch(&path, RecursiveMode::Recursive);
        while !stopped.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(500));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_events() {
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
}
