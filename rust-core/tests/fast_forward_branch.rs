mod common;

use common::{
    commit_file, configure_git_identity, head, init_repo_with_commit, open, run_git, write,
};
use gitcraft_core::GitCraftError;

/// Creates a bare remote + two clones: `local` (checked out on `feature`) and `peer`
/// (used to push new commits to `origin/main`), then fetches in `local` so `main` is
/// behind `origin/main` while `feature` is checked out.
fn setup_behind_branch() -> (
    tempfile::TempDir,
    tempfile::TempDir,
    tempfile::TempDir,
    String,
) {
    let remote = tempfile::tempdir().unwrap();
    run_git(remote.path(), &["init", "--bare", "-b", "main"]);

    let peer = init_repo_with_commit();
    let remote_url = remote.path().to_string_lossy().into_owned();
    run_git(peer.path(), &["remote", "add", "origin", &remote_url]);
    run_git(peer.path(), &["push", "-u", "origin", "main"]);

    let local = tempfile::tempdir().unwrap();
    run_git(local.path(), &["clone", &remote_url, "."]);
    configure_git_identity(local.path());
    run_git(local.path(), &["checkout", "-b", "feature"]);

    // Advance `main` on the remote via `peer`, then fetch into `local`.
    let remote_tip = commit_file(peer.path(), "remote.txt", "from remote\n", "remote commit");
    run_git(peer.path(), &["push", "origin", "main"]);
    run_git(local.path(), &["fetch", "origin"]);

    (remote, peer, local, remote_tip)
}

#[test]
fn fast_forwards_non_checked_out_branch_to_upstream() {
    let (_remote, _peer, local, remote_tip) = setup_behind_branch();
    let feature_head = head(local.path());
    // Leave an uncommitted edit on `feature` to verify the working tree is untouched.
    write(local.path(), "dirty.txt", "wip\n");

    let session = open(local.path());
    let before = session
        .list_branches()
        .unwrap()
        .into_iter()
        .find(|b| !b.is_remote && b.name == "main")
        .unwrap();
    assert_eq!(before.ahead, 0);
    assert_eq!(before.behind, 1);

    session.fast_forward_branch("main".into()).unwrap();

    assert_eq!(
        run_git(local.path(), &["rev-parse", "refs/heads/main"]).trim(),
        remote_tip
    );
    assert_eq!(head(local.path()), feature_head);
    assert_eq!(
        run_git(local.path(), &["symbolic-ref", "--short", "HEAD"]).trim(),
        "feature"
    );
    assert!(local.path().join("dirty.txt").exists());
    assert!(!local.path().join("remote.txt").exists());

    let after = session
        .list_branches()
        .unwrap()
        .into_iter()
        .find(|b| !b.is_remote && b.name == "main")
        .unwrap();
    assert_eq!(after.ahead, 0);
    assert_eq!(after.behind, 0);
}

#[test]
fn fast_forwards_branch_using_origin_fallback_without_explicit_upstream() {
    let (_remote, _peer, local, remote_tip) = setup_behind_branch();
    run_git(local.path(), &["branch", "--unset-upstream", "main"]);

    let session = open(local.path());
    session.fast_forward_branch("main".into()).unwrap();

    assert_eq!(
        run_git(local.path(), &["rev-parse", "refs/heads/main"]).trim(),
        remote_tip
    );
}

#[test]
fn refuses_to_fast_forward_currently_checked_out_branch() {
    let (_remote, _peer, local, _remote_tip) = setup_behind_branch();
    run_git(local.path(), &["checkout", "main"]);
    let before = head(local.path());

    let session = open(local.path());
    let err = session.fast_forward_branch("main".into()).unwrap_err();
    assert!(
        err.to_string().contains("checked out"),
        "unexpected error: {err}"
    );
    assert_eq!(head(local.path()), before);
}

#[test]
fn refuses_to_fast_forward_branch_checked_out_in_other_worktree() {
    let (_remote, _peer, local, _remote_tip) = setup_behind_branch();
    let wt_dir = tempfile::tempdir().unwrap();
    let wt_path = wt_dir.path().join("main-wt");
    run_git(
        local.path(),
        &["worktree", "add", wt_path.to_str().unwrap(), "main"],
    );
    let before = run_git(local.path(), &["rev-parse", "refs/heads/main"])
        .trim()
        .to_owned();

    let session = open(local.path());
    let err = session.fast_forward_branch("main".into()).unwrap_err();
    assert!(
        err.to_string().contains("checked out"),
        "unexpected error: {err}"
    );
    assert_eq!(
        run_git(local.path(), &["rev-parse", "refs/heads/main"]).trim(),
        before
    );
}

#[test]
fn refuses_to_fast_forward_diverged_branch() {
    let (_remote, _peer, local, _remote_tip) = setup_behind_branch();
    // Add a local-only commit to `main`, then switch back to `feature`.
    run_git(local.path(), &["checkout", "main"]);
    let diverged_main = commit_file(local.path(), "local.txt", "local\n", "local commit");
    run_git(local.path(), &["checkout", "feature"]);

    let session = open(local.path());
    let err = session.fast_forward_branch("main".into()).unwrap_err();
    assert!(
        err.to_string().contains("diverged"),
        "unexpected error: {err}"
    );
    assert_eq!(
        run_git(local.path(), &["rev-parse", "refs/heads/main"]).trim(),
        diverged_main
    );
}

#[test]
fn returns_warning_when_branch_is_already_up_to_date() {
    let (_remote, _peer, local, _remote_tip) = setup_behind_branch();
    let session = open(local.path());
    session.fast_forward_branch("main".into()).unwrap();

    let err = session.fast_forward_branch("main".into()).unwrap_err();
    assert!(
        matches!(err, GitCraftError::Warning { .. }),
        "expected Warning, got: {err:?}"
    );
}

#[test]
fn refuses_when_branch_has_no_upstream() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["checkout", "-b", "feature"]);

    let session = open(dir.path());
    let err = session.fast_forward_branch("main".into()).unwrap_err();
    assert!(
        err.to_string().contains("no upstream"),
        "unexpected error: {err}"
    );
}

#[test]
fn refuses_nonexistent_branch() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    let err = session.fast_forward_branch("nope".into()).unwrap_err();
    assert!(
        err.to_string().contains("does not exist"),
        "unexpected error: {err}"
    );
}
