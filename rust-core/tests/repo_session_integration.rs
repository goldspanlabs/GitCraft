use std::{
    fs,
    path::Path,
    process::Command,
    thread,
    time::{Duration, Instant},
};

use gitcraft_core::{RefKind, RepoSession};

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

fn configure_git_identity(dir: &Path) {
    run_git(dir, &["config", "user.name", "GitCraft Tester"]);
    run_git(dir, &["config", "user.email", "tester@gitcraft.local"]);
}

#[test]
fn rejects_non_git_directory_and_handles_empty_repo() {
    let non_repo = tempfile::tempdir().unwrap();
    assert!(RepoSession::new(non_repo.path().to_string_lossy().into_owned()).is_err());

    let empty_repo = tempfile::tempdir().unwrap();
    run_git(empty_repo.path(), &["init", "-b", "main"]);
    let session = RepoSession::new(empty_repo.path().to_string_lossy().into_owned()).unwrap();

    let rows = session.get_commit_graph(0, 100, None).unwrap();
    assert!(rows.is_empty());

    let branches = session.list_branches().unwrap();
    assert!(branches.is_empty());

    let tags = session.list_tags().unwrap();
    assert!(tags.is_empty());
}

#[test]
fn end_to_end_staging_diffs_commits_branches_and_discard() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    run_git(root, &["init", "-b", "main"]);
    configure_git_identity(root);

    let session = RepoSession::new(root.to_string_lossy().into_owned()).unwrap();

    // 1. Untracked file status & working diff preview with syntax spans
    fs::write(
        root.join("hello.rs"),
        "fn main() {\n    println!(\"hi\");\n}\n",
    )
    .unwrap();
    let status = session.status().unwrap();
    assert!(!status.is_clean);
    assert!(status.staged_files.is_empty());
    assert_eq!(status.unstaged_files.len(), 1);
    assert_eq!(status.unstaged_files[0].path, "hello.rs");
    assert_eq!(status.unstaged_files[0].status, "?");

    let untracked_diff = session
        .get_working_diff(Some("hello.rs".into()), false)
        .unwrap();
    assert!(untracked_diff
        .iter()
        .any(|r| r.kind == "addition" && r.text.contains("fn main()")));
    assert!(untracked_diff.iter().any(|r| !r.spans.is_empty()));

    // 2. Binary file guard
    fs::write(root.join("blob.bin"), [0u8, 1, 2, 3, 0, 255]).unwrap();
    let bin_diff = session
        .get_working_diff(Some("blob.bin".into()), false)
        .unwrap();
    assert_eq!(bin_diff.len(), 1);
    assert!(bin_diff[0].text.contains("Binary"));

    // Discard untracked binary file
    session.discard_file("blob.bin".into()).unwrap();
    assert!(!root.join("blob.bin").exists());

    // 3. Stage, unstage, stage_all, commit with multi-line message
    session.stage("hello.rs".into()).unwrap();
    let status = session.status().unwrap();
    assert_eq!(status.staged_files.len(), 1);
    assert!(status.unstaged_files.is_empty());

    let staged_diff = session
        .get_working_diff(Some("hello.rs".into()), true)
        .unwrap();
    assert!(staged_diff.iter().any(|r| r.kind == "addition"));

    session.unstage_all().unwrap();
    let status = session.status().unwrap();
    assert!(status.staged_files.is_empty());
    assert_eq!(status.unstaged_files.len(), 1);

    session.stage_all().unwrap();
    session
        .commit("Initial commit\n\nDetailed commit body line.".into())
        .unwrap();

    let status = session.status().unwrap();
    assert!(status.is_clean);

    // 4. Commit graph, detail, and commit diff
    let graph = session.get_commit_graph(0, 50, None).unwrap();
    assert_eq!(graph.len(), 1);
    let root_oid = graph[0].oid_hex.clone();
    assert_eq!(graph[0].summary, "Initial commit");

    let detail = session.get_commit_detail(root_oid.clone()).unwrap();
    assert_eq!(detail.summary, "Initial commit");
    assert_eq!(detail.body, "Detailed commit body line.");
    assert!(detail.parent_oids.is_empty());
    assert_eq!(detail.files.len(), 1);
    assert_eq!(detail.files[0].path, "hello.rs");

    let commit_diff = session
        .get_commit_diff(root_oid.clone(), Some("hello.rs".into()))
        .unwrap();
    assert!(commit_diff
        .iter()
        .any(|r| r.kind == "addition" && r.new_line == Some(1)));

    // 5. Modify tracked file and discard changes
    fs::write(root.join("hello.rs"), "fn main() {}\n").unwrap();
    let mod_status = session.status().unwrap();
    assert_eq!(mod_status.unstaged_files.len(), 1);
    assert_eq!(mod_status.unstaged_files[0].status, "M");
    session.discard_file("hello.rs".into()).unwrap();
    assert!(session.status().unwrap().is_clean);

    // 6. Branch creation, checkout, merge, detached HEAD, and deletion
    session
        .create_branch("feature/greet".into(), None, true)
        .unwrap();
    fs::write(root.join("greet.txt"), "hello world\n").unwrap();
    session.stage("greet.txt".into()).unwrap();
    session.commit("Add greet.txt".into()).unwrap();

    session.checkout_branch("main".into()).unwrap();
    session.merge_branch("feature/greet".into()).unwrap();
    assert!(root.join("greet.txt").exists());

    session
        .delete_branch("feature/greet".into(), false)
        .unwrap();
    let branches = session.list_branches().unwrap();
    assert_eq!(branches.len(), 1);
    assert_eq!(branches[0].name, "main");
    assert!(branches[0].is_head);

    // Detached HEAD badge verification
    session.checkout_branch(root_oid).unwrap();
    let graph_detached = session.get_commit_graph(0, 50, None).unwrap();
    assert!(graph_detached.iter().any(|c| {
        c.refs
            .iter()
            .any(|r| matches!(r.kind, RefKind::Head) && r.is_current)
    }));
}

#[test]
fn mock_bare_remote_fetch_pull_push_and_ahead_behind() {
    let base = tempfile::tempdir().unwrap();
    let remote_dir = base.path().join("remote.git");
    let clone_a = base.path().join("clone_a");
    let clone_b = base.path().join("clone_b");

    fs::create_dir_all(&remote_dir).unwrap();
    run_git(&remote_dir, &["init", "--bare", "-b", "main"]);

    run_git(
        base.path(),
        &[
            "clone",
            remote_dir.to_str().unwrap(),
            clone_a.to_str().unwrap(),
        ],
    );
    configure_git_identity(&clone_a);
    fs::write(clone_a.join("README.md"), "# GitCraft\n").unwrap();
    run_git(&clone_a, &["add", "."]);
    run_git(&clone_a, &["commit", "-m", "Initial"]);
    run_git(&clone_a, &["push", "-u", "origin", "main"]);

    run_git(
        base.path(),
        &[
            "clone",
            remote_dir.to_str().unwrap(),
            clone_b.to_str().unwrap(),
        ],
    );
    configure_git_identity(&clone_b);

    let session_a = RepoSession::new(clone_a.to_string_lossy().into_owned()).unwrap();
    let session_b = RepoSession::new(clone_b.to_string_lossy().into_owned()).unwrap();

    // Clone A creates a commit locally -> ahead == 1, then pushes
    fs::write(clone_a.join("a.txt"), "from a\n").unwrap();
    session_a.stage("a.txt".into()).unwrap();
    session_a.commit("Commit from A".into()).unwrap();

    let branches_a = session_a.list_branches().unwrap();
    let main_a = branches_a
        .iter()
        .find(|b| !b.is_remote && b.name == "main")
        .unwrap();
    assert_eq!(main_a.ahead, 1);
    assert_eq!(main_a.behind, 0);

    session_a.push().unwrap();
    let branches_a_after = session_a.list_branches().unwrap();
    let main_a_after = branches_a_after
        .iter()
        .find(|b| !b.is_remote && b.name == "main")
        .unwrap();
    assert_eq!(main_a_after.ahead, 0);

    // Clone B fetches -> behind == 1, then pulls -> behind == 0
    session_b.fetch().unwrap();
    let branches_b = session_b.list_branches().unwrap();
    let main_b = branches_b
        .iter()
        .find(|b| !b.is_remote && b.name == "main")
        .unwrap();
    assert_eq!(main_b.behind, 1);

    let graph_before_pull = session_b.get_commit_graph(0, 10, None).unwrap();
    assert!(graph_before_pull
        .iter()
        .any(|c| c.summary == "Commit from A" && c.is_remote_only));
    assert!(graph_before_pull
        .iter()
        .any(|c| c.summary == "Initial" && !c.is_remote_only));

    session_b.pull().unwrap();
    assert!(clone_b.join("a.txt").exists());
    let graph_after_pull = session_b.get_commit_graph(0, 10, None).unwrap();
    assert!(graph_after_pull.iter().all(|c| !c.is_remote_only));

    let branches_b_after = session_b.list_branches().unwrap();
    let main_b_after = branches_b_after
        .iter()
        .find(|b| !b.is_remote && b.name == "main")
        .unwrap();
    assert_eq!(main_b_after.behind, 0);
}

#[test]
fn file_watcher_sets_dirty_flag_on_worktree_change() {
    let dir = tempfile::tempdir().unwrap();
    run_git(dir.path(), &["init", "-b", "main"]);
    let session = RepoSession::new(dir.path().to_string_lossy().into_owned()).unwrap();

    // Drain any initial events while watcher settles
    thread::sleep(Duration::from_millis(600));
    let _ = session.take_dirty();

    fs::write(dir.path().join("watched.txt"), "change\n").unwrap();

    let deadline = Instant::now() + Duration::from_secs(4);
    let mut observed = false;
    while Instant::now() < deadline {
        if session.take_dirty() {
            observed = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    assert!(
        observed,
        "expected watcher to mark session dirty on file write"
    );
}

#[test]
fn stash_push_list_apply_pop_and_drop() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    run_git(root, &["init", "-b", "main"]);
    configure_git_identity(root);

    fs::write(root.join("base.txt"), "v1\n").unwrap();
    run_git(root, &["add", "."]);
    run_git(root, &["commit", "-m", "Base commit"]);

    let session = RepoSession::new(root.to_string_lossy().into_owned()).unwrap();
    assert!(session.list_stashes().unwrap().is_empty());

    // Modify tracked file + add untracked file, then stash with message
    fs::write(root.join("base.txt"), "v2\n").unwrap();
    fs::write(root.join("wip.txt"), "untracked wip\n").unwrap();

    session
        .stash_push(Some("WIP: work in progress".into()), true)
        .unwrap();
    assert!(session.status().unwrap().is_clean);
    assert!(!root.join("wip.txt").exists());

    let stashes = session.list_stashes().unwrap();
    assert_eq!(stashes.len(), 1);
    assert_eq!(stashes[0].index, 0);
    assert_eq!(stashes[0].name, "stash@{0}");
    assert!(stashes[0].message.contains("WIP: work in progress"));

    // Apply keeps stash in list
    session.stash_apply(0).unwrap();
    assert!(!session.status().unwrap().is_clean);
    assert!(root.join("wip.txt").exists());
    assert_eq!(session.list_stashes().unwrap().len(), 1);

    // Clean working tree and pop stash -> restores changes and removes stash
    session.discard_file("base.txt".into()).unwrap();
    session.discard_file("wip.txt".into()).unwrap();
    assert!(session.status().unwrap().is_clean);

    session.stash_pop(0).unwrap();
    assert!(!session.status().unwrap().is_clean);
    assert!(session.list_stashes().unwrap().is_empty());

    // Stash again and drop
    session.stash_push(None, true).unwrap();
    assert_eq!(session.list_stashes().unwrap().len(), 1);
    session.stash_drop(0).unwrap();
    assert!(session.list_stashes().unwrap().is_empty());
}

#[test]
fn create_push_and_delete_tags_with_remote() {
    let base = tempfile::tempdir().unwrap();
    let remote_dir = base.path().join("remote.git");
    let local_dir = base.path().join("local");

    fs::create_dir_all(&remote_dir).unwrap();
    run_git(&remote_dir, &["init", "--bare", "-b", "main"]);

    run_git(
        base.path(),
        &[
            "clone",
            remote_dir.to_str().unwrap(),
            local_dir.to_str().unwrap(),
        ],
    );
    configure_git_identity(&local_dir);
    fs::write(local_dir.join("file.txt"), "hello\n").unwrap();
    run_git(&local_dir, &["add", "."]);
    run_git(&local_dir, &["commit", "-m", "Initial"]);
    run_git(&local_dir, &["push", "-u", "origin", "main"]);

    let session = RepoSession::new(local_dir.to_string_lossy().into_owned()).unwrap();

    // Create lightweight tag locally without pushing, then push explicitly
    session
        .create_tag("v0.1.0".into(), None, None, false)
        .unwrap();
    assert_eq!(session.list_tags().unwrap().len(), 1);
    assert!(!run_git(&remote_dir, &["tag"]).contains("v0.1.0"));

    session.push_tag("v0.1.0".into()).unwrap();
    assert!(run_git(&remote_dir, &["tag"]).contains("v0.1.0"));

    // Create annotated tag and push immediately
    session
        .create_tag("v0.2.0".into(), None, Some("Release v0.2.0".into()), true)
        .unwrap();
    assert_eq!(session.list_tags().unwrap().len(), 2);
    assert!(run_git(&remote_dir, &["tag"]).contains("v0.2.0"));

    // Delete v0.1.0 locally only (remains on remote)
    session.delete_tag("v0.1.0".into(), false).unwrap();
    assert_eq!(session.list_tags().unwrap().len(), 1);
    assert!(run_git(&remote_dir, &["tag"]).contains("v0.1.0"));

    // Delete v0.2.0 both locally and remotely
    session.delete_tag("v0.2.0".into(), true).unwrap();
    assert!(session.list_tags().unwrap().is_empty());
    assert!(!run_git(&remote_dir, &["tag"]).contains("v0.2.0"));
}

#[test]
fn merge_conflict_detection_and_abort_merge() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    run_git(root, &["init", "-b", "main"]);
    configure_git_identity(root);

    fs::write(root.join("conflict.txt"), "base\n").unwrap();
    run_git(root, &["add", "."]);
    run_git(root, &["commit", "-m", "Base"]);

    run_git(root, &["checkout", "-b", "side"]);
    fs::write(root.join("conflict.txt"), "side change\n").unwrap();
    run_git(root, &["add", "."]);
    run_git(root, &["commit", "-m", "Side"]);

    run_git(root, &["checkout", "main"]);
    fs::write(root.join("conflict.txt"), "main change\n").unwrap();
    run_git(root, &["add", "."]);
    run_git(root, &["commit", "-m", "Main"]);

    let session = RepoSession::new(root.to_string_lossy().into_owned()).unwrap();
    assert!(!session.status().unwrap().is_merging);

    // Merging side into main triggers a conflict
    assert!(session.merge_branch("side".into()).is_err());

    let status = session.status().unwrap();
    assert!(status.is_merging);
    assert!(status.has_conflicts);

    // Abort merge restores clean state
    session.abort_merge().unwrap();
    let after = session.status().unwrap();
    assert!(!after.is_merging);
    assert!(!after.has_conflicts);
    assert!(after.is_clean);
}

#[test]
fn list_branches_flags_branches_authored_by_configured_user() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    run_git(root, &["init", "-b", "main"]);
    configure_git_identity(root);

    // Commit on main as the configured user.
    fs::write(root.join("a.txt"), "a\n").unwrap();
    run_git(root, &["add", "a.txt"]);
    run_git(root, &["commit", "-m", "mine"]);

    // A branch whose tip is authored by someone else.
    run_git(root, &["checkout", "-b", "theirs"]);
    fs::write(root.join("b.txt"), "b\n").unwrap();
    run_git(root, &["add", "b.txt"]);
    let out = Command::new("git")
        .args(["commit", "-m", "theirs"])
        .current_dir(root)
        .env("GIT_AUTHOR_NAME", "Someone Else")
        .env("GIT_AUTHOR_EMAIL", "other@example.com")
        .env("GIT_COMMITTER_NAME", "Someone Else")
        .env("GIT_COMMITTER_EMAIL", "other@example.com")
        .output()
        .unwrap();
    assert!(out.status.success());
    run_git(root, &["checkout", "main"]);

    let session = RepoSession::new(root.to_string_lossy().into_owned()).unwrap();
    let branches = session.list_branches().unwrap();
    let mine = branches.iter().find(|b| b.name == "main").unwrap();
    let theirs = branches.iter().find(|b| b.name == "theirs").unwrap();
    assert!(mine.is_mine);
    assert!(!theirs.is_mine);
}
