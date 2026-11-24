//! `RepoSession` worktree APIs against real repositories: listing, dirty counts, lock and
//! unlock, pruning missing folders, and rejecting paths git does not list.

use std::{fs, path::Path, process::Command};

use gitcraft_core::RepoSession;

fn run_git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "GitCraft Tester")
        .env("GIT_AUTHOR_EMAIL", "tester@gitcraft.local")
        .env("GIT_COMMITTER_NAME", "GitCraft Tester")
        .env("GIT_COMMITTER_EMAIL", "tester@gitcraft.local")
        .output()
        .expect("failed to invoke git");
    assert!(
        out.status.success(),
        "git {:?} in {} failed:\nstderr: {}",
        args,
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// A repository on `main` with one commit, so linked worktrees can be added.
fn repo_with_commit() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    run_git(dir.path(), &["init", "-b", "main"]);
    run_git(dir.path(), &["config", "user.name", "GitCraft Tester"]);
    run_git(
        dir.path(),
        &["config", "user.email", "tester@gitcraft.local"],
    );
    fs::write(dir.path().join("README.md"), "hello\n").unwrap();
    run_git(dir.path(), &["add", "README.md"]);
    run_git(dir.path(), &["commit", "-m", "initial"]);
    dir
}

fn canonical(path: &Path) -> String {
    fs::canonicalize(path)
        .unwrap()
        .to_string_lossy()
        .into_owned()
}

#[test]
fn lists_main_first_then_linked_worktrees_with_branches() {
    let repo = repo_with_commit();
    let linked_parent = tempfile::tempdir().unwrap();
    let linked = linked_parent.path().join("feature");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-b",
            "feature/x",
            linked.to_str().unwrap(),
        ],
    );

    let session = RepoSession::open(repo.path()).unwrap();
    let worktrees = session.list_worktrees().unwrap();

    assert_eq!(worktrees.len(), 2);
    assert!(worktrees[0].is_main);
    assert_eq!(worktrees[0].branch.as_deref(), Some("main"));
    assert_eq!(worktrees[0].path, canonical(repo.path()));

    assert!(!worktrees[1].is_main);
    assert_eq!(worktrees[1].branch.as_deref(), Some("feature/x"));
    assert_eq!(worktrees[1].path, canonical(&linked));
    assert!(!worktrees[1].is_detached);
    assert!(!worktrees[1].is_locked);
    assert!(!worktrees[1].is_prunable);
}

#[test]
fn detached_worktree_has_no_branch() {
    let repo = repo_with_commit();
    let linked_parent = tempfile::tempdir().unwrap();
    let linked = linked_parent.path().join("detached");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "--detach",
            linked.to_str().unwrap(),
            "main",
        ],
    );

    let session = RepoSession::open(repo.path()).unwrap();
    let detached = session
        .list_worktrees()
        .unwrap()
        .into_iter()
        .find(|w| !w.is_main)
        .unwrap();
    assert!(detached.is_detached);
    assert_eq!(detached.branch, None);
}

#[test]
fn dirty_count_reflects_modified_and_untracked_files() {
    let repo = repo_with_commit();
    let linked_parent = tempfile::tempdir().unwrap();
    let linked = linked_parent.path().join("dirty");
    run_git(
        repo.path(),
        &["worktree", "add", "-b", "dirty", linked.to_str().unwrap()],
    );

    fs::write(linked.join("README.md"), "changed\n").unwrap();
    fs::write(linked.join("new.txt"), "new\n").unwrap();

    let session = RepoSession::open(repo.path()).unwrap();
    let worktree = session
        .list_worktrees()
        .unwrap()
        .into_iter()
        .find(|w| !w.is_main)
        .unwrap();
    assert_eq!(worktree.dirty_count, 2);
    assert_eq!(
        session.list_worktrees().unwrap()[0].dirty_count,
        0,
        "the main checkout is clean"
    );
}

#[test]
fn lock_and_unlock_round_trip_with_reason() {
    let repo = repo_with_commit();
    let linked_parent = tempfile::tempdir().unwrap();
    let linked = linked_parent.path().join("locked");
    run_git(
        repo.path(),
        &["worktree", "add", "-b", "locked", linked.to_str().unwrap()],
    );
    let linked_path = canonical(&linked);

    let session = RepoSession::open(repo.path()).unwrap();
    session
        .lock_worktree(linked_path.clone(), Some("  on usb  ".into()))
        .unwrap();

    let locked = session
        .list_worktrees()
        .unwrap()
        .into_iter()
        .find(|w| w.path == linked_path)
        .unwrap();
    assert!(locked.is_locked);
    assert_eq!(locked.lock_reason.as_deref(), Some("on usb"));

    session.unlock_worktree(linked_path.clone()).unwrap();
    let unlocked = session
        .list_worktrees()
        .unwrap()
        .into_iter()
        .find(|w| w.path == linked_path)
        .unwrap();
    assert!(!unlocked.is_locked);
    assert_eq!(unlocked.lock_reason, None);
}

#[test]
fn lock_without_reason_reports_locked_with_no_reason() {
    let repo = repo_with_commit();
    let linked_parent = tempfile::tempdir().unwrap();
    let linked = linked_parent.path().join("plain-lock");
    run_git(
        repo.path(),
        &["worktree", "add", "-b", "plain", linked.to_str().unwrap()],
    );
    let linked_path = canonical(&linked);

    let session = RepoSession::open(repo.path()).unwrap();
    session.lock_worktree(linked_path.clone(), None).unwrap();

    let worktree = session
        .list_worktrees()
        .unwrap()
        .into_iter()
        .find(|w| w.path == linked_path)
        .unwrap();
    assert!(worktree.is_locked);
    assert_eq!(worktree.lock_reason, None);
}

#[test]
fn rejects_paths_git_does_not_list() {
    let repo = repo_with_commit();
    let session = RepoSession::open(repo.path()).unwrap();
    let elsewhere = tempfile::tempdir().unwrap();

    let lock = session.lock_worktree(canonical(elsewhere.path()), None);
    assert!(lock.is_err());
    let unlock = session.unlock_worktree(canonical(elsewhere.path()));
    assert!(unlock.is_err());
    assert_eq!(session.list_worktrees().unwrap().len(), 1);
}

#[test]
fn prune_forgets_missing_folders_and_keeps_existing_ones() {
    let repo = repo_with_commit();
    let linked_parent = tempfile::tempdir().unwrap();
    let gone = linked_parent.path().join("gone");
    let kept = linked_parent.path().join("kept");
    run_git(
        repo.path(),
        &["worktree", "add", "-b", "gone", gone.to_str().unwrap()],
    );
    run_git(
        repo.path(),
        &["worktree", "add", "-b", "kept", kept.to_str().unwrap()],
    );
    fs::remove_dir_all(&gone).unwrap();

    let session = RepoSession::open(repo.path()).unwrap();
    let before = session.list_worktrees().unwrap();
    assert!(before.iter().any(|w| w.is_prunable));

    session.prune_worktrees().unwrap();

    let after = session.list_worktrees().unwrap();
    assert_eq!(after.len(), 2, "main and kept remain");
    assert!(after.iter().all(|w| !w.is_prunable));
    assert!(after.iter().any(|w| w.branch.as_deref() == Some("kept")));
    assert!(kept.is_dir(), "prune never deletes existing folders");
}
