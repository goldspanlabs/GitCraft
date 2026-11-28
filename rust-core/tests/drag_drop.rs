mod common;

use common::{commit_file, head, init_repo_with_commit, open, rev, run_git, write};
use gitcraft_core::{DropIntegration, ResetMode};

fn fixture() -> (tempfile::TempDir, String) {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["checkout", "-b", "feature"]);
    commit_file(dir.path(), "feature.txt", "feature\n", "feature change");
    let source = head(dir.path());
    run_git(dir.path(), &["checkout", "main"]);
    (dir, source)
}

#[test]
fn merge_and_cherry_pick_have_undoable_head_moves() {
    for action in [DropIntegration::Merge, DropIntegration::CherryPick] {
        let (dir, source) = fixture();
        let session = open(dir.path());
        let expected = session.head_position().unwrap();
        let movement = session
            .integrate_drop(
                source.clone(),
                Some("refs/heads/feature".into()),
                action,
                expected.clone(),
            )
            .unwrap()
            .unwrap();
        assert_eq!(movement.before, expected);
        assert!(dir.path().join("feature.txt").exists());
        assert_eq!(rev(dir.path(), "feature"), source);
        assert_eq!(
            run_git(dir.path(), &["branch", "--show-current"]).trim(),
            "main"
        );
        session
            .undo_head_move(movement.after, movement.before.oid.clone(), ResetMode::Keep)
            .unwrap();
        assert_eq!(head(dir.path()), movement.before.oid);
        assert!(!dir.path().join("feature.txt").exists());
    }
}

#[test]
fn rebase_replays_destination_onto_dragged_source() {
    let (dir, source) = fixture();
    commit_file(dir.path(), "main.txt", "main\n", "main change");
    let session = open(dir.path());
    let expected = session.head_position().unwrap();
    let movement = session
        .integrate_drop(
            source.clone(),
            Some("refs/heads/feature".into()),
            DropIntegration::Rebase,
            expected.clone(),
        )
        .unwrap()
        .unwrap();
    assert_eq!(rev(dir.path(), "HEAD^"), source);
    assert_eq!(rev(dir.path(), "feature"), source);
    assert_eq!(
        run_git(dir.path(), &["log", "-1", "--format=%s"]).trim(),
        "main change"
    );
    session
        .undo_head_move(movement.after, expected.oid.clone(), ResetMode::Keep)
        .unwrap();
    assert_eq!(head(dir.path()), expected.oid);
}

#[test]
fn stale_head_and_changed_branch_identity_refuse_without_mutating() {
    for action in [
        DropIntegration::Merge,
        DropIntegration::Rebase,
        DropIntegration::CherryPick,
    ] {
        let (dir, source) = fixture();
        let session = open(dir.path());
        let expected = session.head_position().unwrap();
        // Same OID, different branch: checking only the hash would apply to the wrong branch.
        run_git(dir.path(), &["checkout", "-b", "other"]);
        assert!(session
            .integrate_drop(source.clone(), None, action, expected.clone())
            .unwrap_err()
            .to_string()
            .contains("branch changed"));
        assert_eq!(head(dir.path()), expected.oid);
        run_git(dir.path(), &["checkout", "main"]);
        commit_file(dir.path(), "new.txt", "new\n", "new commit");
        let before = head(dir.path());
        assert!(session
            .integrate_drop(source.clone(), None, action, expected)
            .is_err());
        assert_eq!(head(dir.path()), before);
        assert!(!dir.path().join("feature.txt").exists());
    }
}

#[test]
fn changed_or_deleted_source_branch_refuses_without_mutating() {
    for deleted in [false, true] {
        let (dir, source) = fixture();
        let session = open(dir.path());
        let expected = session.head_position().unwrap();
        if deleted {
            run_git(dir.path(), &["branch", "-D", "feature"]);
        } else {
            run_git(dir.path(), &["branch", "-f", "feature", "main"]);
        }
        assert!(session
            .integrate_drop(
                source,
                Some("refs/heads/feature".into()),
                DropIntegration::Merge,
                expected.clone()
            )
            .unwrap_err()
            .to_string()
            .contains("source branch changed"));
        assert_eq!(head(dir.path()), expected.oid);
    }
}

#[test]
fn dirty_state_is_preserved_and_never_automatically_stashed() {
    for action in [
        DropIntegration::Merge,
        DropIntegration::Rebase,
        DropIntegration::CherryPick,
    ] {
        let (dir, source) = fixture();
        let session = open(dir.path());
        let expected = session.head_position().unwrap();
        write(dir.path(), "staged.txt", "staged\n");
        run_git(dir.path(), &["add", "staged.txt"]);
        write(dir.path(), "staged.txt", "unstaged\n");
        write(dir.path(), "untracked.txt", "untracked\n");
        let before = run_git(dir.path(), &["status", "--porcelain"]);
        assert!(session
            .integrate_drop(source, None, action, expected.clone())
            .unwrap_err()
            .to_string()
            .contains("stash"));
        assert_eq!(head(dir.path()), expected.oid);
        assert_eq!(run_git(dir.path(), &["status", "--porcelain"]), before);
        assert_eq!(
            std::fs::read_to_string(dir.path().join("staged.txt")).unwrap(),
            "unstaged\n"
        );
        assert!(run_git(dir.path(), &["stash", "list"]).is_empty());
    }
}

#[test]
fn invalid_object_and_merge_commit_cherry_pick_do_not_change_head() {
    let (dir, source) = fixture();
    let session = open(dir.path());
    let expected = session.head_position().unwrap();
    for invalid in [
        "--help".to_owned(),
        "0".repeat(40),
        run_git(dir.path(), &["rev-parse", "HEAD^{tree}"])
            .trim()
            .to_owned(),
    ] {
        assert!(session
            .integrate_drop(invalid, None, DropIntegration::CherryPick, expected.clone())
            .is_err());
        assert_eq!(head(dir.path()), expected.oid);
    }
    commit_file(dir.path(), "main.txt", "main\n", "main change");
    run_git(dir.path(), &["merge", "--no-edit", &source]);
    let merge = head(dir.path());
    run_git(dir.path(), &["reset", "--hard", &expected.oid]);
    assert!(session
        .integrate_drop(merge, None, DropIntegration::CherryPick, expected.clone())
        .is_err());
    assert_eq!(head(dir.path()), expected.oid);
}

#[test]
fn conflicts_enter_standard_recovery_and_abort_preserves_original_head() {
    for action in [
        DropIntegration::Merge,
        DropIntegration::Rebase,
        DropIntegration::CherryPick,
    ] {
        let dir = init_repo_with_commit();
        run_git(dir.path(), &["checkout", "-b", "feature"]);
        commit_file(dir.path(), "a.txt", "feature conflict\n", "feature change");
        let source = head(dir.path());
        run_git(dir.path(), &["checkout", "main"]);
        commit_file(dir.path(), "a.txt", "main conflict\n", "main change");
        let session = open(dir.path());
        let expected = session.head_position().unwrap();
        assert!(session
            .integrate_drop(source.clone(), None, action, expected.clone())
            .is_err());
        let status = session.status().unwrap();
        assert!(status.has_conflicts);
        assert!(session
            .integrate_drop(source, None, action, session.head_position().unwrap())
            .is_err());
        match action {
            DropIntegration::Merge => session.abort_merge().unwrap(),
            DropIntegration::Rebase => session.abort_rebase().unwrap(),
            DropIntegration::CherryPick => session.abort_cherry_pick().unwrap(),
        }
        assert_eq!(head(dir.path()), expected.oid);
        assert!(session.status().unwrap().is_clean);
    }
}

#[test]
fn already_merged_ancestor_is_a_warning_not_a_successful_noop() {
    let dir = init_repo_with_commit();
    let ancestor = head(dir.path());
    run_git(dir.path(), &["branch", "feature"]);
    commit_file(dir.path(), "later.txt", "later\n", "later");
    let session = open(dir.path());
    let before = session.head_position().unwrap();
    let refs = run_git(dir.path(), &["show-ref"]);
    let error = session
        .integrate_drop(
            ancestor,
            Some("refs/heads/feature".into()),
            DropIntegration::Merge,
            before.clone(),
        )
        .unwrap_err();
    assert!(error.to_string().contains("nothing to merge"));
    assert_eq!(session.head_position().unwrap(), before);
    assert_eq!(run_git(dir.path(), &["show-ref"]), refs);
    assert!(session.status().unwrap().is_clean);
}

#[test]
fn rebase_with_update_refs_enabled_leaves_other_branches_unchanged_through_undo() {
    let (dir, source) = fixture();
    commit_file(dir.path(), "first.txt", "first\n", "first local");
    let first = head(dir.path());
    run_git(dir.path(), &["branch", "midpoint"]);
    commit_file(dir.path(), "second.txt", "second\n", "second local");
    run_git(dir.path(), &["branch", "at-tip"]);
    run_git(dir.path(), &["config", "rebase.updateRefs", "true"]);
    let session = open(dir.path());
    let before = session.head_position().unwrap();
    let movement = session
        .integrate_drop(
            source.clone(),
            Some("refs/heads/feature".into()),
            DropIntegration::Rebase,
            before.clone(),
        )
        .unwrap()
        .unwrap();
    assert_eq!(rev(dir.path(), "HEAD~2"), source);
    assert_eq!(rev(dir.path(), "midpoint"), first);
    assert_eq!(rev(dir.path(), "at-tip"), before.oid);
    session
        .undo_head_move(movement.after, before.oid.clone(), ResetMode::Keep)
        .unwrap();
    assert_eq!(session.head_position().unwrap(), before);
    assert_eq!(rev(dir.path(), "midpoint"), first);
    assert_eq!(rev(dir.path(), "at-tip"), before.oid);
    assert_eq!(
        run_git(dir.path(), &["config", "rebase.updateRefs"]).trim(),
        "true"
    );
}

#[test]
fn merge_drop_overrides_squash_and_no_commit_configuration_and_remains_undoable() {
    for options in ["--squash", "--no-commit", "--squash --no-commit"] {
        let (dir, source) = fixture();
        commit_file(dir.path(), "main.txt", "main\n", "main local change");
        run_git(dir.path(), &["config", "branch.main.mergeOptions", options]);
        let session = open(dir.path());
        let before = session.head_position().unwrap();
        let movement = session
            .integrate_drop(
                source.clone(),
                Some("refs/heads/feature".into()),
                DropIntegration::Merge,
                before.clone(),
            )
            .unwrap()
            .expect("a completed, undoable merge");
        assert_eq!(rev(dir.path(), "HEAD^1"), before.oid);
        assert_eq!(rev(dir.path(), "HEAD^2"), source);
        let status = session.status().unwrap();
        assert!(status.is_clean);
        assert!(!status.is_merging);
        session
            .undo_head_move(movement.after, before.oid.clone(), ResetMode::Keep)
            .unwrap();
        assert_eq!(session.head_position().unwrap(), before);
        assert_eq!(rev(dir.path(), "feature"), source);
        assert!(!dir.path().join("feature.txt").exists());
        assert_eq!(
            run_git(dir.path(), &["config", "branch.main.mergeOptions"]).trim(),
            options
        );
    }
}

#[test]
fn unchanged_rebase_is_a_warning_and_leaves_refs_index_and_files_unchanged() {
    for same_tip in [false, true] {
        let dir = init_repo_with_commit();
        let source = head(dir.path());
        run_git(dir.path(), &["branch", "feature"]);
        if !same_tip {
            commit_file(dir.path(), "later.txt", "later\n", "later local change");
        }
        let session = open(dir.path());
        let before = session.head_position().unwrap();
        let refs = run_git(dir.path(), &["show-ref"]);
        let tree = rev(dir.path(), "HEAD^{tree}");
        let error = session
            .integrate_drop(
                source,
                Some("refs/heads/feature".into()),
                DropIntegration::Rebase,
                before.clone(),
            )
            .unwrap_err();
        assert!(error.to_string().contains("nothing to rebase"));
        assert_eq!(session.head_position().unwrap(), before);
        assert_eq!(run_git(dir.path(), &["show-ref"]), refs);
        assert_eq!(rev(dir.path(), "HEAD^{tree}"), tree);
        let status = session.status().unwrap();
        assert!(status.is_clean);
        assert!(!status.is_rebasing);
    }
}

#[test]
fn hidden_untracked_files_still_refuse_every_drop_integration() {
    for action in [
        DropIntegration::Merge,
        DropIntegration::Rebase,
        DropIntegration::CherryPick,
    ] {
        let (dir, source) = fixture();
        run_git(dir.path(), &["config", "status.showUntrackedFiles", "no"]);
        std::fs::create_dir(dir.path().join("nested")).unwrap();
        write(dir.path(), "nested/untracked.txt", "keep this file\n");
        assert!(run_git(dir.path(), &["status", "--porcelain"]).is_empty());
        let session = open(dir.path());
        assert!(
            session.status().unwrap().is_clean,
            "reproduce the display-status bypass"
        );
        let before = session.head_position().unwrap();
        let refs = run_git(dir.path(), &["show-ref"]);
        let index_tree = run_git(dir.path(), &["write-tree"]);
        let error = session
            .integrate_drop(
                source,
                Some("refs/heads/feature".into()),
                action,
                before.clone(),
            )
            .unwrap_err();
        assert!(error.to_string().contains("Commit or stash"));
        assert_eq!(session.head_position().unwrap(), before);
        assert_eq!(run_git(dir.path(), &["show-ref"]), refs);
        assert_eq!(run_git(dir.path(), &["write-tree"]), index_tree);
        assert_eq!(
            std::fs::read_to_string(dir.path().join("nested/untracked.txt")).unwrap(),
            "keep this file\n"
        );
        assert!(!dir.path().join("feature.txt").exists());
        assert!(run_git(dir.path(), &["stash", "list"]).is_empty());
    }
}

#[test]
fn hidden_submodule_changes_still_refuse_every_drop_integration() {
    for untracked in [false, true] {
        for action in [
            DropIntegration::Merge,
            DropIntegration::Rebase,
            DropIntegration::CherryPick,
        ] {
            let module_source = init_repo_with_commit();
            let (dir, source) = fixture();
            run_git(
                dir.path(),
                &[
                    "-c",
                    "protocol.file.allow=always",
                    "submodule",
                    "add",
                    module_source.path().to_str().unwrap(),
                    "module",
                ],
            );
            run_git(dir.path(), &["commit", "-m", "add module"]);
            run_git(dir.path(), &["config", "status.showUntrackedFiles", "no"]);
            run_git(dir.path(), &["config", "submodule.module.ignore", "all"]);
            run_git(dir.path(), &["config", "diff.ignoreSubmodules", "all"]);
            let module = dir.path().join("module");
            let filename = if untracked { "untracked.txt" } else { "a.txt" };
            write(&module, filename, "keep module change\n");
            assert!(run_git(dir.path(), &["status", "--porcelain"]).is_empty());
            let session = open(dir.path());
            let before = session.head_position().unwrap();
            let refs = run_git(dir.path(), &["show-ref"]);
            let index_tree = run_git(dir.path(), &["write-tree"]);
            let module_head = head(&module);
            let error = session
                .integrate_drop(
                    source,
                    Some("refs/heads/feature".into()),
                    action,
                    before.clone(),
                )
                .unwrap_err();
            assert!(error.to_string().contains("Commit or stash"));
            assert_eq!(session.head_position().unwrap(), before);
            assert_eq!(run_git(dir.path(), &["show-ref"]), refs);
            assert_eq!(run_git(dir.path(), &["write-tree"]), index_tree);
            assert_eq!(head(&module), module_head);
            assert_eq!(
                std::fs::read_to_string(module.join(filename)).unwrap(),
                "keep module change\n"
            );
            assert!(!dir.path().join("feature.txt").exists());
        }
    }
}

#[test]
fn ignored_files_do_not_block_an_otherwise_clean_drop() {
    let (dir, source) = fixture();
    write(dir.path(), ".git/info/exclude", "ignored.txt\n");
    write(dir.path(), "ignored.txt", "keep ignored file\n");
    let session = open(dir.path());
    let expected = session.head_position().unwrap();
    assert!(session
        .integrate_drop(source, None, DropIntegration::Merge, expected)
        .unwrap()
        .is_some());
    assert_eq!(
        std::fs::read_to_string(dir.path().join("ignored.txt")).unwrap(),
        "keep ignored file\n"
    );
}
