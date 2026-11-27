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
    wait_for_watcher(&session);

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

#[test]
fn merge_commit_detail_survives_a_missing_parent_object() {
    let source = merged_repo();
    let clone = tempfile::tempdir().unwrap();
    run_git(
        clone.path(),
        &[
            "clone",
            "--depth",
            "1",
            &format!("file://{}", source.path().display()),
            ".",
        ],
    );
    let session = open(clone.path());
    let detail = session.get_commit_detail(head(clone.path())).unwrap();
    assert_eq!(detail.parent_oids.len(), 2);
}

#[test]
fn paged_graph_matches_one_big_fetch_and_follows_ref_changes() {
    let dir = init_repo_with_commit();
    let p = dir.path();
    for i in 0..120 {
        commit_file(p, "n.txt", &format!("{i}\n"), &format!("commit {i}"));
    }
    // The baseline comes from another session, so the paged session starts with an empty
    // cache and has to grow it page by page.
    let all = open(p).get_commit_graph(0, 500, None).unwrap();
    let session = open(p);
    let mut paged = Vec::new();
    for offset in (0..all.len() as u32).step_by(25) {
        paged.extend(session.get_commit_graph(offset, 25, None).unwrap());
    }
    let ids = |rows: &[gitcraft_core::CommitRow]| {
        rows.iter().map(|r| r.oid_hex.clone()).collect::<Vec<_>>()
    };
    assert_eq!(ids(&paged), ids(&all));
    // A new commit and a new branch show up on the next call despite the cache.
    commit_file(p, "n.txt", "new\n", "brand new");
    run_git(p, &["branch", "marker", "HEAD~3"]);
    let rows = session.get_commit_graph(0, 500, None).unwrap();
    // Commits made within one second tie on date, so look for it rather than expect row 0.
    assert!(rows.iter().any(|r| r.summary == "brand new"));
    assert!(rows
        .iter()
        .any(|r| r.refs.iter().any(|b| b.name == "marker")));

    // Searches are paged from their own walk, not the unfiltered rows.
    let hits = session
        .get_commit_graph(0, 5, Some("commit 11".into()))
        .unwrap();
    assert!(hits.iter().all(|r| r.summary.contains("commit 11")));
}

#[test]
fn graph_cache_notices_a_shallow_clone_being_deepened() {
    let source = init_repo_with_commit();
    for i in 0..5 {
        commit_file(source.path(), "n.txt", &format!("{i}\n"), &format!("c{i}"));
    }
    let clone = tempfile::tempdir().unwrap();
    run_git(
        clone.path(),
        &[
            "clone",
            "--depth",
            "1",
            &format!("file://{}", source.path().display()),
            ".",
        ],
    );
    let session = open(clone.path());
    assert_eq!(session.get_commit_graph(0, 100, None).unwrap().len(), 1);

    run_git(clone.path(), &["fetch", "--unshallow"]);
    assert_eq!(session.get_commit_graph(0, 100, None).unwrap().len(), 6);
}

#[test]
fn cached_lane_geometry_matches_full_walk_across_checkpoint_boundary() {
    use std::io::Write;
    use std::process::{Command, Stdio};

    let dir = tempfile::tempdir().unwrap();
    let p = dir.path();
    run_git(p, &["init", "-b", "main"]);

    // Build a 620-commit merge history via `git fast-import` so active lanes stay > 1
    // across the 512-commit checkpoint boundary.
    let mut child = Command::new("git")
        .args(["fast-import", "--quiet"])
        .current_dir(p)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();

    let mut mark = 0usize;
    let base_ts = 1_700_000_000i64;
    let write_commit = |w: &mut std::process::ChildStdin,
                        ref_name: &str,
                        from: Option<usize>,
                        merge: Option<usize>,
                        m: usize,
                        msg: &str| {
        let ts = base_ts + (m as i64) * 60;
        writeln!(w, "commit {ref_name}").unwrap();
        writeln!(w, "mark :{m}").unwrap();
        writeln!(w, "author Alice <alice@example.com> {ts} +0000").unwrap();
        writeln!(w, "committer Alice <alice@example.com> {ts} +0000").unwrap();
        writeln!(w, "data {}", msg.len()).unwrap();
        writeln!(w, "{msg}").unwrap();
        if let Some(f) = from {
            writeln!(w, "from :{f}").unwrap();
        }
        if let Some(mg) = merge {
            writeln!(w, "merge :{mg}").unwrap();
        }
        let body = format!("v{m}\n");
        writeln!(w, "M 100644 inline file.txt").unwrap();
        writeln!(w, "data {}", body.len()).unwrap();
        writeln!(w, "{body}").unwrap();
    };

    mark += 1;
    let mut main_tip = mark;
    write_commit(&mut stdin, "refs/heads/main", None, None, mark, "root");

    let mut feat_tip: Option<usize> = None;
    let mut feat_left = 0usize;
    while mark < 620 {
        if feat_tip.is_none() && mark.is_multiple_of(5) && mark < 610 {
            feat_tip = Some(main_tip);
            feat_left = 4;
        }
        if let Some(ft) = feat_tip {
            if feat_left > 0 {
                mark += 1;
                write_commit(
                    &mut stdin,
                    "refs/heads/_feat",
                    Some(ft),
                    None,
                    mark,
                    &format!("feat {mark}"),
                );
                feat_tip = Some(mark);
                feat_left -= 1;
                continue;
            } else {
                mark += 1;
                write_commit(
                    &mut stdin,
                    "refs/heads/main",
                    Some(main_tip),
                    Some(ft),
                    mark,
                    &format!("merge {mark}"),
                );
                main_tip = mark;
                feat_tip = None;
                continue;
            }
        }
        mark += 1;
        write_commit(
            &mut stdin,
            "refs/heads/main",
            Some(main_tip),
            None,
            mark,
            &format!("main {mark}"),
        );
        main_tip = mark;
    }
    writeln!(stdin, "reset refs/remotes/origin/main\nfrom :{main_tip}\n").unwrap();
    drop(stdin);
    assert!(child.wait().unwrap().success());
    run_git(p, &["update-ref", "-d", "refs/heads/_feat"]);

    for sort in [
        gitcraft_core::CommitSort::ByDate,
        gitcraft_core::CommitSort::Topological,
    ] {
        // Ground truth: fresh full walk in a separate session.
        let baseline = open(p);
        baseline.set_commit_sort(sort);
        let full = baseline.get_commit_graph(0, 1000, None).unwrap();
        assert!(
            full.len() > 550,
            "expected >550 commits, got {}",
            full.len()
        );

        // Warm the compact checkpoint cache past 512 commits, then serve cache-hit pages
        // before, at, and straddling the 512-commit checkpoint boundary.
        let cached = open(p);
        cached.set_commit_sort(sort);
        let _ = cached.get_commit_graph(0, 620, None).unwrap();

        for (offset, limit) in [(450u32, 50u32), (500, 40), (512, 50), (530, 60)] {
            let page = cached.get_commit_graph(offset, limit, None).unwrap();
            let expected = &full[offset as usize..(offset + limit) as usize];
            assert_eq!(page.len(), expected.len());
            for (i, (got, exp)) in page.iter().zip(expected.iter()).enumerate() {
                let row_idx = offset as usize + i;
                assert_eq!(got.oid_hex, exp.oid_hex, "{sort:?} row {row_idx} oid");
                assert_eq!(got.lane, exp.lane, "{sort:?} row {row_idx} lane");
                assert_eq!(got.color_idx, exp.color_idx, "{sort:?} row {row_idx} color");
                assert_eq!(
                    got.max_lanes, exp.max_lanes,
                    "{sort:?} row {row_idx} max_lanes"
                );
                assert_eq!(got.edges, exp.edges, "{sort:?} row {row_idx} edges");
                assert_eq!(got.refs, exp.refs, "{sort:?} row {row_idx} refs");
                assert_eq!(got.is_remote_only, exp.is_remote_only);
                assert_eq!(got.is_unpushed, exp.is_unpushed);
            }
        }
    }
}

#[test]
fn graph_state_token_changes_when_refs_move() {
    let dir = init_repo_with_commit();
    let p = dir.path();
    let session = open(p);

    let before = session.graph_state_token(false).unwrap();
    assert_eq!(before, session.graph_state_token(false).unwrap());

    commit_file(p, "a.txt", "1\n", "second");
    let after_commit = session.graph_state_token(false).unwrap();
    assert_ne!(before, after_commit);

    run_git(p, &["branch", "side"]);
    let after_branch = session.graph_state_token(false).unwrap();
    assert_ne!(after_commit, after_branch);
}
