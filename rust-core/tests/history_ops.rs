//! Operations that move or remove history: reset, rebase, conflict prediction, deleting a
//! branch on its remote, and checking out a remote branch that already has a local copy.

mod common;

use std::{fs, path::Path};

use common::{commit_file, head, init_repo_with_commit, open, run_git, write};
use gitcraft_core::ResetMode;

fn rev(dir: &Path, name: &str) -> String {
    run_git(dir, &["rev-parse", name]).trim().to_owned()
}

fn read(dir: &Path, name: &str) -> String {
    fs::read_to_string(dir.join(name)).unwrap()
}

fn current_branch(dir: &Path) -> String {
    run_git(dir, &["branch", "--show-current"])
        .trim()
        .to_owned()
}

/// `git status --porcelain` lines, which tell staged, unstaged and untracked apart.
fn porcelain(dir: &Path) -> Vec<String> {
    run_git(dir, &["status", "--porcelain"])
        .lines()
        .map(str::to_owned)
        .collect()
}

// ------------------------------------------------------------------ reset ---

/// Two commits that each change `a.txt`, then one staged edit, one unstaged edit and one
/// untracked file on top, so every reset mode leaves a different state behind.
fn reset_fixture() -> (tempfile::TempDir, String) {
    let dir = init_repo_with_commit();
    let first = head(dir.path());
    commit_file(dir.path(), "a.txt", "second\n", "second");
    write(dir.path(), "staged.txt", "staged\n");
    run_git(dir.path(), &["add", "staged.txt"]);
    write(dir.path(), "b.txt", "unstaged\n");
    write(dir.path(), "untracked.txt", "untracked\n");
    (dir, first)
}

#[test]
fn soft_reset_moves_the_branch_and_keeps_changes_staged() {
    let (dir, first) = reset_fixture();

    open(dir.path())
        .reset_to(first.clone(), ResetMode::Soft)
        .unwrap();

    assert_eq!(rev(dir.path(), "main"), first);
    assert_eq!(current_branch(dir.path()), "main");
    assert_eq!(
        porcelain(dir.path()),
        ["M  a.txt", " M b.txt", "A  staged.txt", "?? untracked.txt"]
    );
    assert_eq!(read(dir.path(), "a.txt"), "second\n");
    assert_eq!(read(dir.path(), "b.txt"), "unstaged\n");
}

#[test]
fn mixed_reset_unstages_changes_but_keeps_the_files() {
    let (dir, first) = reset_fixture();

    open(dir.path())
        .reset_to(first.clone(), ResetMode::Mixed)
        .unwrap();

    assert_eq!(rev(dir.path(), "main"), first);
    assert_eq!(
        porcelain(dir.path()),
        [" M a.txt", " M b.txt", "?? staged.txt", "?? untracked.txt"]
    );
    assert_eq!(read(dir.path(), "a.txt"), "second\n");
    assert_eq!(read(dir.path(), "b.txt"), "unstaged\n");
    assert_eq!(read(dir.path(), "staged.txt"), "staged\n");
}

#[test]
fn hard_reset_drops_tracked_and_staged_changes_but_keeps_untracked_files() {
    let (dir, first) = reset_fixture();

    open(dir.path())
        .reset_to(first.clone(), ResetMode::Hard)
        .unwrap();

    assert_eq!(rev(dir.path(), "main"), first);
    assert_eq!(porcelain(dir.path()), ["?? untracked.txt"]);
    assert_eq!(read(dir.path(), "a.txt"), "alpha\n");
    assert_eq!(read(dir.path(), "b.txt"), "bravo\n");
    assert!(!dir.path().join("staged.txt").exists());
    assert_eq!(read(dir.path(), "untracked.txt"), "untracked\n");
}

#[test]
fn reset_to_a_bad_target_changes_nothing() {
    let (dir, _first) = reset_fixture();
    let session = open(dir.path());
    let before_head = head(dir.path());
    let before_status = porcelain(dir.path());

    for target in ["no-such-commit", "--hard", "   "] {
        assert!(
            session.reset_to(target.into(), ResetMode::Hard).is_err(),
            "{target:?} must be refused"
        );
    }

    assert_eq!(head(dir.path()), before_head);
    assert_eq!(porcelain(dir.path()), before_status);
    assert_eq!(read(dir.path(), "b.txt"), "unstaged\n");
}

// ----------------------------------------------------------------- rebase ---

/// `main` and `feature` each add a commit after the initial one; HEAD is left on `feature`.
/// With `conflicting`, both commits change `a.txt`.
fn diverged_fixture(conflicting: bool) -> tempfile::TempDir {
    let dir = init_repo_with_commit();
    // Results must not depend on the machine's rebase settings.
    run_git(dir.path(), &["config", "rebase.autoStash", "false"]);
    run_git(dir.path(), &["switch", "-qc", "feature"]);
    let feature_file = if conflicting { "a.txt" } else { "feature.txt" };
    commit_file(dir.path(), feature_file, "feature\n", "feature work");
    run_git(dir.path(), &["switch", "-q", "main"]);
    let main_file = if conflicting { "a.txt" } else { "main.txt" };
    commit_file(dir.path(), main_file, "main\n", "main work");
    run_git(dir.path(), &["switch", "-q", "feature"]);
    dir
}

#[test]
fn rebase_replays_the_current_branch_on_top_of_the_target() {
    let dir = diverged_fixture(false);
    let main_tip = rev(dir.path(), "main");

    open(dir.path()).rebase_onto("main".into()).unwrap();

    assert_eq!(current_branch(dir.path()), "feature");
    assert_eq!(rev(dir.path(), "feature~1"), main_tip);
    assert_eq!(
        rev(dir.path(), "main"),
        main_tip,
        "the target must not move"
    );
    assert_eq!(
        run_git(dir.path(), &["log", "-1", "--format=%s"]).trim(),
        "feature work"
    );
    assert!(dir.path().join("feature.txt").exists());
    assert!(dir.path().join("main.txt").exists());
}

#[test]
fn rebase_with_uncommitted_changes_is_refused_and_keeps_them() {
    let dir = diverged_fixture(false);
    let before = head(dir.path());
    write(dir.path(), "b.txt", "unsaved\n");

    assert!(open(dir.path()).rebase_onto("main".into()).is_err());

    assert_eq!(head(dir.path()), before);
    assert_eq!(read(dir.path(), "b.txt"), "unsaved\n");
}

#[test]
fn conflicting_rebase_reports_its_state_and_can_be_aborted() {
    let dir = diverged_fixture(true);
    let session = open(dir.path());
    let before = head(dir.path());

    assert!(session.rebase_onto("main".into()).is_err());
    let status = session.status().unwrap();
    assert!(status.is_rebasing);
    assert!(status.has_conflicts);

    session.abort_rebase().unwrap();
    assert!(!session.status().unwrap().is_rebasing);
    assert_eq!(head(dir.path()), before);
    assert_eq!(current_branch(dir.path()), "feature");
    assert_eq!(read(dir.path(), "a.txt"), "feature\n");
}

// ---------------------------------------------------- conflict prediction ---

#[test]
fn merge_has_conflicts_is_false_for_a_clean_merge() {
    let dir = diverged_fixture(false);
    let before = head(dir.path());

    assert!(!open(dir.path()).merge_has_conflicts("main".into()).unwrap());

    assert_eq!(head(dir.path()), before);
    assert!(porcelain(dir.path()).is_empty());
    assert!(!dir.path().join("main.txt").exists());
}

#[test]
fn merge_has_conflicts_is_true_for_a_clash_and_touches_nothing() {
    let dir = diverged_fixture(true);
    let session = open(dir.path());
    let before = head(dir.path());
    write(dir.path(), "b.txt", "unsaved\n");

    assert!(session.merge_has_conflicts("main".into()).unwrap());

    assert_eq!(head(dir.path()), before);
    assert_eq!(porcelain(dir.path()), [" M b.txt"]);
    assert_eq!(read(dir.path(), "a.txt"), "feature\n");
    assert!(!session.status().unwrap().is_merging);
}

#[test]
fn merge_has_conflicts_reports_an_error_for_an_unknown_commit() {
    let dir = init_repo_with_commit();

    assert!(open(dir.path())
        .merge_has_conflicts("no-such-branch".into())
        .is_err());
}

// ---------------------------------------------------------- remote branches ---

/// A repo with a bare `origin` holding `main` and `topic/login`, plus the local branches.
fn remote_fixture() -> (tempfile::TempDir, tempfile::TempDir) {
    let dir = init_repo_with_commit();
    let origin = tempfile::tempdir().unwrap();
    run_git(origin.path(), &["init", "--bare", "-b", "main"]);
    run_git(
        dir.path(),
        &["remote", "add", "origin", origin.path().to_str().unwrap()],
    );
    run_git(dir.path(), &["branch", "topic/login"]);
    run_git(dir.path(), &["push", "-q", "origin", "main", "topic/login"]);
    (dir, origin)
}

fn branches(dir: &Path) -> Vec<String> {
    run_git(dir, &["for-each-ref", "--format=%(refname)"])
        .lines()
        .map(str::to_owned)
        .collect()
}

#[test]
fn delete_remote_branch_removes_only_that_branch_on_the_remote() {
    let (dir, origin) = remote_fixture();

    // The branch name has a slash of its own: only the first one separates the remote.
    open(dir.path())
        .delete_remote_branch("origin/topic/login".into())
        .unwrap();

    assert_eq!(branches(origin.path()), ["refs/heads/main"]);
    assert_eq!(
        branches(dir.path()),
        [
            "refs/heads/main",
            "refs/heads/topic/login",
            "refs/remotes/origin/main"
        ],
        "the local branch stays and only its tracking ref is pruned"
    );
}

#[test]
fn delete_remote_branch_refuses_bad_names_and_leaves_the_remote_alone() {
    let (dir, origin) = remote_fixture();
    let session = open(dir.path());
    let before = branches(origin.path());

    for name in ["main", "origin/", "origin/--all", "origin/missing"] {
        assert!(
            session.delete_remote_branch(name.into()).is_err(),
            "{name:?} must be refused"
        );
    }
    // The flag-like branch name is stopped by validation, before git ever sees it.
    let error = session
        .delete_remote_branch("origin/--all".into())
        .unwrap_err();
    assert!(error.to_string().contains("must not start with"));

    assert_eq!(branches(origin.path()), before);
}

#[test]
fn checking_out_a_remote_branch_switches_to_the_existing_local_one_without_moving_it() {
    let (dir, _origin) = remote_fixture();
    // The local `main` gets ahead of `origin/main`, then another branch is checked out.
    let local_tip = commit_file(dir.path(), "local.txt", "local\n", "local only");
    run_git(dir.path(), &["switch", "-qc", "elsewhere"]);

    open(dir.path())
        .checkout_branch("origin/main".into())
        .unwrap();

    assert_eq!(current_branch(dir.path()), "main");
    assert_eq!(head(dir.path()), local_tip);
}
