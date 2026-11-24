//! Direct coverage of `RepoSession` methods that the existing integration
//! tests reach only indirectly (or not at all): unstaging, working-tree diffs,
//! syntax highlighting, and the error paths of mutating operations.

use std::{fs, path::Path, process::Command};

use gitcraft_core::{PullStrategy, RepoSession};

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
        "git {:?} in {} failed:\nstdout: {}\nstderr: {}",
        args,
        dir.display(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// Creates a repo on `main` with a local identity configured, and no commits.
fn init_repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    run_git(dir.path(), &["init", "-b", "main"]);
    run_git(dir.path(), &["config", "user.name", "GitCraft Tester"]);
    run_git(
        dir.path(),
        &["config", "user.email", "tester@gitcraft.local"],
    );
    dir
}

fn write(dir: &Path, name: &str, contents: &str) {
    fs::write(dir.join(name), contents).unwrap();
}

/// Creates a repo with one commit containing `a.txt` and `b.txt`.
fn init_repo_with_commit() -> tempfile::TempDir {
    let dir = init_repo();
    write(dir.path(), "a.txt", "alpha\n");
    write(dir.path(), "b.txt", "bravo\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "initial"]);
    dir
}

fn open(dir: &Path) -> RepoSession {
    RepoSession::new(dir.to_string_lossy().into_owned()).unwrap()
}

// ---------------------------------------------------------------- staging ---

#[test]
fn stage_and_unstage_single_file_roundtrip() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    write(dir.path(), "a.txt", "alpha changed\n");
    session.stage("a.txt".into()).unwrap();

    let status = session.status().unwrap();
    assert!(status
        .staged_files
        .iter()
        .any(|f| f.path == "a.txt" && f.staged));
    assert!(status.unstaged_files.is_empty());

    session.unstage("a.txt".into()).unwrap();

    let status = session.status().unwrap();
    assert!(status.staged_files.is_empty());
    assert!(status
        .unstaged_files
        .iter()
        .any(|f| f.path == "a.txt" && !f.staged));
}

#[test]
fn stage_nonexistent_path_is_an_error() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session.stage("does-not-exist.txt".into()).is_err());
}

#[test]
fn stage_all_and_unstage_all() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    write(dir.path(), "a.txt", "alpha changed\n");
    write(dir.path(), "b.txt", "bravo changed\n");
    write(dir.path(), "new.txt", "fresh\n");

    session.stage_all().unwrap();
    let status = session.status().unwrap();
    assert_eq!(status.staged_files.len(), 3);
    assert!(status.unstaged_files.is_empty());

    session.unstage_all().unwrap();
    let status = session.status().unwrap();
    assert!(status.staged_files.is_empty());
    // Modified tracked files are unstaged; the new file stays untracked.
    assert!(status.unstaged_files.iter().any(|f| f.path == "a.txt"));
    assert!(status
        .unstaged_files
        .iter()
        .any(|f| f.path == "new.txt" && f.status == "?"));
}

#[test]
fn unstage_works_in_repo_without_any_commits() {
    // `git reset HEAD` has no HEAD to reset to here, so unstage must fall back
    // to `git rm --cached`.
    let dir = init_repo();
    write(dir.path(), "first.txt", "hello\n");
    run_git(dir.path(), &["add", "first.txt"]);

    let session = open(dir.path());
    session.unstage("first.txt".into()).unwrap();

    let status = session.status().unwrap();
    assert!(status.staged_files.is_empty());
    assert!(
        dir.path().join("first.txt").exists(),
        "unstage must not delete the file"
    );
}

#[test]
fn unstage_all_works_in_repo_without_any_commits() {
    let dir = init_repo();
    write(dir.path(), "one.txt", "1\n");
    write(dir.path(), "two.txt", "2\n");
    run_git(dir.path(), &["add", "-A"]);

    let session = open(dir.path());
    session.unstage_all().unwrap();

    let status = session.status().unwrap();
    assert!(status.staged_files.is_empty());
    assert!(dir.path().join("one.txt").exists());
    assert!(dir.path().join("two.txt").exists());
}

// ------------------------------------------------------------------ diffs ---

#[test]
fn working_diff_reports_unstaged_then_staged_changes() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    write(dir.path(), "a.txt", "alpha\nadded line\n");

    let unstaged = session
        .get_working_diff(Some("a.txt".into()), false)
        .unwrap();
    assert!(
        unstaged
            .iter()
            .any(|r| r.kind == "addition" && r.text == "+added line"),
        "unstaged diff missing addition: {unstaged:?}"
    );

    // The unstaged-only `diff()` should report the same change.
    let all_unstaged = session.diff().unwrap();
    assert!(all_unstaged
        .iter()
        .any(|r| r.kind == "addition" && r.text == "+added line"));

    session.stage("a.txt".into()).unwrap();

    assert!(session
        .get_working_diff(Some("a.txt".into()), false)
        .unwrap()
        .is_empty());
    let staged = session
        .get_working_diff(Some("a.txt".into()), true)
        .unwrap();
    assert!(staged
        .iter()
        .any(|r| r.kind == "addition" && r.text == "+added line"));
    assert!(session.diff().unwrap().is_empty());
}

#[test]
fn working_diff_for_untracked_file_is_synthetic_hunk() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    write(dir.path(), "notes.txt", "one\ntwo\nthree\n");

    let rows = session
        .get_working_diff(Some("notes.txt".into()), false)
        .unwrap();
    assert_eq!(rows.first().map(|r| r.kind.as_str()), Some("hunk"));
    assert!(
        rows[0].text.contains("(untracked)"),
        "got: {}",
        rows[0].text
    );
    assert_eq!(rows.iter().filter(|r| r.kind == "addition").count(), 3);
}

#[test]
fn commit_diff_can_be_filtered_to_one_path() {
    let dir = init_repo_with_commit();
    write(dir.path(), "a.txt", "alpha\nmore\n");
    write(dir.path(), "b.txt", "bravo\nmore\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "touch both"]);
    let oid = run_git(dir.path(), &["rev-parse", "HEAD"])
        .trim()
        .to_owned();

    let session = open(dir.path());

    let all = session.get_commit_diff(oid.clone(), None).unwrap();
    assert_eq!(all.iter().filter(|r| r.text == "+more").count(), 2);

    let only_a = session.get_commit_diff(oid, Some("a.txt".into())).unwrap();
    assert_eq!(only_a.iter().filter(|r| r.text == "+more").count(), 1);
    assert!(only_a.iter().all(|r| !r.text.contains("bravo")));
}

// -------------------------------------------------------------- highlight ---

#[test]
fn highlight_colors_known_extension_and_covers_whole_text() {
    let dir = init_repo();
    let session = open(dir.path());

    let text = "fn main() {\n    println!(\"hi\");\n}\n";
    let spans = session.highlight(text, "rs");

    assert!(!spans.is_empty());
    assert!(spans
        .iter()
        .all(|s| s.foreground.starts_with('#') && s.foreground.len() == 7));

    // Tokens should tile the entire input in UTF-16 code units.
    let covered: u32 = spans.iter().map(|s| s.len_utf16).sum();
    assert_eq!(covered, text.encode_utf16().count() as u32);
}

#[test]
fn highlight_unknown_extension_falls_back_to_plain_text() {
    let dir = init_repo();
    let session = open(dir.path());

    let text = "just some words\n";
    let spans = session.highlight(text, "no-such-ext");

    let covered: u32 = spans.iter().map(|s| s.len_utf16).sum();
    assert_eq!(covered, text.encode_utf16().count() as u32);
}

#[test]
fn highlight_offsets_account_for_surrogate_pairs_on_earlier_lines() {
    let dir = init_repo();
    let session = open(dir.path());

    // The emoji is two UTF-16 units and the newline is one, so the second
    // line must start at offset 3.
    let text = "\u{1F600}\nfn x() {}\n";
    let spans = session.highlight(text, "rs");

    let second_line_start = spans
        .iter()
        .map(|s| s.start_utf16)
        .filter(|&start| start >= 3)
        .min()
        .expect("expected spans on the second line");
    assert_eq!(second_line_start, 3);
}

// --------------------------------------------------------------- branches ---

#[test]
fn create_branch_without_checkout_keeps_head() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    session
        .create_branch("feature".into(), None, false)
        .unwrap();

    let branches = session.list_branches().unwrap();
    let feature = branches
        .iter()
        .find(|b| b.name == "feature")
        .expect("feature branch");
    assert!(!feature.is_head);
    assert!(branches.iter().any(|b| b.name == "main" && b.is_head));
}

#[test]
fn create_branch_with_checkout_and_start_point() {
    let dir = init_repo_with_commit();
    write(dir.path(), "a.txt", "second\n");
    run_git(dir.path(), &["commit", "-am", "second"]);
    let first = run_git(dir.path(), &["rev-parse", "HEAD~1"])
        .trim()
        .to_owned();

    let session = open(dir.path());
    session
        .create_branch("hotfix".into(), Some(first.clone()), true)
        .unwrap();

    let branches = session.list_branches().unwrap();
    let hotfix = branches
        .iter()
        .find(|b| b.name == "hotfix")
        .expect("hotfix branch");
    assert!(hotfix.is_head);
    assert_eq!(hotfix.target_oid_hex, first);
}

#[test]
fn create_branch_rejects_invalid_name() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session
        .create_branch("bad..name".into(), None, false)
        .is_err());
}

#[test]
fn checkout_unknown_branch_is_an_error_and_leaves_head_alone() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    assert!(session.checkout_branch("nope".into()).is_err());
    assert_eq!(session.status().unwrap().branch, "main");
}

#[test]
fn delete_branch_refuses_unmerged_work_unless_forced() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["checkout", "-b", "wip"]);
    write(dir.path(), "wip.txt", "work in progress\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "wip"]);
    run_git(dir.path(), &["checkout", "main"]);

    let session = open(dir.path());

    assert!(session.delete_branch("wip".into(), false).is_err());
    assert!(session
        .list_branches()
        .unwrap()
        .iter()
        .any(|b| b.name == "wip"));

    session.delete_branch("wip".into(), true).unwrap();
    assert!(!session
        .list_branches()
        .unwrap()
        .iter()
        .any(|b| b.name == "wip"));
}

#[test]
fn delete_current_branch_is_an_error() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session.delete_branch("main".into(), true).is_err());
}

// ---------------------------------------------------------------- commits ---

#[test]
fn commit_with_nothing_staged_is_an_error() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session.commit("empty".into()).is_err());
}

#[test]
fn commit_records_staged_changes_with_message() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    write(dir.path(), "a.txt", "alpha v2\n");
    session.stage("a.txt".into()).unwrap();
    session.commit("update alpha".into()).unwrap();

    assert!(session.status().unwrap().is_clean);
    let rows = session.get_commit_graph(0, 10, None).unwrap();
    assert_eq!(rows[0].summary, "update alpha");
}

#[test]
fn commit_detail_for_unknown_oid_is_an_error() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session
        .get_commit_detail("0000000000000000000000000000000000000001".into())
        .is_err());
}

// --------------------------------------------------------------- discard ---

#[test]
fn discard_file_restores_tracked_and_removes_untracked() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    write(dir.path(), "a.txt", "scribbled over\n");
    write(dir.path(), "scratch.txt", "throwaway\n");

    session.discard_file("a.txt".into()).unwrap();
    session.discard_file("scratch.txt".into()).unwrap();

    assert_eq!(
        fs::read_to_string(dir.path().join("a.txt")).unwrap(),
        "alpha\n"
    );
    assert!(!dir.path().join("scratch.txt").exists());
    assert!(session.status().unwrap().is_clean);
}

// ------------------------------------------------------------------ tags ---

#[test]
fn create_tag_rejects_blank_name() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session.create_tag("   ".into(), None, None, false).is_err());
    assert!(session.list_tags().unwrap().is_empty());
}

#[test]
fn annotated_tag_with_target_and_message() {
    let dir = init_repo_with_commit();
    write(dir.path(), "a.txt", "alpha v2\n");
    run_git(dir.path(), &["commit", "-am", "second"]);
    let first = run_git(dir.path(), &["rev-parse", "HEAD~1"])
        .trim()
        .to_owned();

    let session = open(dir.path());
    session
        .create_tag(
            "v1.0".into(),
            Some(first.clone()),
            Some("  release  ".into()),
            false,
        )
        .unwrap();

    let tags = session.list_tags().unwrap();
    let v1 = tags.iter().find(|t| t.name == "v1.0").expect("tag v1.0");
    assert_eq!(v1.target_oid_hex, first);
}

#[test]
fn delete_unknown_tag_is_an_error() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session.delete_tag("ghost".into(), false).is_err());
}

#[test]
fn push_without_any_remote_is_an_error() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session.push().is_err());
    assert!(session.push_tag("v9".into()).is_err());
}

// ---------------------------------------------------------------- stashes ---

#[test]
fn stash_push_with_message_and_untracked_files() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    write(dir.path(), "a.txt", "alpha stashed\n");
    write(dir.path(), "loose.txt", "untracked\n");

    session
        .stash_push(Some("  my work  ".into()), true)
        .unwrap();

    let stashes = session.list_stashes().unwrap();
    assert_eq!(stashes.len(), 1);
    assert_eq!(stashes[0].index, 0);
    assert!(
        stashes[0].message.contains("my work"),
        "message: {}",
        stashes[0].message
    );
    assert!(session.status().unwrap().is_clean);
    assert!(!dir.path().join("loose.txt").exists());
}

#[test]
fn stash_push_on_clean_tree_creates_no_stash() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    // git exits successfully with "No local changes to save" here.
    session.stash_push(None, false).unwrap();
    assert!(session.list_stashes().unwrap().is_empty());
}

#[test]
fn stash_apply_and_drop_with_invalid_index_are_errors() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    assert!(session.stash_apply(0).is_err());
    assert!(session.stash_pop(0).is_err());
    assert!(session.stash_drop(3).is_err());
}

#[test]
fn stash_apply_keeps_entry_until_it_is_dropped() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    write(dir.path(), "a.txt", "alpha stashed\n");
    session.stash_push(None, false).unwrap();

    session.stash_apply(0).unwrap();
    assert_eq!(session.list_stashes().unwrap().len(), 1);
    assert_eq!(
        fs::read_to_string(dir.path().join("a.txt")).unwrap(),
        "alpha stashed\n"
    );

    session.stash_drop(0).unwrap();
    assert!(session.list_stashes().unwrap().is_empty());
}

// ----------------------------------------------------------------- status ---

#[test]
fn status_reports_branch_and_clean_tree() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    let status = session.status().unwrap();
    assert_eq!(status.branch, "main");
    assert!(status.is_clean);
    assert!(status.files.is_empty());
    assert!(!status.is_merging);
    assert!(!status.has_conflicts);
}

#[test]
fn status_parses_renames_to_new_path() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["mv", "a.txt", "renamed.txt"]);

    let session = open(dir.path());
    let status = session.status().unwrap();

    let rename = status
        .staged_files
        .iter()
        .find(|f| f.path == "renamed.txt")
        .expect("rename should use the destination path");
    assert_eq!(rename.status, "R");
    assert!(status.files.iter().all(|p| p != "a.txt"));
}

#[test]
fn status_lists_same_file_as_staged_and_unstaged() {
    let dir = init_repo_with_commit();
    write(dir.path(), "a.txt", "staged version\n");

    let session = open(dir.path());
    session.stage("a.txt".into()).unwrap();
    write(dir.path(), "a.txt", "staged version plus more\n");

    let status = session.status().unwrap();
    assert!(status.staged_files.iter().any(|f| f.path == "a.txt"));
    assert!(status.unstaged_files.iter().any(|f| f.path == "a.txt"));
    assert!(!status.is_clean);
}

#[test]
fn untracked_file_with_glob_characters_is_not_mistaken_for_tracked_file() {
    // `notes[1].txt` is a glob that matches the tracked `notes1.txt`. Paths
    // must be treated literally, or the untracked file loses its synthetic diff.
    let dir = init_repo();
    write(dir.path(), "notes1.txt", "tracked\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "initial"]);
    write(dir.path(), "notes[1].txt", "untracked\nsecond\n");

    let session = open(dir.path());
    let rows = session
        .get_working_diff(Some("notes[1].txt".into()), false)
        .unwrap();

    assert_eq!(rows.first().map(|r| r.kind.as_str()), Some("hunk"));
    assert!(
        rows[0].text.contains("(untracked)"),
        "got: {}",
        rows[0].text
    );
    assert_eq!(rows.iter().filter(|r| r.kind == "addition").count(), 2);
}

// ----------------------------------------------------------------- ignore ---

#[test]
fn ignore_path_writes_gitignore_and_hides_file() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    write(dir.path(), "scratch.txt", "x\n");

    session.ignore_path("scratch.txt".into(), false).unwrap();
    // Idempotent: a second call must not duplicate the rule.
    session.ignore_path("scratch.txt".into(), false).unwrap();

    assert_eq!(
        fs::read_to_string(dir.path().join(".gitignore")).unwrap(),
        "/scratch.txt\n"
    );
    let status = session.status().unwrap();
    assert!(!status
        .unstaged_files
        .iter()
        .any(|f| f.path == "scratch.txt"));
}

#[test]
fn ignore_path_local_only_uses_info_exclude() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    fs::create_dir(dir.path().join("gen")).unwrap();
    write(&dir.path().join("gen"), "out.swift", "x\n");

    session.ignore_path("gen/".into(), true).unwrap();

    assert!(!dir.path().join(".gitignore").exists());
    let exclude = fs::read_to_string(dir.path().join(".git/info/exclude")).unwrap();
    assert!(exclude.lines().any(|l| l == "/gen/"));
    assert!(session.status().unwrap().unstaged_files.is_empty());
}

#[test]
fn ignore_path_appends_after_missing_trailing_newline() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    write(dir.path(), ".gitignore", "target");

    session.ignore_path("#weird*.txt".into(), false).unwrap();

    assert_eq!(
        fs::read_to_string(dir.path().join(".gitignore")).unwrap(),
        "target\n/\\#weird\\*.txt\n"
    );
}

// ------------------------------------------------------------------ fetch ---

#[test]
fn fetch_prunes_remote_branches_deleted_upstream() {
    let origin = init_repo_with_commit();
    run_git(origin.path(), &["branch", "feature"]);

    let clone_parent = tempfile::tempdir().unwrap();
    let clone_path = clone_parent.path().join("clone");
    run_git(
        clone_parent.path(),
        &[
            "clone",
            &origin.path().to_string_lossy(),
            &clone_path.to_string_lossy(),
        ],
    );
    let remote_refs = |dir: &Path| run_git(dir, &["branch", "-r"]);
    assert!(remote_refs(&clone_path).contains("origin/feature"));

    // Deleted on the "server" after the clone was made.
    run_git(origin.path(), &["branch", "-D", "feature"]);

    open(&clone_path).fetch().unwrap();

    assert!(!remote_refs(&clone_path).contains("origin/feature"));
}

// ---------------------------------------------------------------- remotes ---

#[test]
fn remote_management_roundtrip() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session.list_remotes().unwrap().is_empty());

    session
        .add_remote("origin".into(), "https://example.com/a.git".into())
        .unwrap();
    let remotes = session.list_remotes().unwrap();
    assert_eq!(remotes.len(), 1);
    assert_eq!(remotes[0].name, "origin");
    assert_eq!(remotes[0].fetch_url, "https://example.com/a.git");
    assert_eq!(remotes[0].push_url, "https://example.com/a.git");

    session
        .set_remote_url("origin".into(), "https://example.com/b.git".into())
        .unwrap();
    assert_eq!(
        session.list_remotes().unwrap()[0].fetch_url,
        "https://example.com/b.git"
    );

    session
        .rename_remote("origin".into(), "upstream".into())
        .unwrap();
    assert_eq!(session.list_remotes().unwrap()[0].name, "upstream");

    session.remove_remote("upstream".into()).unwrap();
    assert!(session.list_remotes().unwrap().is_empty());
}

#[test]
fn remote_management_rejects_bad_input() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session.add_remote("  ".into(), "x".into()).is_err());
    assert!(session.add_remote("--mirror".into(), "x".into()).is_err());
    assert!(session.add_remote("origin".into(), "-evil".into()).is_err());
    // Duplicate names are reported by git.
    session.add_remote("origin".into(), "u".into()).unwrap();
    assert!(session.add_remote("origin".into(), "u2".into()).is_err());
    assert!(session.remove_remote("nope".into()).is_err());
}

#[test]
fn fetch_remote_targets_only_the_named_remote() {
    let origin = init_repo_with_commit();
    let clone_parent = tempfile::tempdir().unwrap();
    let clone_path = clone_parent.path().join("clone");
    run_git(
        clone_parent.path(),
        &[
            "clone",
            &origin.path().to_string_lossy(),
            &clone_path.to_string_lossy(),
        ],
    );
    run_git(origin.path(), &["branch", "newbranch"]);
    open(&clone_path).fetch_remote("origin".into()).unwrap();
    assert!(run_git(&clone_path, &["branch", "-r"]).contains("origin/newbranch"));
}

#[test]
fn tags_are_listed_newest_created_first() {
    let dir = init_repo_with_commit();
    // A lightweight tag on the existing commit, then an annotated tag created later
    // whose name sorts *before* it alphabetically.
    run_git(dir.path(), &["tag", "zzz-light"]);
    let ok = Command::new("git")
        .args(["tag", "-a", "aaa-annotated", "-m", "later"])
        .current_dir(dir.path())
        .env("GIT_COMMITTER_NAME", "GitCraft Tester")
        .env("GIT_COMMITTER_EMAIL", "tester@gitcraft.local")
        .env("GIT_COMMITTER_DATE", "2099-01-01T00:00:00Z")
        .status()
        .unwrap()
        .success();
    assert!(ok);

    let tags = open(dir.path()).list_tags().unwrap();
    let names: Vec<_> = tags.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(names, ["aaa-annotated", "zzz-light"]);
    assert!(tags[0].created_timestamp > tags[1].created_timestamp);
}

#[test]
fn status_handles_non_ascii_and_special_filenames() {
    let dir = init_repo_with_commit();
    write(dir.path(), "café.txt", "x\n");
    write(dir.path(), "a b.txt", "x\n");
    write(dir.path(), "q\"uote.txt", "x\n");
    let session = open(dir.path());

    let status = session.status().unwrap();
    let mut paths: Vec<_> = status
        .unstaged_files
        .iter()
        .map(|f| f.path.as_str())
        .collect();
    paths.sort();
    assert_eq!(paths, ["a b.txt", "café.txt", "q\"uote.txt"]);

    // The reported path must round-trip through stage/unstage.
    session.stage("café.txt".into()).unwrap();
    let status = session.status().unwrap();
    assert_eq!(status.staged_files.len(), 1);
    assert_eq!(status.staged_files[0].path, "café.txt");
    session.unstage("café.txt".into()).unwrap();
    assert!(session.status().unwrap().staged_files.is_empty());
}

#[test]
fn status_reports_rename_with_new_path_only() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["mv", "a.txt", "renamed é.txt"]);
    let status = open(dir.path()).status().unwrap();
    assert_eq!(status.staged_files.len(), 1);
    assert_eq!(status.staged_files[0].path, "renamed é.txt");
    assert_eq!(status.staged_files[0].status, "R");
    assert!(status.unstaged_files.is_empty());
}

#[test]
fn commit_detail_and_diff_handle_non_ascii_paths() {
    let dir = init_repo_with_commit();
    write(dir.path(), "café.txt", "hello\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "add cafe"]);
    let head = run_git(dir.path(), &["rev-parse", "HEAD"])
        .trim()
        .to_owned();

    let session = open(dir.path());
    let detail = session.get_commit_detail(head.clone()).unwrap();
    assert_eq!(detail.files.len(), 1);
    assert_eq!(detail.files[0].path, "café.txt");

    let diff = session
        .get_commit_diff(head, Some("café.txt".into()))
        .unwrap();
    assert!(diff.iter().any(|r| r.text.contains("hello")));
}

#[test]
fn option_like_names_are_rejected() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    assert!(session
        .create_branch("--force".into(), None, false)
        .is_err());
    assert!(session
        .create_branch("ok".into(), Some("-x".into()), false)
        .is_err());
    assert!(session.create_tag("-d".into(), None, None, false).is_err());
    assert!(session.checkout_branch("--detach".into()).is_err());
    assert!(session.merge_branch("--abort".into()).is_err());
    assert!(session.delete_branch("-D".into(), true).is_err());
    assert!(session.delete_tag("-a".into(), false).is_err());
}

#[test]
fn checkout_prefers_the_branch_over_a_same_named_file() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["branch", "a.txt"]);
    write(dir.path(), "a.txt", "dirty\n");
    let session = open(dir.path());
    session.checkout_branch("a.txt".into()).unwrap();
    // The branch was checked out; the file's local edit was carried over, not reverted.
    assert_eq!(
        run_git(dir.path(), &["branch", "--show-current"]).trim(),
        "a.txt"
    );
    assert_eq!(
        fs::read_to_string(dir.path().join("a.txt")).unwrap(),
        "dirty\n"
    );
}

#[test]
fn unstage_does_not_stage_a_deletion_when_reset_fails() {
    let dir = init_repo_with_commit();
    write(dir.path(), "a.txt", "changed\n");
    run_git(dir.path(), &["add", "a.txt"]);
    let session = open(dir.path());
    // Make the index unwritable so `git reset` fails.
    fs::write(dir.path().join(".git/index.lock"), "").unwrap();
    assert!(session.unstage("a.txt".into()).is_err());
    fs::remove_file(dir.path().join(".git/index.lock")).unwrap();
    // The file must still be tracked and merely modified, not staged for deletion.
    let status = session.status().unwrap();
    assert!(status.staged_files.iter().all(|f| f.status != "D"));
    assert_eq!(status.staged_files.len(), 1);
}

/// A repo with one commit plus a bare "origin" it can push to.
fn repo_with_bare_origin() -> (tempfile::TempDir, tempfile::TempDir) {
    let dir = init_repo_with_commit();
    let origin = tempfile::tempdir().unwrap();
    run_git(origin.path(), &["init", "--bare", "-b", "main"]);
    run_git(
        dir.path(),
        &["remote", "add", "origin", origin.path().to_str().unwrap()],
    );
    (dir, origin)
}

#[test]
fn first_push_publishes_the_branch_and_sets_its_upstream() {
    let (dir, origin) = repo_with_bare_origin();
    let session = open(dir.path());
    session.push().unwrap();

    let upstream = run_git(
        dir.path(),
        &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
    );
    assert_eq!(upstream.trim(), "origin/main");
    assert!(!run_git(origin.path(), &["branch", "--list", "main"])
        .trim()
        .is_empty());

    // A second push (with an upstream now) still works.
    write(dir.path(), "a.txt", "more\n");
    run_git(dir.path(), &["commit", "-am", "more"]);
    session.push().unwrap();
}

#[test]
fn pull_of_diverged_branches_falls_back_to_a_merge() {
    let (dir, origin) = repo_with_bare_origin();
    let session = open(dir.path());
    session.push().unwrap();

    // Someone else pushes a commit touching a different file...
    let other = tempfile::tempdir().unwrap();
    run_git(
        other.path(),
        &["clone", "-q", origin.path().to_str().unwrap(), "."],
    );
    write(other.path(), "other.txt", "theirs\n");
    run_git(other.path(), &["add", "-A"]);
    run_git(other.path(), &["commit", "-m", "theirs"]);
    run_git(other.path(), &["push", "-q"]);

    // ...while we commit locally, so the branches diverge.
    write(dir.path(), "mine.txt", "mine\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "mine"]);

    session.pull(PullStrategy::GitConfig).unwrap();
    assert!(dir.path().join("other.txt").exists());
    assert!(dir.path().join("mine.txt").exists());
}

#[test]
fn checking_out_a_remote_branch_creates_a_tracking_branch() {
    let (dir, _origin) = repo_with_bare_origin();
    run_git(dir.path(), &["branch", "feature"]);
    run_git(dir.path(), &["push", "-q", "origin", "feature"]);
    run_git(dir.path(), &["branch", "-D", "feature"]);
    run_git(dir.path(), &["fetch", "-q", "origin"]);

    let session = open(dir.path());
    session.checkout_branch("origin/feature".into()).unwrap();
    assert_eq!(
        run_git(dir.path(), &["branch", "--show-current"]).trim(),
        "feature"
    );
}

#[test]
fn staging_treats_paths_as_literals_not_globs() {
    let dir = init_repo_with_commit();
    write(dir.path(), "a*.txt", "x\n");
    write(dir.path(), "ab.txt", "x\n");
    let session = open(dir.path());
    session.stage("a*.txt".into()).unwrap();
    let staged: Vec<_> = session
        .status()
        .unwrap()
        .staged_files
        .into_iter()
        .map(|f| f.path)
        .collect();
    assert_eq!(staged, ["a*.txt"]);
}

#[test]
fn status_branch_is_clean_for_empty_and_detached_repos() {
    let empty = init_repo();
    assert_eq!(open(empty.path()).status().unwrap().branch, "main");

    let dir = init_repo_with_commit();
    run_git(dir.path(), &["checkout", "-q", "--detach"]);
    assert_eq!(open(dir.path()).status().unwrap().branch, "HEAD (detached)");
}

#[test]
fn merge_state_is_detected_in_a_linked_worktree() {
    let dir = init_repo_with_commit();
    run_git(dir.path(), &["branch", "side"]);
    let wt_parent = tempfile::tempdir().unwrap();
    let wt = wt_parent.path().join("wt");
    run_git(
        dir.path(),
        &["worktree", "add", "-q", wt.to_str().unwrap(), "side"],
    );
    // Make main and side conflict.
    write(dir.path(), "a.txt", "main change\n");
    run_git(dir.path(), &["commit", "-qam", "main"]);
    write(&wt, "a.txt", "side change\n");
    run_git(&wt, &["commit", "-qam", "side"]);
    let merged = Command::new("git")
        .args(["merge", "main"])
        .current_dir(&wt)
        .output()
        .unwrap();
    assert!(!merged.status.success(), "expected a conflict");

    let status = open(&wt).status().unwrap();
    assert!(status.is_merging);
    assert!(status.has_conflicts);
}

/// Two clones of one origin whose `main` branches have diverged (each side has a
/// commit the other lacks, touching different files).
fn diverged_pair() -> (tempfile::TempDir, tempfile::TempDir, tempfile::TempDir) {
    let (dir, origin) = repo_with_bare_origin();
    open(dir.path()).push().unwrap();
    let other = tempfile::tempdir().unwrap();
    run_git(
        other.path(),
        &["clone", "-q", origin.path().to_str().unwrap(), "."],
    );
    write(other.path(), "theirs.txt", "theirs\n");
    run_git(other.path(), &["add", "-A"]);
    run_git(other.path(), &["commit", "-m", "theirs"]);
    run_git(other.path(), &["push", "-q"]);
    write(dir.path(), "mine.txt", "mine\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "mine"]);
    (dir, origin, other)
}

fn parent_count(dir: &Path) -> usize {
    run_git(dir, &["rev-list", "--parents", "-n", "1", "HEAD"])
        .split_whitespace()
        .count()
        - 1
}

#[test]
fn pull_with_rebase_keeps_history_linear() {
    let (dir, _o, _other) = diverged_pair();
    open(dir.path()).pull(PullStrategy::Rebase).unwrap();
    assert!(dir.path().join("theirs.txt").exists());
    assert_eq!(
        parent_count(dir.path()),
        1,
        "rebase must not create a merge commit"
    );
}

#[test]
fn pull_with_merge_creates_a_merge_commit() {
    let (dir, _o, _other) = diverged_pair();
    open(dir.path()).pull(PullStrategy::Merge).unwrap();
    assert_eq!(parent_count(dir.path()), 2);
}

#[test]
fn pull_fast_forward_only_refuses_diverged_branches() {
    let (dir, _o, _other) = diverged_pair();
    let before = run_git(dir.path(), &["rev-parse", "HEAD"]);
    assert!(open(dir.path())
        .pull(PullStrategy::FastForwardOnly)
        .is_err());
    assert_eq!(run_git(dir.path(), &["rev-parse", "HEAD"]), before);
}

#[test]
fn rebase_conflict_is_reported_and_can_be_aborted() {
    let (dir, origin) = repo_with_bare_origin();
    let session = open(dir.path());
    session.push().unwrap();
    let other = tempfile::tempdir().unwrap();
    run_git(
        other.path(),
        &["clone", "-q", origin.path().to_str().unwrap(), "."],
    );
    write(other.path(), "a.txt", "theirs\n");
    run_git(other.path(), &["commit", "-qam", "theirs"]);
    run_git(other.path(), &["push", "-q"]);
    write(dir.path(), "a.txt", "mine\n");
    run_git(dir.path(), &["commit", "-qam", "mine"]);
    let before = run_git(dir.path(), &["rev-parse", "HEAD"]);

    assert!(session.pull(PullStrategy::Rebase).is_err());
    let status = session.status().unwrap();
    assert!(status.is_rebasing);
    assert!(status.has_conflicts);

    session.abort_rebase().unwrap();
    let status = session.status().unwrap();
    assert!(!status.is_rebasing);
    assert_eq!(run_git(dir.path(), &["rev-parse", "HEAD"]), before);
}

#[test]
fn rebase_can_be_continued_after_resolving_conflicts() {
    let (dir, origin) = repo_with_bare_origin();
    let session = open(dir.path());
    session.push().unwrap();
    let other = tempfile::tempdir().unwrap();
    run_git(
        other.path(),
        &["clone", "-q", origin.path().to_str().unwrap(), "."],
    );
    write(other.path(), "a.txt", "theirs\n");
    run_git(other.path(), &["commit", "-qam", "theirs"]);
    run_git(other.path(), &["push", "-q"]);
    write(dir.path(), "a.txt", "mine\n");
    run_git(dir.path(), &["commit", "-qam", "mine"]);

    assert!(session.pull(PullStrategy::Rebase).is_err());
    write(dir.path(), "a.txt", "resolved\n");
    session.stage("a.txt".into()).unwrap();
    session.continue_rebase().unwrap();

    assert!(!session.status().unwrap().is_rebasing);
    assert_eq!(parent_count(dir.path()), 1);
    assert_eq!(
        fs::read_to_string(dir.path().join("a.txt")).unwrap(),
        "resolved\n"
    );
}
