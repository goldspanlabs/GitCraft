mod common;

use std::{fs, path::Path};

use common::{configure_git_identity, run_git};
use gitcraft_core::RepoSession;

fn commit(repo: &Path, name: &str) {
    fs::write(repo.join(name), name).unwrap();
    run_git(repo, &["add", "."]);
    run_git(repo, &["commit", "-q", "-m", name]);
}

#[test]
fn ahead_and_behind_with_and_without_a_configured_upstream() {
    let dir = tempfile::tempdir().unwrap();
    let remote = dir.path().join("remote.git");
    let repo = dir.path().join("clone");
    run_git(
        dir.path(),
        &[
            "init",
            "-q",
            "--bare",
            "-b",
            "main",
            remote.to_str().unwrap(),
        ],
    );
    run_git(
        dir.path(),
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            repo.to_str().unwrap(),
        ],
    );
    configure_git_identity(&repo);
    commit(&repo, "base");
    run_git(&repo, &["push", "-q", "-u", "origin", "main"]);

    // `tracked` has a configured upstream, one commit ahead of it and two behind.
    run_git(&repo, &["checkout", "-q", "-b", "tracked"]);
    commit(&repo, "t1");
    commit(&repo, "t2");
    run_git(&repo, &["push", "-q", "-u", "origin", "tracked"]);
    run_git(&repo, &["reset", "-q", "--hard", "main"]);
    commit(&repo, "t3");

    // `loose` only shares its name with a remote branch.
    run_git(&repo, &["checkout", "-q", "-b", "loose", "main"]);
    commit(&repo, "l1");
    run_git(&repo, &["push", "-q", "origin", "loose"]);
    commit(&repo, "l2");
    commit(&repo, "l3");

    // `gone` tracks a remote branch that no longer exists.
    run_git(&repo, &["checkout", "-q", "-b", "gone", "main"]);
    run_git(&repo, &["push", "-q", "-u", "origin", "gone"]);
    run_git(&repo, &["push", "-q", "origin", "--delete", "gone"]);
    commit(&repo, "g1");

    let session = RepoSession::new(repo.to_string_lossy().into_owned()).unwrap();
    let branches = session.list_branches().unwrap();
    let counts = |name: &str| {
        let branch = branches
            .iter()
            .find(|b| !b.is_remote && b.name == name)
            .unwrap();
        (branch.ahead, branch.behind)
    };
    assert_eq!(counts("main"), (0, 0));
    assert_eq!(counts("tracked"), (1, 2));
    assert_eq!(counts("loose"), (2, 0));
    assert_eq!(counts("gone"), (0, 0));
}
