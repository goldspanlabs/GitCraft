mod common;

use std::{
    fs, thread,
    time::{Duration, Instant},
};

use common::{configure_git_identity, run_git, wait_for_watcher};
use gitcraft_core::RepoSession;

fn becomes_dirty(session: &RepoSession, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if session.take_dirty() {
            return true;
        }
        thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Lets events from the setup arrive and be consumed.
fn settle(session: &RepoSession) {
    while becomes_dirty(session, Duration::from_millis(1500)) {}
}

#[test]
fn only_changes_git_would_report_make_the_checkout_dirty() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    run_git(root, &["init", "-q", "-b", "main"]);
    configure_git_identity(root);
    fs::write(root.join(".gitignore"), "target/\n*.log\n").unwrap();
    fs::write(root.join("kept.log"), "tracked despite the rule\n").unwrap();
    run_git(root, &["add", ".gitignore"]);
    run_git(root, &["add", "-f", "kept.log"]);
    run_git(root, &["commit", "-q", "-m", "base"]);
    fs::create_dir_all(root.join("target/debug")).unwrap();

    let session = RepoSession::new(root.to_string_lossy().into_owned()).unwrap();
    wait_for_watcher(&session);
    settle(&session);

    for i in 0..50 {
        fs::write(root.join(format!("target/debug/out{i}")), "built").unwrap();
    }
    fs::write(root.join("build.log"), "noise").unwrap();
    assert!(
        !becomes_dirty(&session, Duration::from_secs(2)),
        "ignored files don't show in git status"
    );

    fs::write(root.join("kept.log"), "edited\n").unwrap();
    assert!(
        becomes_dirty(&session, Duration::from_secs(4)),
        "a tracked file counts even when it matches an ignore rule"
    );
    settle(&session);

    fs::write(root.join("target/debug/out0"), "rebuilt").unwrap();
    fs::write(root.join("new.txt"), "new\n").unwrap();
    assert!(
        becomes_dirty(&session, Duration::from_secs(4)),
        "an ignored file in the same batch doesn't hide a real change"
    );
}
