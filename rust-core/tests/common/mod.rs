#![allow(dead_code)]

use std::{
    fs,
    path::Path,
    process::Command,
    thread,
    time::{Duration, Instant},
};

use gitcraft_core::RepoSession;

pub fn run_git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "GitCraft Tester")
        .env("GIT_AUTHOR_EMAIL", "tester@gitcraft.local")
        .env("GIT_COMMITTER_NAME", "GitCraft Tester")
        .env("GIT_COMMITTER_EMAIL", "tester@gitcraft.local")
        // Fixed dates make commit hashes identical on every run, so hash-matching
        // searches and sort ties behave the same each time.
        .env("GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z")
        .env("GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z")
        .output()
        .expect("failed to invoke git");
    assert!(
        out.status.success(),
        "git {:?} in {} failed:\nstdout: {}\nstderr: {}",
        args,
        dir.display(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

pub fn configure_git_identity(dir: &Path) {
    run_git(dir, &["config", "user.name", "GitCraft Tester"]);
    run_git(dir, &["config", "user.email", "tester@gitcraft.local"]);
}

/// Creates a repo on `main` with a local identity configured, and no commits.
pub fn init_repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    run_git(dir.path(), &["init", "-b", "main"]);
    configure_git_identity(dir.path());
    dir
}

pub fn write(dir: &Path, name: &str, contents: &str) {
    fs::write(dir.join(name), contents).unwrap();
}

/// Creates a repo with one commit containing `a.txt` and `b.txt`.
pub fn init_repo_with_commit() -> tempfile::TempDir {
    let dir = init_repo();
    write(dir.path(), "a.txt", "alpha\n");
    write(dir.path(), "b.txt", "bravo\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "initial"]);
    dir
}

pub fn open(dir: &Path) -> RepoSession {
    RepoSession::new(dir.to_string_lossy().into_owned()).unwrap()
}

pub fn head(dir: &Path) -> String {
    run_git(dir, &["rev-parse", "HEAD"]).trim().to_owned()
}

pub fn commit_file(dir: &Path, name: &str, contents: &str, msg: &str) -> String {
    write(dir, name, contents);
    run_git(dir, &["add", "-A"]);
    run_git(dir, &["commit", "-m", msg]);
    head(dir)
}

/// Waits until the session's file watcher is listening, then lets startup events arrive and
/// discards them, so flags raised afterwards come from changes the test makes.
///
/// A fixed sleep is not enough: registering watches can take over a second, for example when
/// the test binary sits in a folder holding tens of thousands of build artifacts.
pub fn wait_for_watcher(session: &RepoSession) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !session.is_watcher_ready() {
        assert!(
            Instant::now() < deadline,
            "the file watcher never became ready"
        );
        thread::sleep(Duration::from_millis(10));
    }
    thread::sleep(Duration::from_millis(600));
    let _ = session.take_dirty();
    let _ = session.take_graph_dirty();
    let _ = session.take_worktrees_dirty();
}
