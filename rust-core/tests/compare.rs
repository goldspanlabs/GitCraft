mod common;

use std::collections::BTreeMap;

use common::{commit_file, head, init_repo_with_commit, open, run_git, write};
use gitcraft_core::CompareSummary;

fn files(summary: &CompareSummary) -> BTreeMap<&str, (&str, Option<&str>)> {
    summary
        .files
        .iter()
        .map(|file| {
            (
                file.path.as_str(),
                (file.status.as_str(), file.old_path.as_deref()),
            )
        })
        .collect()
}

#[test]
fn branch_compare_uses_fork_point_and_pins_file_versions() {
    let repo = init_repo_with_commit();
    let dir = repo.path();
    let fork = commit_file(dir, "modified.txt", "before\n", "Add a file to modify");
    run_git(dir, &["switch", "-c", "topic"]);
    run_git(dir, &["mv", "a.txt", "new α [name].txt"]);
    run_git(dir, &["rm", "b.txt"]);
    write(dir, "modified.txt", "after\n");
    let topic = commit_file(dir, "add.txt", "new\n", "Change four files");
    run_git(dir, &["switch", "main"]);
    let main = commit_file(dir, "main-only.txt", "main\n", "Advance main");

    let session = open(dir);
    let result = session
        .compare_branches("HEAD".into(), "refs/heads/topic".into())
        .unwrap();
    assert_eq!(result.merge_base_oid, fork);
    assert_eq!(result.base_oid, main);
    assert_eq!(result.head_oid, topic);
    assert_eq!((result.ahead, result.behind), (1, 1));
    assert_eq!(
        files(&result),
        BTreeMap::from([
            ("add.txt", ("A", None)),
            ("b.txt", ("D", None)),
            ("modified.txt", ("M", None)),
            ("new α [name].txt", ("R", Some("a.txt"))),
        ])
    );

    // The summary and both per-file APIs retain the original object IDs after the ref moves.
    run_git(dir, &["branch", "-f", "topic", "main"]);
    let rename = result.files.iter().find(|file| file.status == "R").unwrap();
    let rename_diff = session
        .get_compare_diff(fork.clone(), topic.clone(), rename.clone())
        .unwrap();
    assert!(rename_diff
        .iter()
        .any(|row| row.text == "rename to new α [name].txt"));
    let pair = session
        .get_compare_file_contents(fork.clone(), topic.clone(), rename.clone())
        .unwrap();
    assert_eq!(pair.old_content.as_deref(), Some("alpha\n"));
    assert_eq!(pair.new_content, pair.old_content);

    let modified = result.files.iter().find(|file| file.status == "M").unwrap();
    let rows = session
        .get_compare_diff(fork, topic, modified.clone())
        .unwrap();
    assert!(rows
        .iter()
        .any(|row| row.kind == "deletion" && row.text == "-before"));
    assert!(rows
        .iter()
        .any(|row| row.kind == "addition" && row.text == "+after"));
}

#[test]
fn merge_from_main_advances_the_base() {
    let repo = init_repo_with_commit();
    let dir = repo.path();
    run_git(dir, &["switch", "-c", "topic"]);
    commit_file(dir, "topic.txt", "topic\n", "Add topic file");
    run_git(dir, &["switch", "main"]);
    let merged = commit_file(dir, "main.txt", "main\n", "Advance main");
    run_git(dir, &["switch", "topic"]);
    run_git(dir, &["merge", "--no-edit", "main"]);
    run_git(dir, &["switch", "main"]);
    commit_file(dir, "main-later.txt", "later\n", "Advance main again");

    let result = open(dir)
        .compare_branches("HEAD".into(), "topic".into())
        .unwrap();
    assert_eq!(result.merge_base_oid, merged);
    assert_eq!(files(&result), BTreeMap::from([("topic.txt", ("A", None))]));
    assert_eq!((result.ahead, result.behind), (2, 1));
}

#[test]
fn working_tree_combines_committed_staged_unstaged_and_untracked_changes() {
    let repo = init_repo_with_commit();
    let dir = repo.path();
    let fork = head(dir);
    run_git(dir, &["switch", "-c", "topic"]);
    commit_file(dir, "committed.txt", "committed\n", "Advance topic");
    write(dir, "a.txt", "staged\n");
    run_git(dir, &["add", "a.txt"]);
    write(dir, "b.txt", "unstaged\n");
    write(dir, "untracked β [name].txt", "untracked\n");
    write(dir, ".git/info/exclude", "ignored.txt\n");
    write(dir, "ignored.txt", "ignored\n");

    let session = open(dir);
    let before = run_git(dir, &["status", "--porcelain", "-z"]);
    let result = session.compare_working_tree("main".into()).unwrap();
    assert_eq!(result.merge_base_oid, fork);
    assert_eq!((result.ahead, result.behind), (1, 0));
    assert_eq!(
        files(&result),
        BTreeMap::from([
            ("a.txt", ("M", None)),
            ("b.txt", ("M", None)),
            ("committed.txt", ("A", None)),
            ("untracked β [name].txt", ("A", None)),
        ])
    );
    for (file, text) in result
        .files
        .iter()
        .zip(["staged", "unstaged", "committed", "untracked"])
    {
        let rows = session
            .get_compare_diff(fork.clone(), result.head_oid.clone(), file.clone())
            .unwrap();
        assert!(rows
            .iter()
            .any(|row| row.kind == "addition" && row.text == format!("+{text}")));
        let pair = session
            .get_compare_file_contents(fork.clone(), result.head_oid.clone(), file.clone())
            .unwrap();
        assert_eq!(pair.new_content, Some(format!("{text}\n")));
    }
    let current = session
        .compare_working_tree("refs/heads/topic".into())
        .unwrap();
    assert_eq!(current.merge_base_oid, head(dir));
    assert_eq!((current.ahead, current.behind), (0, 0));
    assert!(!files(&current).contains_key("committed.txt"));
    assert_eq!(current.files.len(), 3);
    assert_eq!(run_git(dir, &["status", "--porcelain", "-z"]), before);
}

#[test]
fn clean_working_tree_can_be_compared_to_current_branch() {
    let repo = init_repo_with_commit();
    let session = open(repo.path());
    assert_eq!(
        session.compare_default_branch().as_deref(),
        Some("refs/heads/main")
    );
    let result = session.compare_working_tree("main".into()).unwrap();
    assert_eq!(result.merge_base_oid, head(repo.path()));
    assert!(result.files.is_empty());
}

#[test]
fn compares_only_related_branches_and_reports_unresolvable_refs() {
    let repo = init_repo_with_commit();
    let dir = repo.path();
    let main = head(dir);
    run_git(dir, &["switch", "--orphan", "other"]);
    let other = commit_file(dir, "other.txt", "other\n", "Unrelated root");
    run_git(dir, &["switch", "main"]);
    let session = open(dir);
    assert_eq!(
        session
            .comparable_branch_tips(vec![main.clone(), other])
            .unwrap(),
        vec![main]
    );

    let branch_error = session
        .compare_branches("HEAD".into(), "other".into())
        .unwrap_err();
    assert_eq!(
        branch_error.to_string(),
        "No merge base (unrelated histories)."
    );
    let worktree_error = session.compare_working_tree("other".into()).unwrap_err();
    assert_eq!(
        worktree_error.to_string(),
        "No merge base (unrelated histories)."
    );
    let unknown = session.compare_working_tree("missing".into()).unwrap_err();
    assert_eq!(unknown.to_string(), "Unknown ref: missing");

    run_git(dir, &["switch", "--detach", "main"]);
    let detached = session
        .compare_branches("HEAD".into(), "other".into())
        .unwrap_err();
    assert_eq!(detached.to_string(), "HEAD is detached.");
    assert!(session
        .compare_working_tree("main".into())
        .unwrap()
        .files
        .is_empty());
}

#[test]
fn a_recreated_tracked_file_is_compared_using_its_working_copy() {
    let repo = init_repo_with_commit();
    let dir = repo.path();
    run_git(dir, &["rm", "--cached", "a.txt", "b.txt"]);
    write(dir, "a.txt", "recreated\n");
    // b.txt is still present and identical to the merge base.
    let session = open(dir);
    let before = run_git(dir, &["status", "--porcelain", "-z"]);
    let summary = session.compare_working_tree("main".into()).unwrap();
    assert_eq!(files(&summary), BTreeMap::from([("a.txt", ("M", None))]));
    let rows = session
        .get_compare_diff(
            summary.merge_base_oid,
            summary.head_oid,
            summary.files[0].clone(),
        )
        .unwrap();
    assert!(rows.iter().any(|row| row.text == "-alpha"));
    assert!(rows.iter().any(|row| row.text == "+recreated"));
    assert_eq!(run_git(dir, &["status", "--porcelain", "-z"]), before);
}

#[test]
fn ignored_file_left_on_disk_is_still_deleted_in_patch_and_preview() {
    let repo = init_repo_with_commit();
    let dir = repo.path();
    commit_file(dir, "guide.md", "# Original\n", "Track guide");
    run_git(dir, &["rm", "--cached", "guide.md"]);
    write(dir, ".git/info/exclude", "guide.md\n");
    write(dir, "guide.md", "# Ignored\n");

    let session = open(dir);
    let result = session.compare_working_tree("main".into()).unwrap();
    assert_eq!(files(&result), BTreeMap::from([("guide.md", ("D", None))]));
    let file = result.files[0].clone();
    let rows = session
        .get_compare_diff(
            result.merge_base_oid.clone(),
            result.head_oid.clone(),
            file.clone(),
        )
        .unwrap();
    assert!(rows
        .iter()
        .any(|row| row.kind == "deletion" && row.text == "-# Original"));
    assert!(!rows.iter().any(|row| row.kind == "addition"));
    let pair = session
        .get_compare_file_contents(result.merge_base_oid, result.head_oid, file)
        .unwrap();
    assert_eq!(pair.old_content.as_deref(), Some("# Original\n"));
    assert_eq!(pair.new_content, None);
}

#[test]
fn moved_markdown_uses_old_directory_only_for_removed_relative_assets() {
    let html = gitcraft_core::render_compare_markdown_html(
        Some("![old](../diagram.png)\n\n![root](/icon.png)\n".into()),
        Some("![new](diagram.png)\n".into()),
        Some("docs/old #β/guide.md".into()),
    );
    assert!(html.contains(r#"src="/docs/old%20%23%CE%B2/../diagram.png?diff-side=old""#));
    assert!(html.contains(r#"src="/icon.png?diff-side=old""#));
    assert!(html.contains(r#"src="diagram.png""#));
}
