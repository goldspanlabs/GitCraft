mod common;

use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Stdio},
    time::Instant,
};

use common::run_git;
use gitcraft_core::{CommitSort, RepoSession};

fn generate_large_repo_via_fast_import(dir: &Path, num_commits: usize) {
    run_git(dir, &["init", "-b", "main"]);

    let mut child = Command::new("git")
        .args(["fast-import", "--quiet"])
        .current_dir(dir)
        .stdin(Stdio::piped())
        .spawn()
        .expect("failed to spawn git fast-import");

    {
        let stdin = child.stdin.as_mut().expect("stdin");
        let base_ts = 1_700_000_000i64;

        for i in 1..=num_commits {
            let msg = if i % 500 == 0 {
                format!("Release milestone #{i}")
            } else {
                format!("Commit #{i}: update module state")
            };
            let content = format!("pub fn value() -> usize {{ {i} }}\n");
            let ts = base_ts + i as i64;

            writeln!(stdin, "commit refs/heads/main").unwrap();
            writeln!(stdin, "mark :{i}").unwrap();
            writeln!(
                stdin,
                "committer Stress Tester <stress@gitcraft.local> {ts} +0000"
            )
            .unwrap();
            writeln!(stdin, "data {}", msg.len()).unwrap();
            stdin.write_all(msg.as_bytes()).unwrap();
            writeln!(stdin).unwrap();
            if i > 1 {
                writeln!(stdin, "from :{}", i - 1).unwrap();
            }
            writeln!(stdin, "M 100644 inline src/lib.rs").unwrap();
            writeln!(stdin, "data {}", content.len()).unwrap();
            stdin.write_all(content.as_bytes()).unwrap();
            writeln!(stdin).unwrap();
        }

        // Add 10 feature branches branching off earlier commits
        for b in 1..=10 {
            let parent_mark = (num_commits / 10) * b;
            let mark = num_commits + b;
            let msg = format!("Feature branch #{b}");
            let ts = base_ts + num_commits as i64 + b as i64;
            writeln!(stdin, "commit refs/heads/feature/topic-{b}").unwrap();
            writeln!(stdin, "mark :{mark}").unwrap();
            writeln!(
                stdin,
                "committer Stress Tester <stress@gitcraft.local> {ts} +0000"
            )
            .unwrap();
            writeln!(stdin, "data {}", msg.len()).unwrap();
            stdin.write_all(msg.as_bytes()).unwrap();
            writeln!(stdin).unwrap();
            writeln!(stdin, "from :{parent_mark}").unwrap();
            writeln!(stdin, "M 100644 inline feature_{b}.txt").unwrap();
            writeln!(stdin, "data 4\nwip\n").unwrap();
        }
    }

    let status = child.wait().expect("wait fast-import");
    assert!(status.success(), "git fast-import failed");
    run_git(dir, &["checkout", "-f", "main"]);
}

#[test]
fn stress_test_10k_commits_pagination_search_and_large_diff() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();

    let gen_start = Instant::now();
    generate_large_repo_via_fast_import(root, 10_000);
    let gen_elapsed = gen_start.elapsed();

    let open_start = Instant::now();
    let session = RepoSession::new(root.to_string_lossy().into_owned()).unwrap();
    let open_elapsed = open_start.elapsed();

    // 1. First 500 commits (Milestone 2 target: fast paginated fetch)
    let page1_start = Instant::now();
    let page1 = session.get_commit_graph(0, 500, None).unwrap();
    let page1_elapsed = page1_start.elapsed();
    assert_eq!(page1.len(), 500);

    // 2. Second page (offset 500, limit 500) - verify no overlap
    let page2_start = Instant::now();
    let page2 = session.get_commit_graph(500, 500, None).unwrap();
    let page2_elapsed = page2_start.elapsed();
    assert_eq!(page2.len(), 500);
    assert_ne!(
        page1.last().unwrap().oid_hex,
        page2.first().unwrap().oid_hex
    );

    // 3. Search across 10k commits
    let search_start = Instant::now();
    let matches = session
        .get_commit_graph(0, 50, Some("milestone".into()))
        .unwrap();
    let search_elapsed = search_start.elapsed();
    assert_eq!(matches.len(), 20);

    // 4. List all branches
    let branches_start = Instant::now();
    let branches = session.list_branches().unwrap();
    let branches_elapsed = branches_start.elapsed();
    assert_eq!(branches.len(), 11);

    // 5. Large 5,000-line file diff + syntect highlighting
    let mut big_file = String::new();
    for i in 0..5_000 {
        big_file.push_str(&format!("pub fn fn_{i}(x: i32) -> i32 {{ x + {i} }}\n"));
    }
    fs::write(root.join("big.rs"), &big_file).unwrap();
    run_git(root, &["add", "big.rs"]);
    run_git(
        root,
        &[
            "-c",
            "user.name=Stress",
            "-c",
            "user.email=s@m.local",
            "commit",
            "-m",
            "Add big.rs",
        ],
    );

    let modified: String = (0..5_000)
        .map(|i| {
            if i % 10 == 0 {
                format!("pub fn fn_{i}(x: i32) -> i32 {{ x * 2 + {i} }}\n")
            } else {
                format!("pub fn fn_{i}(x: i32) -> i32 {{ x + {i} }}\n")
            }
        })
        .collect();
    fs::write(root.join("big.rs"), modified).unwrap();

    let diff_start = Instant::now();
    let diff_rows = session
        .get_working_diff(Some("big.rs".into()), false)
        .unwrap();
    let diff_elapsed = diff_start.elapsed();
    assert!(diff_rows.len() > 1_000);

    eprintln!(
        "=== GitCraft 10k-Commit Stress Benchmark ===\n\
         generate 10,010 commits : {:?}\n\
         RepoSession::new        : {:?}\n\
         graph page 1 (0..500)   : {:?}\n\
         graph page 2 (500..1000): {:?}\n\
         search (10k scan)       : {:?}\n\
         list_branches (11)      : {:?}\n\
         5,000-line diff+syntect : {:?} ({} rows)",
        gen_elapsed,
        open_elapsed,
        page1_elapsed,
        page2_elapsed,
        search_elapsed,
        branches_elapsed,
        diff_elapsed,
        diff_rows.len()
    );
}

#[test]
fn index_commit_graph_and_random_access_lookup() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    generate_large_repo_via_fast_import(root, 1_500);

    let session = RepoSession::new(root.to_string_lossy().into_owned()).unwrap();

    // Index all 1,510 commits without materializing rows.
    let summary = session.index_commit_graph(false).unwrap();
    assert_eq!(summary.total_count, 1_510);
    assert!(summary.exhausted);

    // Random-access window deep in the history materializes directly from checkpoints.
    let deep_window = session.get_commit_graph(1_200, 50, None).unwrap();
    assert_eq!(deep_window.len(), 50);

    // find_commit_index returns the exact 0-based row index.
    let target_oid = deep_window[17].oid_hex.clone();
    let found = session.find_commit_index(target_oid, false).unwrap();
    assert_eq!(found, Some(1_217));

    // Unknown or invalid OIDs return None.
    assert_eq!(
        session
            .find_commit_index("0000000000000000000000000000000000000000".into(), false)
            .unwrap(),
        None
    );
    assert_eq!(
        session
            .find_commit_index("not-a-hex".into(), false)
            .unwrap(),
        None
    );
}

#[test]
fn cached_graph_window_serves_only_the_indexed_view() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    generate_large_repo_via_fast_import(root, 1_500);

    let session = RepoSession::new(root.to_string_lossy().into_owned()).unwrap();

    // Nothing indexed yet: the caller has to fall back to a full fetch.
    assert!(session.cached_graph_window(0, 50, false).is_none());

    // A first page indexes only a prefix; windows past it are not served.
    session.get_commit_graph(0, 100, None).unwrap();
    assert!(session.cached_graph_window(1_200, 50, false).is_none());

    session.index_commit_graph(false).unwrap();
    let cached = session.cached_graph_window(1_200, 50, false).unwrap();
    let walked = session.get_commit_graph(1_200, 50, None).unwrap();
    assert_eq!(format!("{cached:?}"), format!("{walked:?}"));

    // The tail is clipped to the end of history.
    assert_eq!(
        session.cached_graph_window(1_500, 50, false).unwrap().len(),
        10
    );

    // A different scope, sort or a search walk doesn't match the cached index.
    assert!(session.cached_graph_window(0, 50, true).is_none());
    session.set_commit_sort(CommitSort::Topological);
    assert!(session.cached_graph_window(0, 50, false).is_none());
    session.set_commit_sort(CommitSort::ByDate);
    assert!(session.cached_graph_window(0, 50, false).is_some());
    session
        .get_commit_graph(0, 50, Some("milestone".into()))
        .unwrap();
    assert!(session.cached_graph_window(0, 50, false).is_none());
}
