mod common;

use std::{
    thread,
    time::{Duration, Instant},
};

use common::*;

fn head(dir: &std::path::Path) -> String {
    run_git(dir, &["rev-parse", "HEAD"]).trim().to_owned()
}

fn merged_repo() -> tempfile::TempDir {
    let dir = init_repo_with_commit();
    let p = dir.path();
    run_git(p, &["checkout", "-b", "feature"]);
    write(p, "f.txt", "feature\n");
    run_git(p, &["add", "-A"]);
    run_git(p, &["commit", "-m", "feature work"]);
    run_git(p, &["checkout", "main"]);
    write(p, "m.txt", "main\n");
    run_git(p, &["add", "-A"]);
    run_git(p, &["commit", "-m", "main work"]);
    run_git(p, &["merge", "--no-ff", "feature", "-m", "merge feature"]);
    dir
}

#[test]
fn merge_commit_lists_files_and_diff_against_first_parent() {
    let dir = merged_repo();
    let session = open(dir.path());
    let oid = head(dir.path());

    let detail = session.get_commit_detail(oid.clone()).unwrap();
    let paths: Vec<_> = detail.files.iter().map(|f| f.path.as_str()).collect();
    assert_eq!(paths, vec!["f.txt"]);

    let rows = session.get_commit_diff(oid.clone(), None).unwrap();
    assert!(rows.iter().any(|r| r.text == "+feature"));
    assert!(!rows.iter().any(|r| r.text == "+main"));

    let one = session.get_commit_diff(oid, Some("f.txt".into())).unwrap();
    assert!(one.iter().any(|r| r.text == "+feature"));
}

#[test]
fn commit_diff_path_is_literal_not_a_glob() {
    let dir = init_repo();
    write(dir.path(), "a*.txt", "star\n");
    write(dir.path(), "ab.txt", "other\n");
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "two files"]);
    let session = open(dir.path());

    let rows = session
        .get_commit_diff(head(dir.path()), Some("a*.txt".into()))
        .unwrap();
    assert!(rows.iter().any(|r| r.text == "+star"));
    assert!(!rows.iter().any(|r| r.text == "+other"));
}

#[test]
fn deleted_sql_comment_keeps_line_numbers_in_working_diff() {
    let dir = init_repo();
    write(
        dir.path(),
        "q.sql",
        "select 1;\n-- old comment\nselect 2;\nselect 3;\n",
    );
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-m", "sql"]);
    write(dir.path(), "q.sql", "select 1;\nselect 2;\nselect 3;\n");
    let session = open(dir.path());

    let rows = session
        .get_working_diff(Some("q.sql".into()), false)
        .unwrap();
    let gone = rows.iter().find(|r| r.text == "--- old comment").unwrap();
    assert_eq!(gone.kind, "deletion");
    assert_eq!(gone.old_line, Some(2));
    let last = rows.last().unwrap();
    assert_eq!((last.old_line, last.new_line), (Some(4), Some(3)));
}

#[test]
fn discard_file_reports_failure_for_a_conflicted_file() {
    let dir = init_repo_with_commit();
    let p = dir.path();
    run_git(p, &["checkout", "-b", "other"]);
    write(p, "a.txt", "other side\n");
    run_git(p, &["commit", "-am", "other"]);
    run_git(p, &["checkout", "main"]);
    write(p, "a.txt", "main side\n");
    run_git(p, &["commit", "-am", "main"]);
    let merge = std::process::Command::new("git")
        .args(["merge", "other"])
        .current_dir(p)
        .output()
        .unwrap();
    assert!(!merge.status.success());
    let session = open(p);

    assert!(session.discard_file("a.txt".into()).is_err());
    assert!(std::fs::read_to_string(p.join("a.txt"))
        .unwrap()
        .contains("<<<<<<<"));
}

#[test]
fn editing_a_lock_file_in_the_working_tree_marks_status_dirty() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    thread::sleep(Duration::from_millis(1500));
    let _ = session.take_dirty();

    write(dir.path(), "Cargo.lock", "# changed\n");
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = false;
    while Instant::now() < deadline {
        if session.take_dirty() {
            seen = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    assert!(seen, "Cargo.lock edit never marked the session dirty");
}
