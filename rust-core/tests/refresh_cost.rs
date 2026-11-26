mod common;

use std::{
    fs, thread,
    time::{Duration, Instant},
};

use common::{configure_git_identity, init_repo_with_commit, run_git, wait_for_watcher};
use gitcraft_core::RepoSession;

fn within(timeout: Duration, mut flag: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if flag() {
            return true;
        }
        thread::sleep(Duration::from_millis(50));
    }
    false
}

#[test]
fn sibling_worktree_listing_leaves_this_checkouts_count_to_its_status() {
    let repo = init_repo_with_commit();
    let parent = tempfile::tempdir().unwrap();
    let linked = parent.path().join("linked");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "linked",
            linked.to_str().unwrap(),
        ],
    );
    fs::write(repo.path().join("here.txt"), "x").unwrap();
    fs::write(linked.join("there.txt"), "x").unwrap();
    let path = fs::canonicalize(repo.path()).unwrap();

    let session = RepoSession::open(&path).unwrap();
    let counts: Vec<u32> = session
        .list_worktrees_with_sibling_counts()
        .unwrap()
        .iter()
        .map(|w| w.dirty_count)
        .collect();

    assert_eq!(counts, [0, 1]);
}

#[test]
fn linked_checkout_session_notices_edits_in_the_primary_checkout() {
    let repo = init_repo_with_commit();
    let parent = tempfile::tempdir().unwrap();
    let linked = parent.path().join("linked");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "linked",
            linked.to_str().unwrap(),
        ],
    );
    let session = RepoSession::open(&linked).unwrap();
    wait_for_watcher(&session);

    fs::write(
        repo.path().join("a.txt"),
        "edited in the primary checkout\n",
    )
    .unwrap();

    assert!(within(Duration::from_secs(4), || session.take_worktrees_dirty()));
}

/// The app leaves reloading after a background fetch to the watcher.
#[test]
fn a_fetch_is_noticed_only_when_it_brings_something() {
    let source = init_repo_with_commit();
    let parent = tempfile::tempdir().unwrap();
    let clone = parent.path().join("clone");
    run_git(
        parent.path(),
        &[
            "clone",
            "-q",
            source.path().to_str().unwrap(),
            clone.to_str().unwrap(),
        ],
    );
    configure_git_identity(&clone);
    let session = RepoSession::open(&clone).unwrap();
    // The first fetch may record the remote's default branch.
    session.fetch(true).unwrap();
    wait_for_watcher(&session);
    while within(Duration::from_millis(1500), || session.take_graph_dirty()) {}

    session.fetch(true).unwrap();
    assert!(!within(Duration::from_secs(2), || session.take_graph_dirty()));

    run_git(
        source.path(),
        &["commit", "-q", "--allow-empty", "-m", "more"],
    );
    session.fetch(true).unwrap();
    assert!(within(Duration::from_secs(4), || session.take_graph_dirty()));
}
