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

#[test]
fn linked_worktree_watcher_detects_commits_and_ref_changes() {
    use std::{
        thread,
        time::{Duration, Instant},
    };

    let repo = repo_with_commit();
    let linked_parent = tempfile::tempdir().unwrap();
    let linked = linked_parent.path().join("watched-wt");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-b",
            "feature/watch",
            linked.to_str().unwrap(),
        ],
    );

    let session = RepoSession::open(&linked).unwrap();
    // Let the watcher thread attach and drain any startup events.
    thread::sleep(Duration::from_millis(600));
    let _ = session.take_dirty();
    let _ = session.take_graph_dirty();

    // Creating a commit with `--allow-empty` touches only the linked worktree's gitdir and
    // the shared commondir (refs/heads/feature/watch), not the checkout's working tree.
    run_git(&linked, &["commit", "--allow-empty", "-m", "empty commit"]);

    let deadline = Instant::now() + Duration::from_secs(4);
    let mut graph_dirty = false;
    while Instant::now() < deadline {
        if session.take_graph_dirty() {
            graph_dirty = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    assert!(
        graph_dirty,
        "expected linked-worktree watcher to flag graph_dirty on commit/ref update"
    );
}

#[test]
fn add_worktree_supports_new_branch_existing_branch_and_detached_commit() {
    let repo = repo_with_commit();
    fs::write(repo.path().join("README.md"), "v2\n").unwrap();
    run_git(repo.path(), &["commit", "-am", "second"]);
    let first_oid = run_git(repo.path(), &["rev-parse", "HEAD~1"])
        .trim()
        .to_owned();
    run_git(repo.path(), &["branch", "existing-feature"]);

    let session = RepoSession::open(repo.path()).unwrap();
    let parent = tempfile::tempdir().unwrap();

    // 1. New branch starting from an older commit.
    let new_branch_dir = parent.path().join("new-branch");
    session
        .add_worktree(
            new_branch_dir.to_string_lossy().into_owned(),
            Some("feat/from-first".into()),
            Some(first_oid.clone()),
            false,
        )
        .unwrap();

    // 2. Existing local branch (not checked out anywhere).
    let existing_dir = parent.path().join("existing-branch");
    session
        .add_worktree(
            existing_dir.to_string_lossy().into_owned(),
            None,
            Some("existing-feature".into()),
            false,
        )
        .unwrap();

    // 3. Detached HEAD at a specific commit.
    let detached_dir = parent.path().join("detached");
    session
        .add_worktree(
            detached_dir.to_string_lossy().into_owned(),
            None,
            Some(first_oid.clone()),
            true,
        )
        .unwrap();

    let worktrees = session.list_worktrees().unwrap();
    assert_eq!(worktrees.len(), 4);

    let nb = worktrees
        .iter()
        .find(|w| w.path == canonical(&new_branch_dir))
        .expect("new branch worktree");
    assert_eq!(nb.branch.as_deref(), Some("feat/from-first"));
    assert_eq!(nb.head_oid_hex, first_oid);
    assert!(!nb.is_detached);

    let ex = worktrees
        .iter()
        .find(|w| w.path == canonical(&existing_dir))
        .expect("existing branch worktree");
    assert_eq!(ex.branch.as_deref(), Some("existing-feature"));

    let det = worktrees
        .iter()
        .find(|w| w.path == canonical(&detached_dir))
        .expect("detached worktree");
    assert!(det.is_detached);
    assert_eq!(det.branch, None);
    assert_eq!(det.head_oid_hex, first_oid);
}

#[test]
fn add_worktree_rejects_invalid_arguments_and_checked_out_branch() {
    let repo = repo_with_commit();
    let session = RepoSession::open(repo.path()).unwrap();
    let parent = tempfile::tempdir().unwrap();
    let target = parent.path().join("wt").to_string_lossy().into_owned();

    assert!(session
        .add_worktree("   ".into(), Some("b".into()), None, false)
        .is_err());
    assert!(session
        .add_worktree(target.clone(), Some("b".into()), None, true)
        .is_err());
    assert!(session
        .add_worktree(target.clone(), None, None, false)
        .is_err());
    assert!(session
        .add_worktree(target.clone(), Some("-f".into()), None, false)
        .is_err());
    // `main` is already checked out in the primary worktree.
    assert!(session
        .add_worktree(target, None, Some("main".into()), false)
        .is_err());
    assert_eq!(session.list_worktrees().unwrap().len(), 1);
}

#[test]
fn remove_worktree_deletes_clean_linked_checkout_even_from_its_own_session() {
    let repo = repo_with_commit();
    let parent = tempfile::tempdir().unwrap();
    let linked = parent.path().join("clean-wt");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-b",
            "clean-wt",
            linked.to_str().unwrap(),
        ],
    );
    let linked_path = canonical(&linked);

    // Open the session directly on the linked worktree being removed.
    let linked_session = RepoSession::open(&linked).unwrap();
    linked_session
        .remove_worktree(linked_path.clone(), false)
        .unwrap();

    assert!(!linked.exists(), "worktree folder should be deleted");
    let main_session = RepoSession::open(repo.path()).unwrap();
    let remaining = main_session.list_worktrees().unwrap();
    assert_eq!(remaining.len(), 1);
    assert!(remaining[0].is_main);
    // Branch history is preserved after worktree removal.
    assert!(main_session
        .list_branches()
        .unwrap()
        .iter()
        .any(|b| b.name == "clean-wt"));
}

#[test]
fn remove_worktree_requires_force_for_modified_staged_and_untracked_files() {
    let repo = repo_with_commit();
    let session = RepoSession::open(repo.path()).unwrap();
    let parent = tempfile::tempdir().unwrap();

    for (name, dirty_kind) in [
        ("wt-modified", "modified"),
        ("wt-staged", "staged"),
        ("wt-untracked", "untracked"),
    ] {
        let wt = parent.path().join(name);
        session
            .add_worktree(
                wt.to_string_lossy().into_owned(),
                Some(name.into()),
                None,
                false,
            )
            .unwrap();
        let wt_path = canonical(&wt);

        match dirty_kind {
            "modified" => fs::write(wt.join("README.md"), "dirty\n").unwrap(),
            "staged" => {
                fs::write(wt.join("README.md"), "staged\n").unwrap();
                run_git(&wt, &["add", "README.md"]);
            }
            "untracked" => fs::write(wt.join("scratch.txt"), "untracked\n").unwrap(),
            _ => unreachable!(),
        }

        let err = session
            .remove_worktree(wt_path.clone(), false)
            .expect_err(&format!("safe remove should refuse {dirty_kind} worktree"));
        let msg = err.to_string();
        assert!(
            msg.contains("modified or untracked files") || msg.contains("--force"),
            "unexpected error for {dirty_kind}: {msg}"
        );
        assert!(
            wt.exists(),
            "{dirty_kind} folder should remain on safe failure"
        );

        session.remove_worktree(wt_path, true).unwrap();
        assert!(
            !wt.exists(),
            "forced remove should delete {dirty_kind} folder"
        );
    }

    assert_eq!(session.list_worktrees().unwrap().len(), 1);
}

#[test]
fn remove_worktree_refuses_primary_locked_and_unlisted_paths() {
    let repo = repo_with_commit();
    let session = RepoSession::open(repo.path()).unwrap();
    let parent = tempfile::tempdir().unwrap();
    let locked = parent.path().join("locked-wt");
    session
        .add_worktree(
            locked.to_string_lossy().into_owned(),
            Some("locked-wt".into()),
            None,
            false,
        )
        .unwrap();
    let locked_path = canonical(&locked);
    session.lock_worktree(locked_path.clone(), None).unwrap();

    let elsewhere = tempfile::tempdir().unwrap();

    // Primary checkout cannot be removed, even with force.
    assert!(session
        .remove_worktree(canonical(repo.path()), true)
        .is_err());
    // Unlisted path cannot be removed.
    assert!(session
        .remove_worktree(canonical(elsewhere.path()), true)
        .is_err());
    // Locked worktree cannot be removed until unlocked, even with force.
    assert!(session.remove_worktree(locked_path.clone(), true).is_err());
    assert!(locked.exists());

    session.unlock_worktree(locked_path.clone()).unwrap();
    session.remove_worktree(locked_path, false).unwrap();
    assert!(!locked.exists());
}

#[test]
fn list_worktree_entries_returns_metadata_without_dirty_counts() {
    let repo = repo_with_commit();
    fs::write(repo.path().join("README.md"), "modified\n").unwrap();
    let parent = tempfile::tempdir().unwrap();
    let linked = parent.path().join("dirty-wt");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-b",
            "dirty-wt",
            linked.to_str().unwrap(),
        ],
    );
    fs::write(linked.join("new.txt"), "untracked\n").unwrap();

    let session = RepoSession::open(repo.path()).unwrap();
    let entries = session.list_worktree_entries().unwrap();
    assert_eq!(entries.len(), 2);
    assert!(entries[0].is_main);
    assert_eq!(entries[0].path, canonical(repo.path()));
    assert_eq!(entries[1].path, canonical(&linked));
    assert!(entries.iter().all(|w| w.dirty_count == 0));
}

#[test]
fn commit_graph_includes_detached_sibling_worktree_head() {
    let repo = repo_with_commit();
    let parent = tempfile::tempdir().unwrap();
    let detached = parent.path().join("detached-wt");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "--detach",
            detached.to_str().unwrap(),
            "main",
        ],
    );
    fs::write(detached.join("detached.txt"), "only on detached\n").unwrap();
    run_git(&detached, &["add", "detached.txt"]);
    run_git(&detached, &["commit", "-m", "detached-only commit"]);
    let detached_oid = run_git(&detached, &["rev-parse", "HEAD"]).trim().to_owned();

    // Open on the primary checkout, where no branch or tag points at `detached_oid`.
    let session = RepoSession::open(repo.path()).unwrap();
    let rows = session.get_commit_graph(0, 50, None).unwrap();
    assert!(
        rows.iter().any(|r| r.oid_hex == detached_oid),
        "expected full commit graph to include detached sibling worktree HEAD {detached_oid}"
    );
}

#[test]
fn sibling_worktree_file_edit_flags_worktrees_dirty_without_dirtying_active_status() {
    use std::{
        thread,
        time::{Duration, Instant},
    };

    let repo = repo_with_commit();
    let parent = tempfile::tempdir().unwrap();
    let sibling = parent.path().join("sibling-wt");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-b",
            "sibling",
            sibling.to_str().unwrap(),
        ],
    );

    let session = RepoSession::open(repo.path()).unwrap();
    thread::sleep(Duration::from_millis(600));
    let _ = session.take_dirty();
    let _ = session.take_graph_dirty();
    let _ = session.take_worktrees_dirty();

    fs::write(sibling.join("README.md"), "edited in sibling\n").unwrap();

    let deadline = Instant::now() + Duration::from_secs(4);
    let mut worktrees_dirty = false;
    while Instant::now() < deadline {
        if session.take_worktrees_dirty() {
            worktrees_dirty = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    assert!(
        worktrees_dirty,
        "expected sibling worktree edit to flag worktrees_dirty"
    );
    assert!(
        !session.take_dirty(),
        "sibling worktree edit should not mark active checkout status dirty"
    );
    assert!(
        !session.take_graph_dirty(),
        "sibling worktree edit should not mark graph dirty"
    );
}

#[test]
fn remove_worktree_works_in_bare_backed_repository_from_removed_session() {
    let source = repo_with_commit();
    let parent = tempfile::tempdir().unwrap();
    let bare = parent.path().join("origin.git");
    run_git(
        parent.path(),
        &[
            "clone",
            "--bare",
            source.path().to_str().unwrap(),
            bare.to_str().unwrap(),
        ],
    );
    let wt1 = parent.path().join("wt1");
    let wt2 = parent.path().join("wt2");
    run_git(&bare, &["worktree", "add", wt1.to_str().unwrap(), "main"]);
    run_git(
        &bare,
        &["worktree", "add", "-b", "second", wt2.to_str().unwrap()],
    );
    let wt1_path = canonical(&wt1);
    let wt2_path = canonical(&wt2);

    // Removing the first non-bare worktree from its own session must run from `common_dir`
    // (the bare repo) rather than from `wt1` itself.
    let session = RepoSession::open(&wt1).unwrap();
    session.remove_worktree(wt1_path, false).unwrap();

    assert!(!wt1.exists(), "removed bare-backed worktree should be gone");
    let surviving = RepoSession::open(&wt2).unwrap();
    let remaining = surviving.list_worktree_entries().unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].path, wt2_path);
}

#[test]
fn common_dir_identifies_the_repository_across_checkouts() {
    let repo = repo_with_commit();
    let linked = tempfile::tempdir().unwrap();
    let linked_path = linked.path().join("linked");
    run_git(
        repo.path(),
        &[
            "worktree",
            "add",
            "-b",
            "linked",
            linked_path.to_str().unwrap(),
        ],
    );
    let other = repo_with_commit();

    let primary = RepoSession::new(repo.path().to_str().unwrap().to_string()).unwrap();
    let from_linked = RepoSession::new(linked_path.to_str().unwrap().to_string()).unwrap();
    let unrelated = RepoSession::new(other.path().to_str().unwrap().to_string()).unwrap();

    assert_eq!(primary.common_dir(), from_linked.common_dir());
    assert_eq!(primary.common_dir(), canonical(&repo.path().join(".git")));
    assert_ne!(primary.common_dir(), unrelated.common_dir());
}
