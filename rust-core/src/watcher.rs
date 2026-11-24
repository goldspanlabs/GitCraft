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

pub fn spawn_dirty_watcher(repo: &Path, dirty: Arc<AtomicBool>, stopped: Arc<AtomicBool>) {
    let path = repo.to_owned();
    thread::spawn(move || {
        let dirty_cb = Arc::clone(&dirty);
        let callback = move |result: notify::Result<Event>| {
            if let Ok(event) = result {
                let relevant = event.paths.iter().any(|p| {
                    let s = p.to_string_lossy();
                    !s.contains("/.git/objects/") && !s.contains("/.git/logs/")
                });
                if relevant {
                    dirty_cb.store(true, Ordering::Release);
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
