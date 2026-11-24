//! Merging a commit that HEAD already contains must be reported, not silently ignored.

mod common;

use common::{commit_file, head, open, run_git};
use gitcraft_core::MergeType;

#[test]
fn merging_a_commit_already_in_head_reports_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path();
    run_git(p, &["init", "-b", "main"]);
    commit_file(p, "a.txt", "alpha\n", "initial");
    run_git(p, &["checkout", "-b", "feature"]);
    let f1 = commit_file(p, "f.txt", "feature\n", "feature change");
    run_git(p, &["checkout", "main"]);
    run_git(p, &["merge", "--no-ff", "-m", "merge feature", "feature"]);
    let before = head(p);

    let session = open(p);
    for merge_type in [
        MergeType::Default,
        MergeType::NoFastForward,
        MergeType::FastForwardOnly,
        MergeType::Squash,
    ] {
        let err = session
            .merge_commit(f1.clone(), merge_type)
            .expect_err("already-merged commit must be an error");
        assert!(
            err.to_string().contains("nothing to merge")
                || format!("{err:?}").contains("nothing to merge"),
            "unexpected error: {err:?}"
        );
    }
    let branch_err = session
        .merge_branch("feature".into())
        .expect_err("already-merged branch must also report a warning");
    assert!(
        branch_err.to_string().contains("feature")
            && branch_err.to_string().contains("nothing to merge"),
        "unexpected error: {branch_err:?}"
    );
    assert_eq!(head(p), before, "HEAD must not move");
}
