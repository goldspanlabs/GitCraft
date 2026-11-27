//! Operations that move or remove history: reset, rebase, conflict prediction, deleting a
//! branch on its remote, and checking out a remote branch that already has a local copy.

mod common;

use std::{fs, path::Path};

use common::{commit_file, head, init_repo_with_commit, open, rev, run_git, write};
use gitcraft_core::ResetMode;

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

// ------------------------------------------------------------------- undo ---

#[test]
fn head_position_names_the_commit_and_branch() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    let position = session.head_position().unwrap();
    assert_eq!(position.oid, head(dir.path()));
    assert_eq!(position.branch.as_deref(), Some("refs/heads/main"));

    run_git(dir.path(), &["checkout", "--detach", "-q"]);
    assert_eq!(session.head_position().unwrap().branch, None);
}

#[test]
fn head_position_is_none_before_the_first_commit() {
    let dir = common::init_repo();
    assert!(open(dir.path()).head_position().is_none());
}

#[test]
fn undoing_a_soft_reset_restores_the_branch_and_the_staged_changes() {
    let (dir, first) = reset_fixture();
    let session = open(dir.path());
    let status_before = porcelain(dir.path());

    let moved = session.reset_to(first, ResetMode::Soft).unwrap().unwrap();
    session
        .undo_head_move(moved.after, moved.before.oid.clone(), ResetMode::Soft)
        .unwrap();

    assert_eq!(head(dir.path()), moved.before.oid);
    assert_eq!(porcelain(dir.path()), status_before);
}

#[test]
fn undoing_a_mixed_reset_restores_the_branch_and_keeps_the_files() {
    let (dir, first) = reset_fixture();
    let session = open(dir.path());

    let moved = session.reset_to(first, ResetMode::Mixed).unwrap().unwrap();
    session
        .undo_head_move(moved.after, moved.before.oid.clone(), ResetMode::Mixed)
        .unwrap();

    assert_eq!(head(dir.path()), moved.before.oid);
    // Back on the second commit, so only the edits made on top of it are left (unstaged).
    assert_eq!(
        porcelain(dir.path()),
        [" M b.txt", "?? staged.txt", "?? untracked.txt"]
    );
    assert_eq!(read(dir.path(), "a.txt"), "second\n");
}

#[test]
fn undoing_a_cherry_pick_keeps_unrelated_local_changes() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["checkout", "-q", "-b", "other"]);
    let picked = commit_file(dir.path(), "c.txt", "charlie\n", "add c");
    run_git(dir.path(), &["checkout", "-q", "main"]);
    write(dir.path(), "b.txt", "local edit\n");

    let session = open(dir.path());
    let before = session.head_position().unwrap();
    let moved = session.cherry_pick(picked).unwrap().unwrap();
    assert_eq!(moved.before, before);
    assert_eq!(moved.after, session.head_position().unwrap());

    session
        .undo_head_move(moved.after, before.oid.clone(), ResetMode::Keep)
        .unwrap();

    assert_eq!(head(dir.path()), before.oid);
    assert!(
        !dir.path().join("c.txt").exists(),
        "the picked file is gone again"
    );
    assert_eq!(read(dir.path(), "b.txt"), "local edit\n");
    assert_eq!(porcelain(dir.path()), [" M b.txt"]);
}

#[test]
fn undoing_a_revert_brings_the_change_back() {
    let dir = init_repo_with_commit();
    let change = commit_file(dir.path(), "a.txt", "changed\n", "change a");
    let session = open(dir.path());

    let moved = session.revert_commit(change.clone()).unwrap().unwrap();
    assert_eq!(read(dir.path(), "a.txt"), "alpha\n");
    session
        .undo_head_move(moved.after, moved.before.oid, ResetMode::Keep)
        .unwrap();

    assert_eq!(head(dir.path()), change);
    assert_eq!(read(dir.path(), "a.txt"), "changed\n");
}

#[test]
fn a_reset_that_goes_nowhere_reports_no_move() {
    let dir = init_repo_with_commit();
    let here = head(dir.path());
    assert!(open(dir.path())
        .reset_to(here, ResetMode::Soft)
        .unwrap()
        .is_none());
}

#[test]
fn a_failed_cherry_pick_reports_an_error_not_a_move() {
    let dir = init_repo_with_commit();
    assert!(open(dir.path())
        .cherry_pick("no-such-commit".into())
        .is_err());
}

#[test]
fn undoing_a_cherry_pick_refuses_when_a_local_edit_touches_the_picked_file() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["checkout", "-q", "-b", "other"]);
    let picked = commit_file(dir.path(), "a.txt", "picked\n", "change a");
    run_git(dir.path(), &["checkout", "-q", "main"]);
    let session = open(dir.path());

    let moved = session.cherry_pick(picked).unwrap().unwrap();
    // An edit on top of the picked change: undoing would have to overwrite it.
    write(dir.path(), "a.txt", "edited after the pick\n");

    assert!(session
        .undo_head_move(moved.after.clone(), moved.before.oid, ResetMode::Keep)
        .is_err());
    assert_eq!(head(dir.path()), moved.after.oid, "the branch stays put");
    assert_eq!(read(dir.path(), "a.txt"), "edited after the pick\n");
}

#[test]
fn undoing_a_cherry_pick_refuses_while_other_changes_are_staged() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["checkout", "-q", "-b", "other"]);
    let picked = commit_file(dir.path(), "c.txt", "charlie\n", "add c");
    run_git(dir.path(), &["checkout", "-q", "main"]);
    let session = open(dir.path());
    let moved = session.cherry_pick(picked).unwrap().unwrap();

    // Staged, and unrelated to the pick: `reset --keep` would unstage it.
    write(dir.path(), "b.txt", "staged edit\n");
    run_git(dir.path(), &["add", "b.txt"]);

    let error = session
        .undo_head_move(
            moved.after.clone(),
            moved.before.oid.clone(),
            ResetMode::Keep,
        )
        .unwrap_err();
    assert!(error.to_string().contains("staged"), "{error}");
    assert_eq!(head(dir.path()), moved.after.oid);
    assert_eq!(
        porcelain(dir.path()),
        ["M  b.txt"],
        "the staging is untouched"
    );

    // Once it's unstaged, the undo works.
    run_git(dir.path(), &["reset", "-q", "b.txt"]);
    session
        .undo_head_move(moved.after, moved.before.oid.clone(), ResetMode::Keep)
        .unwrap();
    assert_eq!(head(dir.path()), moved.before.oid);
}

#[test]
fn undo_head_move_rejects_a_bad_target() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    let here = session.head_position().unwrap();

    for target in ["--hard", "   ", "no-such-commit"] {
        assert!(
            session
                .undo_head_move(here.clone(), target.into(), ResetMode::Keep)
                .is_err(),
            "{target:?} must be refused"
        );
    }
    assert_eq!(session.head_position().unwrap(), here);
}

#[test]
fn undo_refuses_once_the_branch_has_moved_on() {
    let dir = init_repo_with_commit();
    let first = head(dir.path());
    let session = open(dir.path());
    commit_file(dir.path(), "a.txt", "second\n", "second");
    let after = session.head_position().unwrap();

    // A commit made after the action.
    let later = commit_file(dir.path(), "a.txt", "third\n", "third");
    assert!(session
        .undo_head_move(after.clone(), first.clone(), ResetMode::Keep)
        .is_err());
    assert_eq!(head(dir.path()), later);

    // The same commit, but checked out on another branch.
    run_git(dir.path(), &["reset", "-q", "--hard", &after.oid]);
    run_git(dir.path(), &["checkout", "-q", "-b", "elsewhere"]);
    assert!(session
        .undo_head_move(after.clone(), first, ResetMode::Keep)
        .is_err());
    assert_eq!(rev(dir.path(), "elsewhere"), after.oid);
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

#[test]
fn merge_has_conflicts_keeps_gits_explanation_when_a_commit_cannot_be_resolved() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    fs::remove_dir_all(dir.path().join(".git")).unwrap();

    let error = session.merge_has_conflicts("main".into()).unwrap_err();

    assert!(
        error.to_string().contains("not a git repository"),
        "{error}"
    );
}

#[test]
fn merge_has_conflicts_passes_on_a_failure_to_start_git() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    // With the folder gone, git cannot be started in it at all.
    fs::remove_dir_all(dir.path()).unwrap();

    let error = session.merge_has_conflicts("main".into()).unwrap_err();

    assert!(
        error.to_string().contains("No such file or directory"),
        "{error}"
    );
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

#[test]
fn undo_checkout_switches_back_and_refuses_when_head_moved() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    run_git(dir.path(), &["branch", "feature"]);

    let moved = session.checkout_branch("feature".into()).unwrap().unwrap();
    assert_eq!(current_branch(dir.path()), "feature");

    session
        .undo_checkout(moved.after.clone(), moved.before.clone())
        .unwrap();
    assert_eq!(current_branch(dir.path()), "main");

    // Once HEAD moved again, the stale undo must refuse.
    assert!(session.undo_checkout(moved.after, moved.before).is_err());
}

#[test]
fn undo_checkout_refuses_when_target_branch_moved() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    run_git(dir.path(), &["branch", "feature"]);

    let moved = session.checkout_branch("feature".into()).unwrap().unwrap();
    // Advance `main` externally while on `feature`.
    let new_commit = commit_file(dir.path(), "other.txt", "new\n", "advance");
    run_git(dir.path(), &["branch", "-f", "main", &new_commit]);

    assert!(session.undo_checkout(moved.after, moved.before).is_err());
    assert_eq!(current_branch(dir.path()), "feature");
}

#[test]
fn undo_ref_move_restores_deleted_branch_config_and_annotated_tag() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    let tip = head(dir.path());
    run_git(dir.path(), &["branch", "feature"]);
    run_git(dir.path(), &["config", "branch.feature.remote", "origin"]);
    run_git(
        dir.path(),
        &["config", "branch.feature.merge", "refs/heads/feature"],
    );

    let deleted_branch = session
        .delete_branch("feature".into(), false)
        .unwrap()
        .unwrap();
    assert!(session.ref_oid("refs/heads/feature".into()).is_none());
    session
        .undo_ref_move(
            deleted_branch.after_oid,
            deleted_branch.full_ref.clone(),
            deleted_branch.before_oid.clone(),
            deleted_branch.branch_config.clone(),
        )
        .unwrap();
    assert_eq!(
        session.ref_oid("refs/heads/feature".into()).as_deref(),
        Some(tip.as_str())
    );
    assert_eq!(
        run_git(dir.path(), &["config", "--get", "branch.feature.remote"]).trim(),
        "origin"
    );
    assert_eq!(
        run_git(dir.path(), &["config", "--get", "branch.feature.merge"]).trim(),
        "refs/heads/feature"
    );

    let created_tag = session
        .create_tag("v1.0".into(), None, Some("Release 1.0".into()), false)
        .unwrap()
        .unwrap();
    let tag_oid = created_tag.after_oid.clone().unwrap();
    let deleted_tag = session.delete_tag("v1.0".into(), false).unwrap().unwrap();
    assert_eq!(deleted_tag.before_oid.as_deref(), Some(tag_oid.as_str()));
    assert!(session.ref_oid("refs/tags/v1.0".into()).is_none());

    session
        .undo_ref_move(
            deleted_tag.after_oid,
            deleted_tag.full_ref,
            deleted_tag.before_oid,
            deleted_tag.branch_config,
        )
        .unwrap();
    assert_eq!(
        session.ref_oid("refs/tags/v1.0".into()).as_deref(),
        Some(tag_oid.as_str())
    );
    let tag_msg = run_git(dir.path(), &["tag", "-l", "-n1", "v1.0"]);
    assert!(tag_msg.contains("Release 1.0"));
}

#[test]
fn undo_ref_move_refuses_when_branch_checked_out_in_sibling_worktree() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    let created = session
        .create_branch("wt-branch".into(), None, false)
        .unwrap()
        .unwrap();

    let wt_dir = tempfile::tempdir().unwrap();
    let wt_path = wt_dir.path().join("sibling");
    run_git(
        dir.path(),
        &["worktree", "add", wt_path.to_str().unwrap(), "wt-branch"],
    );

    assert!(session
        .undo_ref_move(
            created.after_oid,
            created.full_ref,
            created.before_oid,
            created.branch_config,
        )
        .is_err());
    assert!(session.ref_oid("refs/heads/wt-branch".into()).is_some());
}

#[test]
fn delete_branch_undo_does_not_duplicate_dotted_sibling_branch_config() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    run_git(dir.path(), &["branch", "release"]);
    run_git(dir.path(), &["branch", "release.next"]);
    run_git(
        dir.path(),
        &["config", "branch.release.next.remote", "origin"],
    );

    let deleted = session
        .delete_branch("release".into(), false)
        .unwrap()
        .unwrap();
    assert!(deleted.branch_config.is_empty());

    session
        .undo_ref_move(
            deleted.after_oid,
            deleted.full_ref,
            deleted.before_oid,
            deleted.branch_config,
        )
        .unwrap();
    let values = run_git(
        dir.path(),
        &["config", "--get-all", "branch.release.next.remote"],
    );
    assert_eq!(values.lines().collect::<Vec<_>>(), ["origin"]);
}

#[test]
fn undo_ref_move_rolls_back_ref_when_config_is_locked() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    let tip = head(dir.path());
    run_git(dir.path(), &["branch", "feature"]);
    run_git(dir.path(), &["config", "branch.feature.remote", "origin"]);

    let deleted = session
        .delete_branch("feature".into(), false)
        .unwrap()
        .unwrap();

    let config_lock = dir.path().join(".git/config.lock");
    fs::write(&config_lock, "").unwrap();
    assert!(session
        .undo_ref_move(
            deleted.after_oid.clone(),
            deleted.full_ref.clone(),
            deleted.before_oid.clone(),
            deleted.branch_config.clone(),
        )
        .is_err());
    assert!(session.ref_oid("refs/heads/feature".into()).is_none());

    fs::remove_file(&config_lock).unwrap();
    session
        .undo_ref_move(
            deleted.after_oid,
            deleted.full_ref.clone(),
            deleted.before_oid,
            deleted.branch_config,
        )
        .unwrap();
    assert_eq!(
        session.ref_oid("refs/heads/feature".into()).as_deref(),
        Some(tip.as_str())
    );

    fs::write(&config_lock, "").unwrap();
    assert!(session
        .undo_ref_move(Some(tip.clone()), deleted.full_ref, None, Vec::new())
        .is_err());
    assert_eq!(
        session.ref_oid("refs/heads/feature".into()).as_deref(),
        Some(tip.as_str())
    );
}
