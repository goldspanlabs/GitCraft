//! Force pushing rewritten history: when it is offered, and what the lease protects.

mod common;

use std::path::{Path, PathBuf};

use common::{
    commit_file, configure_git_identity, head, init_repo_with_commit, open, rev, run_git, write,
};
use gitcraft_core::ForcePushPlan;

const PULL_FIRST: &str = "origin/main has commits your branch doesn't. Pull first.";
const REMOTE_MOVED: &str = "The remote has new commits. Fetch, then try again.";

struct Fixture {
    repo: tempfile::TempDir,
    server: tempfile::TempDir,
}

impl Fixture {
    fn path(&self) -> &Path {
        self.repo.path()
    }

    fn remote_tip(&self, branch: &str) -> String {
        rev(self.server.path(), branch)
    }

    fn plan(&self) -> ForcePushPlan {
        open(self.path())
            .force_push_plan()
            .unwrap()
            .expect("a force push should be offered")
    }

    fn refusal(&self) -> String {
        open(self.path())
            .force_push_plan()
            .expect_err("force push should be refused")
            .to_string()
    }

    fn force_push_error(&self, plan: ForcePushPlan) -> String {
        match open(self.path()).force_push(plan) {
            Ok(_) => panic!("the force push went through"),
            Err(error) => error.to_string(),
        }
    }

    fn amend(&self, message: &str) {
        run_git(self.path(), &["commit", "--amend", "-q", "-m", message]);
    }

    /// Someone else pushes a commit to `main`.
    fn others_push(&self) -> String {
        let root = tempfile::tempdir().unwrap();
        let url = self.server.path().to_str().unwrap();
        run_git(root.path(), &["clone", "-q", url, "other"]);
        let other: PathBuf = root.path().join("other");
        configure_git_identity(&other);
        let oid = commit_file(&other, "theirs.txt", "theirs\n", "theirs");
        run_git(&other, &["push", "-q", "origin", "main"]);
        oid
    }
}

fn bare() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    run_git(dir.path(), &["init", "-q", "--bare", "-b", "main"]);
    dir
}

/// `initial`, A, B and C on `main`, pushed to a bare `origin` and tracking it.
fn pushed() -> Fixture {
    let repo = init_repo_with_commit();
    for name in ["A", "B", "C"] {
        commit_file(repo.path(), &format!("{name}.txt"), name, name);
    }
    let server = bare();
    let url = server.path().to_str().unwrap();
    run_git(repo.path(), &["remote", "add", "origin", url]);
    run_git(repo.path(), &["push", "-q", "-u", "origin", "main"]);
    Fixture { repo, server }
}

fn summaries(commits: &[gitcraft_core::PushCommit]) -> Vec<&str> {
    commits.iter().map(|c| c.summary.as_str()).collect()
}

#[test]
fn no_plan_without_a_remote_branch() {
    let repo = init_repo_with_commit();
    assert!(open(repo.path()).force_push_plan().unwrap().is_none());

    let fixture = pushed();
    run_git(fixture.path(), &["checkout", "-q", "-b", "unpublished"]);
    assert!(open(fixture.path()).force_push_plan().unwrap().is_none());
}

#[test]
fn no_plan_when_ahead_or_up_to_date() {
    let fixture = pushed();
    assert!(open(fixture.path()).force_push_plan().unwrap().is_none());
    commit_file(fixture.path(), "D.txt", "D", "D");
    assert!(open(fixture.path()).force_push_plan().unwrap().is_none());
}

#[test]
fn plans_after_a_squash() {
    let fixture = pushed();
    let tip = head(fixture.path());
    let session = open(fixture.path());
    let oids: Vec<String> = ["HEAD", "HEAD~1", "HEAD~2"]
        .iter()
        .map(|r| rev(fixture.path(), r))
        .collect();
    let preview = session.squash_preview(oids.clone()).unwrap();
    session
        .squash_commits(oids, "All three".into(), preview.head)
        .unwrap();

    let plan = fixture.plan();

    assert_eq!(summaries(&plan.removed), ["C", "B", "A"]);
    assert_eq!(summaries(&plan.added), ["All three"]);
    assert_eq!(plan.expected_remote_oid, tip);
    assert_eq!(plan.branch, "main");
    assert_eq!(plan.remote, "origin");
    assert_eq!(plan.destination, "origin/main");
    assert_eq!(plan.destination_ref, "refs/heads/main");
    assert_eq!(plan.head.oid, head(fixture.path()));
    assert!(tip.starts_with(&plan.removed[0].short_oid));
}

#[test]
fn plans_after_amend_and_after_rebase() {
    let fixture = pushed();
    fixture.amend("C amended");
    assert_eq!(summaries(&fixture.plan().added), ["C amended"]);

    let fixture = pushed();
    run_git(fixture.path(), &["checkout", "-q", "-b", "base", "HEAD~1"]);
    commit_file(fixture.path(), "base.txt", "base", "base");
    run_git(fixture.path(), &["checkout", "-q", "main"]);
    run_git(fixture.path(), &["rebase", "-q", "base"]);
    assert_eq!(summaries(&fixture.plan().added), ["C", "base"]);
}

#[test]
fn plans_after_reset_with_nothing_added() {
    let fixture = pushed();
    run_git(fixture.path(), &["reset", "-q", "--hard", "HEAD~1"]);

    let plan = fixture.plan();

    assert_eq!(summaries(&plan.removed), ["C"]);
    assert!(plan.added.is_empty());
}

#[test]
fn plans_without_an_upstream() {
    let fixture = pushed();
    run_git(fixture.path(), &["branch", "--unset-upstream"]);
    fixture.amend("C amended");
    assert_eq!(fixture.plan().destination, "origin/main");
}

#[test]
fn follows_the_push_destination() {
    let fixture = pushed();
    let fork = bare();
    let url = fork.path().to_str().unwrap();
    run_git(fixture.path(), &["remote", "add", "fork", url]);
    run_git(
        fixture.path(),
        &["config", "branch.main.pushRemote", "fork"],
    );
    run_git(fixture.path(), &["config", "push.default", "current"]);
    run_git(fixture.path(), &["push", "-q"]);
    fixture.amend("C amended");

    let plan = fixture.plan();
    assert_eq!(plan.remote, "fork");
    assert_eq!(plan.destination, "fork/main");

    open(fixture.path()).force_push(plan).unwrap();
    assert_eq!(rev(fork.path(), "main"), head(fixture.path()));
    assert_ne!(fixture.remote_tip("main"), head(fixture.path()));
}

#[test]
fn marks_the_default_branch() {
    let fixture = pushed();
    run_git(fixture.path(), &["remote", "set-head", "origin", "main"]);
    fixture.amend("C amended");
    assert!(fixture.plan().is_default_branch);

    run_git(fixture.path(), &["checkout", "-q", "-b", "feature"]);
    run_git(fixture.path(), &["push", "-q", "-u", "origin", "feature"]);
    fixture.amend("feature amended");
    assert!(!fixture.plan().is_default_branch);
}

#[test]
fn refuses_others_fetched_commits() {
    let fixture = pushed();
    fixture.others_push();
    commit_file(fixture.path(), "D.txt", "D", "D");
    run_git(fixture.path(), &["fetch", "-q"]);
    assert_eq!(fixture.refusal(), PULL_FIRST);
}

#[test]
fn behind_after_fetch_is_refused() {
    let fixture = pushed();
    fixture.others_push();
    run_git(fixture.path(), &["fetch", "-q"]);
    assert_eq!(fixture.refusal(), PULL_FIRST);
}

#[test]
fn no_offer_without_a_reflog() {
    let fixture = pushed();
    fixture.amend("C amended");
    run_git(
        fixture.path(),
        &["config", "core.logAllRefUpdates", "false"],
    );
    run_git(
        fixture.path(),
        &["reflog", "expire", "--expire=all", "--all"],
    );
    assert_eq!(fixture.refusal(), PULL_FIRST);
}

#[test]
fn force_push_replaces_the_remote_tip() {
    let fixture = pushed();
    fixture.amend("C amended");
    write(fixture.path(), "A.txt", "edited");
    write(fixture.path(), "new.txt", "new");
    let status = run_git(fixture.path(), &["status", "--porcelain"]);

    let result = open(fixture.path()).force_push(fixture.plan()).unwrap();

    assert!(result.forced);
    assert!(result.included_branch);
    assert_eq!(result.branch, "main");
    assert_eq!(result.destination, "origin/main");
    assert_eq!(fixture.remote_tip("main"), head(fixture.path()));
    assert_eq!(run_git(fixture.path(), &["status", "--porcelain"]), status);
}

#[test]
fn lease_stops_when_the_remote_moved() {
    for fetches in [false, true] {
        let fixture = pushed();
        fixture.amend("C amended");
        let plan = fixture.plan();
        let theirs = fixture.others_push();
        if fetches {
            run_git(fixture.path(), &["fetch", "-q"]);
        }

        assert_eq!(fixture.force_push_error(plan), REMOTE_MOVED);
        assert_eq!(fixture.remote_tip("main"), theirs);
    }
}

#[test]
fn lease_stops_when_the_remote_branch_was_deleted() {
    let fixture = pushed();
    fixture.amend("C amended");
    let plan = fixture.plan();
    run_git(
        fixture.server.path(),
        &["update-ref", "-d", "refs/heads/main"],
    );

    assert_eq!(fixture.force_push_error(plan), REMOTE_MOVED);
    assert_eq!(run_git(fixture.server.path(), &["for-each-ref"]), "");
}

#[test]
fn stops_when_head_moved() {
    let fixture = pushed();
    let tip = head(fixture.path());
    fixture.amend("C amended");
    let plan = fixture.plan();
    commit_file(fixture.path(), "D.txt", "D", "D");

    assert_eq!(
        fixture.force_push_error(plan),
        "The branch has changed since then. Push again."
    );
    assert_eq!(fixture.remote_tip("main"), tip);
}

#[test]
fn reports_a_server_refusal() {
    let fixture = pushed();
    let tip = head(fixture.path());
    run_git(
        fixture.server.path(),
        &["config", "receive.denyNonFastForwards", "true"],
    );
    fixture.amend("C amended");

    let error = fixture.force_push_error(fixture.plan());

    assert!(error.contains("non-fast-forward"), "{error}");
    assert_eq!(fixture.remote_tip("main"), tip);
}

#[test]
fn pushes_only_this_branch() {
    let fixture = pushed();
    run_git(fixture.path(), &["checkout", "-q", "-b", "other"]);
    let other = commit_file(fixture.path(), "other.txt", "other", "other");
    run_git(fixture.path(), &["push", "-q", "origin", "other"]);
    fixture.amend("other amended");
    run_git(fixture.path(), &["checkout", "-q", "main"]);
    run_git(fixture.path(), &["config", "push.default", "matching"]);
    fixture.amend("C amended");

    open(fixture.path()).force_push(fixture.plan()).unwrap();

    assert_eq!(fixture.remote_tip("main"), head(fixture.path()));
    assert_eq!(fixture.remote_tip("other"), other);
}

#[test]
fn without_an_upstream_targets_where_an_ordinary_push_goes() {
    let fixture = pushed();
    let fork = bare();
    let url = fork.path().to_str().unwrap();
    run_git(fixture.path(), &["remote", "add", "fork", url]);
    run_git(fixture.path(), &["push", "-q", "fork", "main"]);
    run_git(fixture.path(), &["branch", "--unset-upstream"]);
    run_git(
        fixture.path(),
        &["config", "branch.main.pushRemote", "fork"],
    );
    run_git(fixture.path(), &["config", "push.default", "current"]);
    let published = head(fixture.path());
    fixture.amend("C amended");

    // An ordinary first push goes to the default remote, so the force push does too.
    let plan = fixture.plan();
    assert_eq!(plan.destination, "origin/main");
    open(fixture.path()).force_push(plan).unwrap();

    assert_eq!(fixture.remote_tip("main"), head(fixture.path()));
    assert_eq!(rev(fork.path(), "main"), published);
}

/// `main` pushed to a server where fetching it lands in `origin/published`, with a decoy
/// server branch of that name at the same commit.
fn remapped_fetch() -> Fixture {
    let fixture = pushed();
    run_git(fixture.path(), &["push", "-q", "origin", "main:published"]);
    run_git(
        fixture.path(),
        &[
            "config",
            "remote.origin.fetch",
            "+refs/heads/main:refs/remotes/origin/published",
        ],
    );
    run_git(fixture.path(), &["fetch", "-q"]);
    fixture
}

#[test]
fn a_remapped_fetch_refspec_still_pushes_the_server_branch() {
    for has_upstream in [true, false] {
        let fixture = remapped_fetch();
        if !has_upstream {
            run_git(fixture.path(), &["branch", "--unset-upstream"]);
        }
        let decoy = fixture.remote_tip("published");
        fixture.amend("C amended");

        let plan = fixture.plan();
        assert_eq!(plan.destination_ref, "refs/heads/main", "{has_upstream}");
        assert_eq!(plan.destination, "origin/main");
        open(fixture.path()).force_push(plan).unwrap();

        assert_eq!(fixture.remote_tip("main"), head(fixture.path()));
        assert_eq!(fixture.remote_tip("published"), decoy);
    }
}

#[test]
fn follows_an_upstream_push_to_a_differently_named_branch() {
    let fixture = pushed();
    run_git(
        fixture.path(),
        &["push", "-q", "-u", "origin", "main:deploy"],
    );
    run_git(fixture.path(), &["config", "push.default", "upstream"]);
    fixture.amend("C amended");

    let plan = fixture.plan();

    assert_eq!(plan.destination_ref, "refs/heads/deploy");
    assert_eq!(plan.destination, "origin/deploy");
}

#[test]
fn follows_a_configured_push_refspec() {
    let fixture = pushed();
    run_git(
        fixture.path(),
        &[
            "config",
            "remote.origin.push",
            "refs/heads/main:refs/heads/deploy",
        ],
    );
    run_git(fixture.path(), &["push", "-q", "origin"]);
    fixture.amend("C amended");

    assert_eq!(fixture.plan().destination_ref, "refs/heads/deploy");
}

#[test]
fn pushes_the_confirmed_commit_rather_than_the_branch_name() {
    use std::os::unix::fs::PermissionsExt;

    let fixture = pushed();
    fixture.amend("C amended");
    // The pre-push hook is told what git was asked to push.
    let seen = fixture.path().join(".git/pushed-refs");
    let hook = fixture.path().join(".git/hooks/pre-push");
    std::fs::create_dir_all(hook.parent().unwrap()).unwrap();
    std::fs::write(&hook, format!("#!/bin/sh\ncat > '{}'\n", seen.display())).unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    run_git(fixture.path(), &["config", "core.hooksPath", ".git/hooks"]);
    let confirmed = head(fixture.path());

    let result = open(fixture.path()).force_push(fixture.plan()).unwrap();

    // A branch name could move between the check and git reading it; a commit ID can't.
    let line = std::fs::read_to_string(seen).unwrap();
    assert!(
        line.starts_with(&format!("{confirmed} {confirmed} ")),
        "{line}"
    );
    assert!(result.forced && result.included_branch);
    assert_eq!(result.branch, "main");
    assert_eq!(fixture.remote_tip("main"), confirmed);
}
