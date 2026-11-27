//! Squashing consecutive commits: which selections are allowed, and what the rewrite keeps.

mod common;

use std::{path::Path, process::Command};

use common::{commit_file, head, init_repo, init_repo_with_commit, open, rev, run_git, write};
use gitcraft_core::{ResetMode, SquashResult};

/// Why the core refuses to squash `oids`.
fn refusal(dir: &Path, oids: &[&str]) -> String {
    match open(dir).squash_preview(owned(oids)) {
        Ok(_) => panic!("squashing {oids:?} was allowed"),
        Err(error) => error.to_string(),
    }
}

fn owned(oids: &[&str]) -> Vec<String> {
    oids.iter().map(|o| (*o).to_owned()).collect()
}

/// Runs a git command that is expected to stop on a conflict.
fn git_that_fails(dir: &Path, args: &[&str]) {
    let status = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap()
        .status;
    assert!(!status.success(), "git {args:?} was expected to fail");
}

/// `initial`, then commits A, B and C on `main`.
fn three_commits() -> (tempfile::TempDir, String, String, String) {
    let dir = init_repo_with_commit();
    let a = commit_file(dir.path(), "one.txt", "one\n", "A");
    let b = commit_file(dir.path(), "two.txt", "two\n", "B");
    let c = commit_file(dir.path(), "three.txt", "three\n", "C");
    (dir, a, b, c)
}

#[test]
fn previews_commits_oldest_first_from_any_order() {
    let (dir, a, b, c) = three_commits();

    let preview = open(dir.path())
        .squash_preview(owned(&[&c, &a, &b, &b]))
        .unwrap();

    let oids: Vec<_> = preview.commits.iter().map(|x| x.oid_hex.clone()).collect();
    assert_eq!(oids, [a.clone(), b, c.clone()]);
    assert_eq!(preview.commits[0].summary, "A");
    assert_eq!(preview.commits[0].author_name, "GitCraft Tester");
    assert_eq!(preview.commits[0].author_email, "tester@gitcraft.local");
    assert!(a.starts_with(&preview.commits[0].short_oid));
    assert_eq!(preview.head.oid, c);
    assert_eq!(preview.head.branch.as_deref(), Some("refs/heads/main"));
    assert!(!preview.is_pushed);
}

#[test]
fn preview_splits_summary_and_body() {
    let (dir, _, _, c) = three_commits();
    write(dir.path(), "four.txt", "four\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(
        dir.path(),
        &["commit", "-m", "D", "-m", "Because.\nReally."],
    );
    let d = head(dir.path());

    let preview = open(dir.path()).squash_preview(owned(&[&c, &d])).unwrap();

    assert_eq!(preview.commits[1].summary, "D");
    assert_eq!(preview.commits[1].body, "Because.\nReally.");
}

#[test]
fn refuses_fewer_than_two() {
    let (dir, _, _, c) = three_commits();
    assert_eq!(refusal(dir.path(), &[&c]), "Select at least two commits");
    assert_eq!(
        refusal(dir.path(), &[&c, &c]),
        "Select at least two commits"
    );
}

#[test]
fn refuses_detached_head() {
    let (dir, _, b, c) = three_commits();
    run_git(dir.path(), &["checkout", "-q", "--detach"]);
    assert_eq!(
        refusal(dir.path(), &[&b, &c]),
        "Check out a branch to squash commits"
    );
}

/// `main` and `other` both change `a.txt`, after two commits on `main` that can be selected.
fn conflicting_branches() -> (tempfile::TempDir, String, String) {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["checkout", "-q", "-b", "other"]);
    commit_file(dir.path(), "a.txt", "other\n", "other");
    run_git(dir.path(), &["checkout", "-q", "main"]);
    let first = commit_file(dir.path(), "x.txt", "x\n", "x");
    let second = commit_file(dir.path(), "a.txt", "main\n", "main");
    (dir, first, second)
}

#[test]
fn refuses_during_an_operation() {
    for args in [
        &["merge", "other"][..],
        &["rebase", "other"][..],
        &["cherry-pick", "other"][..],
    ] {
        let (dir, first, second) = conflicting_branches();
        git_that_fails(dir.path(), args);
        // A stopped rebase detaches HEAD, so that reason comes first.
        let expected = if args[0] == "rebase" {
            "Check out a branch to squash commits"
        } else {
            "Finish the current operation first"
        };
        assert_eq!(
            refusal(dir.path(), &[&first, &second]),
            expected,
            "{args:?}"
        );
    }

    // A revert of an older commit that a newer one changed again.
    let (dir, first, second) = conflicting_branches();
    let third = commit_file(dir.path(), "a.txt", "again\n", "again");
    git_that_fails(dir.path(), &["revert", "--no-edit", &second]);
    assert_eq!(
        refusal(dir.path(), &[&first, &third]),
        "Finish the current operation first"
    );

    // Conflicts without any operation in progress.
    let (dir, first, second) = conflicting_branches();
    write(dir.path(), "a.txt", "stashed\n");
    run_git(dir.path(), &["stash"]);
    let third = commit_file(dir.path(), "a.txt", "committed\n", "third");
    git_that_fails(dir.path(), &["stash", "pop"]);
    assert_eq!(
        refusal(dir.path(), &[&second, &third]),
        "Finish the current operation first",
        "unmerged index after {first}"
    );
}

#[test]
fn refuses_commits_off_the_branch() {
    let (dir, _, b, c) = three_commits();
    run_git(dir.path(), &["checkout", "-q", "-b", "side", &b]);
    let side = commit_file(dir.path(), "side.txt", "side\n", "side");
    run_git(dir.path(), &["checkout", "-q", "main"]);
    assert_eq!(
        refusal(dir.path(), &[&c, &side]),
        "Select commits on the current branch"
    );

    // Reachable only through the merge's second parent.
    run_git(
        dir.path(),
        &["merge", "--no-ff", "-m", "merge side", "side"],
    );
    assert_eq!(
        refusal(dir.path(), &[&c, &side]),
        "Select commits on the current branch"
    );
}

#[test]
fn refuses_gaps() {
    let (dir, a, _, c) = three_commits();
    assert_eq!(refusal(dir.path(), &[&a, &c]), "Select consecutive commits");
}

#[test]
fn refuses_merges() {
    let (dir, a, b, c) = three_commits();
    run_git(dir.path(), &["checkout", "-q", "-b", "side", &a]);
    commit_file(dir.path(), "side.txt", "side\n", "side");
    run_git(dir.path(), &["checkout", "-q", "main"]);
    run_git(
        dir.path(),
        &["merge", "--no-ff", "-m", "merge side", "side"],
    );
    let merge = head(dir.path());

    assert_eq!(
        refusal(dir.path(), &[&c, &merge]),
        "Can't squash across a merge commit",
        "merge in the selection"
    );
    assert_eq!(
        refusal(dir.path(), &[&a, &b]),
        "Can't squash across a merge commit",
        "merge above the selection"
    );
}

#[test]
fn refuses_a_shallow_boundary() {
    let (source, _, _, _) = three_commits();
    let root = tempfile::tempdir().unwrap();
    let url = format!("file://{}", source.path().display());
    run_git(root.path(), &["clone", "-q", "--depth", "2", &url, "clone"]);
    let clone = root.path().join("clone");

    assert_eq!(
        refusal(&clone, &[&rev(&clone, "HEAD~1"), &head(&clone)]),
        "History is incomplete in this shallow clone"
    );
}

#[test]
fn refuses_changes_that_cancel_out() {
    let (dir, _, _, _) = three_commits();
    let added = commit_file(dir.path(), "temp.txt", "temp\n", "add temp");
    run_git(dir.path(), &["rm", "-q", "temp.txt"]);
    run_git(dir.path(), &["commit", "-q", "-m", "remove temp"]);

    assert_eq!(
        refusal(dir.path(), &[&added, &head(dir.path())]),
        "These commits cancel each other out"
    );
}

#[test]
fn allows_the_first_commit() {
    let dir = init_repo();
    let root = commit_file(dir.path(), "a.txt", "a\n", "root");
    let child = commit_file(dir.path(), "b.txt", "b\n", "child");

    assert!(open(dir.path())
        .squash_preview(owned(&[&root, &child]))
        .is_ok());
}

#[test]
fn marks_pushed_commits() {
    let (dir, a, b, c) = three_commits();
    run_git(dir.path(), &["update-ref", "refs/remotes/origin/main", &a]);
    let session = open(dir.path());

    assert!(session.squash_preview(owned(&[&a, &b])).unwrap().is_pushed);
    assert!(!session.squash_preview(owned(&[&b, &c])).unwrap().is_pushed);
}

// ---------------------------------------------------------------- rewrite ---

/// Previews and squashes `oids` with `message`, as the app does.
fn squash(dir: &Path, oids: &[&str], message: &str) -> SquashResult {
    let session = open(dir);
    let preview = session.squash_preview(owned(oids)).unwrap();
    session
        .squash_commits(owned(oids), message.to_owned(), preview.head)
        .unwrap()
}

/// The raw commit object, headers and message.
fn commit_bytes(dir: &Path, name: &str) -> Vec<u8> {
    let out = Command::new("git")
        .args(["cat-file", "commit", name])
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success());
    out.stdout
}

/// The raw header lines starting with `key`.
fn header(commit: &[u8], key: &str) -> Vec<u8> {
    commit
        .split(|b| *b == b'\n')
        .take_while(|line| !line.is_empty())
        .filter(|line| line.starts_with(key.as_bytes()))
        .flat_map(|line| line.to_vec())
        .collect()
}

/// Everything after the headers.
fn message_bytes(commit: &[u8]) -> Vec<u8> {
    let at = commit.windows(2).position(|w| w == b"\n\n").unwrap();
    commit[at + 2..].to_vec()
}

fn subjects(dir: &Path) -> Vec<String> {
    run_git(dir, &["log", "--format=%s"])
        .lines()
        .map(str::to_owned)
        .collect()
}

fn porcelain(dir: &Path) -> String {
    run_git(dir, &["status", "--porcelain"])
}

#[test]
fn squashes_at_head() {
    let (dir, a, b, c) = three_commits();
    let base = rev(dir.path(), &format!("{a}^"));
    let tree = rev(dir.path(), "HEAD^{tree}");

    let result = squash(dir.path(), &[&a, &b, &c], "Subject\n\nBody");

    assert_eq!(result.squashed_oid, head(dir.path()));
    assert_eq!(result.head_move.before.oid, c);
    assert_eq!(result.head_move.after.oid, result.squashed_oid);
    assert_eq!(rev(dir.path(), "HEAD^"), base);
    assert_eq!(rev(dir.path(), "HEAD^{tree}"), tree);
    assert_eq!(
        message_bytes(&commit_bytes(dir.path(), "HEAD")),
        b"Subject\n\nBody\n"
    );
    assert_eq!(subjects(dir.path()), ["Subject", "initial"]);
}

#[test]
fn keeps_the_oldest_author_and_date() {
    let dir = init_repo_with_commit();
    write(dir.path(), "one.txt", "one\n");
    run_git(dir.path(), &["add", "-A"]);
    // `--author` and `--date` win over the helper's fixed environment.
    run_git(
        dir.path(),
        &[
            "commit",
            "-m",
            "A",
            "--author=Ada <ada@example.com>",
            "--date=2025-03-04T05:06:07+0200",
        ],
    );
    let a = head(dir.path());
    let b = commit_file(dir.path(), "two.txt", "two\n", "B");
    let author = header(&commit_bytes(dir.path(), &a), "author ");

    squash(dir.path(), &[&a, &b], "Both");

    let squashed = commit_bytes(dir.path(), "HEAD");
    assert_eq!(header(&squashed, "author "), author);
    let committer = String::from_utf8(header(&squashed, "committer ")).unwrap();
    assert!(
        committer.starts_with("committer GitCraft Tester <tester@gitcraft.local>"),
        "{committer}"
    );
}

#[test]
fn recreates_commits_above() {
    let (dir, a, b, c) = three_commits();
    let d = commit_file(dir.path(), "four.txt", "four\n", "D");
    let e = commit_file(dir.path(), "five.txt", "five\n", "E");

    let result = squash(dir.path(), &[&b, &c], "B and C");

    assert_eq!(subjects(dir.path()), ["E", "D", "B and C", "A", "initial"]);
    assert_eq!(rev(dir.path(), "HEAD~3"), a);
    assert_eq!(rev(dir.path(), "HEAD~2"), result.squashed_oid);
    for (new, old) in [("HEAD", &e), ("HEAD~1", &d)] {
        let (new, old) = (commit_bytes(dir.path(), new), commit_bytes(dir.path(), old));
        assert_eq!(header(&new, "tree "), header(&old, "tree "));
        assert_eq!(header(&new, "author "), header(&old, "author "));
        assert_eq!(message_bytes(&new), message_bytes(&old));
    }
}

#[test]
fn preserves_messages_byte_for_byte() {
    let (dir, _, b, c) = three_commits();
    let message = dir.path().join(".git/test-message");
    let message_path = message.to_str().unwrap();

    std::fs::write(&message, "D\n\n\n# not a comment\n\n\ntrailing   \n\n").unwrap();
    write(dir.path(), "four.txt", "four\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(
        dir.path(),
        &["commit", "--cleanup=verbatim", "-F", message_path],
    );
    let d = head(dir.path());

    std::fs::write(&message, b"caf\xe9\n").unwrap();
    write(dir.path(), "five.txt", "five\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(
        dir.path(),
        &[
            "-c",
            "i18n.commitEncoding=ISO-8859-1",
            "commit",
            "-F",
            message_path,
        ],
    );
    let e = head(dir.path());

    squash(dir.path(), &[&b, &c], "B and C");

    for (new, old) in [("HEAD", &e), ("HEAD~1", &d)] {
        let (new, old) = (commit_bytes(dir.path(), new), commit_bytes(dir.path(), old));
        assert_eq!(message_bytes(&new), message_bytes(&old));
        assert_eq!(header(&new, "encoding "), header(&old, "encoding "));
    }
}

#[test]
fn squashes_the_first_commit() {
    let dir = init_repo();
    let root = commit_file(dir.path(), "a.txt", "a\n", "root");
    let child = commit_file(dir.path(), "b.txt", "b\n", "child");

    squash(dir.path(), &[&root, &child], "Start");

    assert_eq!(subjects(dir.path()), ["Start"]);
    assert!(header(&commit_bytes(dir.path(), "HEAD"), "parent ").is_empty());
}

/// One staged edit, one unstaged edit and one untracked file.
fn dirty(dir: &Path) {
    write(dir, "staged.txt", "staged\n");
    run_git(dir, &["add", "staged.txt"]);
    write(dir, "b.txt", "unstaged\n");
    write(dir, "untracked.txt", "untracked\n");
}

#[test]
fn leaves_staged_unstaged_and_untracked_changes() {
    let (dir, a, b, _) = three_commits();
    dirty(dir.path());
    let before = porcelain(dir.path());

    squash(dir.path(), &[&a, &b], "A and B");

    assert_eq!(porcelain(dir.path()), before);
    for (name, contents) in [
        ("staged.txt", "staged\n"),
        ("b.txt", "unstaged\n"),
        ("untracked.txt", "untracked\n"),
    ] {
        assert_eq!(
            std::fs::read_to_string(dir.path().join(name)).unwrap(),
            contents
        );
    }
}

#[test]
fn leaves_other_branches_and_tags() {
    let (dir, a, b, c) = three_commits();
    run_git(dir.path(), &["branch", "keep", &b]);
    run_git(dir.path(), &["tag", "v1", &b]);

    squash(dir.path(), &[&a, &b, &c], "All");

    assert_eq!(rev(dir.path(), "keep"), b);
    assert_eq!(rev(dir.path(), "v1"), b);
}

#[test]
fn refuses_when_the_branch_moved() {
    const MOVED: &str = "The branch has changed since then. Select the commits again.";
    let (dir, a, b, c) = three_commits();
    let session = open(dir.path());
    let preview = session.squash_preview(owned(&[&a, &b])).unwrap();

    // Another branch at the same commit.
    run_git(dir.path(), &["checkout", "-q", "-b", "twin"]);
    let error = session
        .squash_commits(owned(&[&a, &b]), "x".into(), preview.head.clone())
        .unwrap_err();
    assert_eq!(error.to_string(), MOVED);
    assert_eq!(rev(dir.path(), "twin"), c);
    assert_eq!(rev(dir.path(), "main"), c);

    run_git(dir.path(), &["checkout", "-q", "main"]);
    let d = commit_file(dir.path(), "four.txt", "four\n", "D");
    let error = session
        .squash_commits(owned(&[&a, &b]), "x".into(), preview.head)
        .unwrap_err();
    assert_eq!(error.to_string(), MOVED);
    assert_eq!(rev(dir.path(), "main"), d);
}

#[test]
fn refuses_a_blank_message() {
    let (dir, a, b, c) = three_commits();
    let session = open(dir.path());
    let preview = session.squash_preview(owned(&[&a, &b])).unwrap();

    assert!(session
        .squash_commits(owned(&[&a, &b]), "  \n".into(), preview.head)
        .is_err());
    assert_eq!(head(dir.path()), c);
}

#[test]
fn signs_when_configured_and_fails_cleanly() {
    let (dir, a, b, c) = three_commits();
    run_git(dir.path(), &["config", "commit.gpgsign", "true"]);
    run_git(dir.path(), &["config", "gpg.program", "false"]);
    let session = open(dir.path());
    let preview = session.squash_preview(owned(&[&a, &b])).unwrap();

    assert!(session
        .squash_commits(owned(&[&a, &b]), "x".into(), preview.head)
        .is_err());
    assert_eq!(head(dir.path()), c);
}

#[test]
fn signs_with_the_configured_program() {
    use std::os::unix::fs::PermissionsExt;

    let (dir, a, b, _) = three_commits();
    let program = dir.path().join(".git/fake-gpg");
    std::fs::write(
        &program,
        "#!/bin/sh\ncat >/dev/null\necho '[GNUPG:] SIG_CREATED ' >&2\n\
         printf -- '-----BEGIN PGP SIGNATURE-----\\nfake\\n-----END PGP SIGNATURE-----\\n'\n",
    )
    .unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
    run_git(dir.path(), &["config", "commit.gpgsign", "true"]);
    run_git(
        dir.path(),
        &["config", "gpg.program", program.to_str().unwrap()],
    );

    // A and B, leaving C above.
    squash(dir.path(), &[&a, &b], "A and B");

    for name in ["HEAD", "HEAD~1"] {
        assert!(
            !header(&commit_bytes(dir.path(), name), "gpgsig ").is_empty(),
            "{name} is unsigned"
        );
    }
}

#[test]
fn undo_and_redo_restore_both_ends() {
    let (dir, a, b, c) = three_commits();
    dirty(dir.path());
    let before = porcelain(dir.path());
    let moved = squash(dir.path(), &[&a, &b], "A and B").head_move;
    let session = open(dir.path());

    session
        .undo_head_move(
            moved.after.clone(),
            moved.before.oid.clone(),
            ResetMode::Soft,
        )
        .unwrap();
    assert_eq!(head(dir.path()), c);
    assert_eq!(porcelain(dir.path()), before);

    session
        .undo_head_move(moved.before, moved.after.oid.clone(), ResetMode::Soft)
        .unwrap();
    assert_eq!(head(dir.path()), moved.after.oid);
    assert_eq!(porcelain(dir.path()), before);
}

/// Writes a commit object exactly as given and moves `main` to it. Git's own commands would
/// tidy the author and message first.
fn commit_raw(dir: &Path, author: &str, message: &[u8]) -> String {
    let tree = rev(dir, "HEAD^{tree}");
    let mut object = format!(
        "tree {tree}\nparent {}\nauthor {author} 1700000000 +0130\n\
         committer C <c@x> 1700000000 +0000\n\n",
        head(dir)
    )
    .into_bytes();
    object.extend_from_slice(message);
    let file = dir.join(".git/raw-commit");
    std::fs::write(&file, object).unwrap();
    let oid = run_git(
        dir,
        &["hash-object", "-t", "commit", "-w", file.to_str().unwrap()],
    )
    .trim()
    .to_owned();
    run_git(dir, &["update-ref", "refs/heads/main", &oid]);
    oid
}

#[test]
fn keeps_unlabelled_non_utf8_messages_and_unusual_authors() {
    let (dir, a, b, _) = three_commits();
    let message = b"caf\xe9\n\nbody \xff\n";
    let latin = commit_raw(dir.path(), "Ada <ada@x>", message);
    let quoted = commit_raw(dir.path(), "\"Jo, Q\" <jo@x>", b"quoted\n");

    squash(dir.path(), &[&a, &b], "A and B");

    for (new, old) in [("HEAD", &quoted), ("HEAD~1", &latin)] {
        let (new, old) = (commit_bytes(dir.path(), new), commit_bytes(dir.path(), old));
        assert_eq!(header(&new, "author "), header(&old, "author "));
        assert_eq!(header(&new, "encoding "), header(&old, "encoding "));
        assert_eq!(message_bytes(&new), message_bytes(&old));
    }
}

#[test]
fn keeps_an_unusual_author_on_the_combined_commit() {
    let (dir, _, _, c) = three_commits();
    let quoted = commit_raw(dir.path(), "\"Jo, Q\" <jo@x>", b"quoted\n");
    write(dir.path(), "four.txt", "four\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-q", "-m", "D"]);
    let d = head(dir.path());

    squash(dir.path(), &[&quoted, &d], "Both");

    assert_eq!(rev(dir.path(), "HEAD^"), c);
    assert_eq!(
        header(&commit_bytes(dir.path(), "HEAD"), "author "),
        header(&commit_bytes(dir.path(), &quoted), "author ")
    );
}

#[test]
fn refuses_to_sign_a_commit_it_cannot_keep_unchanged() {
    use std::os::unix::fs::PermissionsExt;

    let (dir, a, b, _) = three_commits();
    let latin = commit_raw(dir.path(), "Ada <ada@x>", b"caf\xe9\n");
    let program = dir.path().join(".git/fake-gpg");
    std::fs::write(
        &program,
        "#!/bin/sh\ncat >/dev/null\necho '[GNUPG:] SIG_CREATED ' >&2\necho signature\n",
    )
    .unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
    run_git(dir.path(), &["config", "commit.gpgsign", "true"]);
    run_git(
        dir.path(),
        &["config", "gpg.program", program.to_str().unwrap()],
    );
    let session = open(dir.path());
    let preview = session.squash_preview(owned(&[&a, &b])).unwrap();

    let error = session
        .squash_commits(owned(&[&a, &b]), "x".into(), preview.head)
        .unwrap_err()
        .to_string();

    assert_eq!(
        error,
        format!(
            "Commit {} can't be signed without changing its author or message. \
             Turn off commit signing to squash.",
            &latin[..7]
        )
    );
    assert_eq!(head(dir.path()), latin);
}
