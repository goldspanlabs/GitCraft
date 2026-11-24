//! Merging a commit that HEAD already contains must be reported, not silently ignored.

use std::{fs, path::Path, process::Command};

use gitcraft_core::{MergeType, RepoSession};

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "GitCraft Tester")
        .env("GIT_AUTHOR_EMAIL", "tester@gitcraft.local")
        .env("GIT_COMMITTER_NAME", "GitCraft Tester")
        .env("GIT_COMMITTER_EMAIL", "tester@gitcraft.local")
        .env("GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z")
        .env("GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z")
        .output()
        .expect("git");
    assert!(
        out.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn head(dir: &Path) -> String {
    git(dir, &["rev-parse", "HEAD"]).trim().to_owned()
}

fn commit_file(dir: &Path, name: &str, contents: &str, msg: &str) -> String {
    fs::write(dir.join(name), contents).unwrap();
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-m", msg]);
    head(dir)
}

#[test]
fn merging_a_commit_already_in_head_reports_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path();
    git(p, &["init", "-b", "main"]);
    commit_file(p, "a.txt", "alpha\n", "initial");
    git(p, &["checkout", "-b", "feature"]);
    let f1 = commit_file(p, "f.txt", "feature\n", "feature change");
    git(p, &["checkout", "main"]);
    git(p, &["merge", "--no-ff", "-m", "merge feature", "feature"]);
    let before = head(p);

    let session = RepoSession::new(p.to_string_lossy().into_owned()).unwrap();
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
    assert_eq!(head(p), before, "HEAD must not move");
}
