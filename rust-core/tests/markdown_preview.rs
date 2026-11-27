//! End-to-end checks of the Markdown preview data path: file versions read from a real
//! repository, rendered into a block-level diff.

mod common;

use common::{commit_file, init_repo, init_repo_with_commit, open, rev, run_git, write};
use gitcraft_core::{render_markdown_diff_html, FileContentPair, GitCraftError};

const OVER_LIMIT: usize = 1024 * 1024 + 1;

fn err_text(err: GitCraftError) -> String {
    err.to_string()
}

fn render(pair: &FileContentPair) -> String {
    render_markdown_diff_html(pair.old_content.clone(), pair.new_content.clone())
}

#[test]
fn oversized_files_error_for_working_staged_and_commit_sources() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    let big = "x".repeat(OVER_LIMIT);

    write(dir.path(), "big.md", &big);
    let working = err_text(
        session
            .get_working_file_versions("big.md".into(), false)
            .unwrap_err(),
    );
    assert!(working.contains("too large"), "{working}");

    run_git(dir.path(), &["add", "big.md"]);
    let staged = err_text(
        session
            .get_working_file_versions("big.md".into(), true)
            .unwrap_err(),
    );
    assert!(staged.contains("too large"), "{staged}");

    run_git(dir.path(), &["commit", "-m", "big"]);
    let oid = rev(dir.path(), "HEAD");
    let committed = err_text(
        session
            .get_commit_file_versions(oid, "big.md".into())
            .unwrap_err(),
    );
    assert!(committed.contains("too large"), "{committed}");
}

#[test]
fn file_at_the_size_limit_is_still_previewable() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    write(dir.path(), "edge.md", &"y".repeat(OVER_LIMIT - 1));
    let pair = session
        .get_working_file_versions("edge.md".into(), false)
        .unwrap();
    assert_eq!(pair.new_content.unwrap().len(), OVER_LIMIT - 1);
}

#[test]
fn binary_files_error_for_working_and_commit_sources() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    std::fs::write(dir.path().join("bin.md"), b"# hi\0there").unwrap();

    let working = err_text(
        session
            .get_working_file_versions("bin.md".into(), false)
            .unwrap_err(),
    );
    assert!(working.contains("Binary"), "{working}");

    run_git(dir.path(), &["add", "bin.md"]);
    run_git(dir.path(), &["commit", "-m", "bin"]);
    let oid = rev(dir.path(), "HEAD");
    let committed = err_text(
        session
            .get_commit_file_versions(oid, "bin.md".into())
            .unwrap_err(),
    );
    assert!(committed.contains("Binary"), "{committed}");
}

#[test]
fn added_and_deleted_files_have_one_missing_side() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());

    let add_oid = commit_file(dir.path(), "doc.md", "# Doc\n", "add");
    let added = session
        .get_commit_file_versions(add_oid, "doc.md".into())
        .unwrap();
    assert_eq!(added.old_content, None);
    assert!(added.new_content.is_some());

    run_git(dir.path(), &["rm", "doc.md"]);
    run_git(dir.path(), &["commit", "-m", "rm"]);
    let rm_oid = rev(dir.path(), "HEAD");
    let deleted = session
        .get_commit_file_versions(rm_oid, "doc.md".into())
        .unwrap();
    assert!(deleted.old_content.is_some());
    assert_eq!(deleted.new_content, None);

    let missing = session
        .get_working_file_versions("never-existed.md".into(), false)
        .unwrap();
    assert_eq!(missing.old_content, None);
    assert_eq!(missing.new_content, None);
}

#[test]
fn missing_objects_are_errors_not_absent_files() {
    let dir = init_repo_with_commit();
    commit_file(dir.path(), "doc.md", "# Old\n", "add");
    let edit_oid = commit_file(dir.path(), "doc.md", "# New\n", "edit");
    let blob = run_git(dir.path(), &["rev-parse", "HEAD~1:doc.md"])
        .trim()
        .to_owned();
    // Commits write loose objects, so deleting the file removes the blob from the repository.
    let loose = dir
        .path()
        .join(".git/objects")
        .join(&blob[..2])
        .join(&blob[2..]);
    assert!(loose.exists());
    std::fs::remove_file(loose).unwrap();

    let session = open(dir.path());
    assert!(session
        .get_commit_file_versions(edit_oid, "doc.md".into())
        .is_err());
}

#[test]
fn staged_preview_before_the_first_commit_has_no_old_side() {
    let dir = init_repo();
    let session = open(dir.path());
    write(dir.path(), "new.md", "# First\n");
    run_git(dir.path(), &["add", "new.md"]);
    let pair = session
        .get_working_file_versions("new.md".into(), true)
        .unwrap();
    assert_eq!(pair.old_content, None);
    assert_eq!(pair.new_content.as_deref(), Some("# First\n"));
}

#[test]
fn empty_and_crlf_files_render() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    write(dir.path(), "empty.md", "");
    write(dir.path(), "crlf.md", "# Title\r\n\r\nBody\r\n");
    let empty = session
        .get_working_file_versions("empty.md".into(), false)
        .unwrap();
    assert_eq!(empty.new_content.as_deref(), Some(""));
    let crlf = session
        .get_working_file_versions("crlf.md".into(), false)
        .unwrap();
    assert!(render(&crlf).contains("<h1 id=\"title\">Title</h1>"));
}

#[test]
fn unclosed_html_only_marks_the_changed_block() {
    let dir = init_repo_with_commit();
    let session = open(dir.path());
    let head = "<p align=center>\n\nIntro <b>bold\n\n";
    commit_file(
        dir.path(),
        "readme.md",
        &format!("{head}Keep.\n\nChange me.\n"),
        "add",
    );
    write(
        dir.path(),
        "readme.md",
        &format!("{head}Keep.\n\nChanged.\n"),
    );
    let pair = session
        .get_working_file_versions("readme.md".into(), false)
        .unwrap();
    let html = render(&pair);
    assert_eq!(html.matches("diff-deleted").count(), 1, "{html}");
    assert_eq!(html.matches("diff-added").count(), 1, "{html}");
    assert!(html.contains("Change me."));
    assert!(html.contains("Changed."));
}
