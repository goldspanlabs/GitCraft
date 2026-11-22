use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::{io, path::Path, sync::mpsc::Sender, thread, time::Duration};

pub fn watch(repo: &Path, events: Sender<()>) -> io::Result<()> {
    let path = repo.to_owned();
    thread::spawn(move || {
        let callback = move |result: notify::Result<Event>| {
            if result.is_ok() {
                let _ = events.send(());
            }
        };
        let mut watcher = match RecommendedWatcher::new(
            callback,
            Config::default().with_poll_interval(Duration::from_millis(150)),
        ) {
            Ok(watcher) => watcher,
            Err(_) => return,
        };
        let _ = watcher.watch(&path, RecursiveMode::Recursive);
        loop {
            thread::sleep(Duration::from_secs(3600));
        }
    });
    Ok(())
}
