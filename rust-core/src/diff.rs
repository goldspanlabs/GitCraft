use std::{io, path::Path};

use crate::{
    git_cli, highlight, validation::is_tracked, CompareFile, DiffRow, FileContentPair,
    GitCraftError,
};

pub fn working_tree(repo: &Path) -> Result<Vec<DiffRow>, crate::GitCraftError> {
    working_tree_file(repo, None, false)
}

pub fn working_tree_file(
    repo: &Path,
    path: Option<&str>,
    staged: bool,
) -> Result<Vec<DiffRow>, crate::GitCraftError> {
    // Paths are literal filenames, not globs: `notes[1].txt` must not match `notes1.txt`.
    let mut args = vec![
        "--literal-pathspecs",
        "diff",
        "--no-ext-diff",
        "--unified=3",
    ];
    if staged {
        args.push("--cached");
    }
    if let Some(p) = path {
        args.push("--");
        args.push(p);
    }
    let raw = git_cli::run(repo, &args)?;
    let ext = path.and_then(file_ext);

    // An empty unstaged diff only means "untracked" if git doesn't know the
    // path. A tracked file with no unstaged changes must yield no rows.
    if raw.trim().is_empty() && !staged {
        if let Some(rows) = path.and_then(|rel_path| untracked_file_rows(repo, rel_path, ext)) {
            return Ok(rows);
        }
    }

    Ok(parse_with_ext(&raw, ext)?)
}

/// The extension of `path`, such as `rs`, used to pick a syntax highlighter.
fn file_ext(path: &str) -> Option<&str> {
    Path::new(path).extension().and_then(|e| e.to_str())
}

/// Shows an untracked file as one hunk that adds every line, or `None` when `rel_path` is
/// tracked, not a regular file, or can't be read.
fn untracked_file_rows(repo: &Path, rel_path: &str, ext: Option<&str>) -> Option<Vec<DiffRow>> {
    let full_path = repo.join(rel_path);
    if is_tracked(repo, rel_path) {
        return None;
    }
    let canonical_root = std::fs::canonicalize(repo).ok()?;
    let parent = std::fs::canonicalize(full_path.parent()?).ok()?;
    if !parent.starts_with(canonical_root) {
        return None;
    }
    let meta = std::fs::symlink_metadata(&full_path).ok()?;
    let bytes = if meta.is_symlink() {
        std::fs::read_link(&full_path)
            .ok()?
            .to_string_lossy()
            .as_bytes()
            .to_vec()
    } else if meta.is_file() {
        std::fs::read(&full_path).ok()?
    } else {
        return None;
    };
    if bytes.len() > 256 * 1024 || bytes.contains(&0) {
        return Some(vec![DiffRow::meta(
            "hunk",
            format!("Binary or large file ({} bytes)", bytes.len()),
        )]);
    }
    let text = String::from_utf8_lossy(&bytes);
    let mut rows = vec![DiffRow::meta(
        "hunk",
        format!("@@ -0,0 +1,{} @@ (untracked)", text.lines().count()),
    )];
    let mut hl = ext.map(highlight::LineHighlighter::new);
    for (idx, line) in text.lines().enumerate() {
        let spans = highlight_code(line, hl.as_mut());
        rows.push(DiffRow {
            kind: "addition".into(),
            text: format!("+{line}"),
            old_line: None,
            new_line: Some((idx + 1) as u32),
            spans,
        });
    }
    Some(rows)
}

pub fn commit_diff(
    repo: &Path,
    oid_hex: &str,
    path: Option<&str>,
) -> Result<Vec<DiffRow>, crate::GitCraftError> {
    // Literal paths (as in `working_tree_file`), so `a*.txt` does not also match `ab.txt`. A
    // merge commit is shown against its first parent; plain `git show` prints nothing for a
    // clean merge.
    let mut args = vec![
        "--literal-pathspecs",
        "show",
        "-m",
        "--first-parent",
        "--no-ext-diff",
        "--unified=3",
        "--format=",
        oid_hex,
    ];
    if let Some(p) = path {
        args.push("--");
        args.push(p);
    }
    let raw = git_cli::run(repo, &args)?;
    let ext = path.and_then(file_ext);
    Ok(parse_with_ext(&raw, ext)?)
}

/// Diffs a file against a pinned comparison base, with both names for rename detection.
pub(crate) fn compare_file_diff(
    repo: &Path,
    base: &str,
    head: Option<&str>,
    file: &CompareFile,
) -> Result<Vec<DiffRow>, GitCraftError> {
    let ext = file_ext(&file.path);
    let mut args = vec![
        "--literal-pathspecs",
        "diff",
        "-M",
        "--no-ext-diff",
        "--no-textconv",
        "--unified=3",
        base,
    ];
    args.extend(head);
    args.extend(["--", &file.path]);
    args.extend(file.old_path.as_deref());
    let raw = if head.is_none() && !matches!(file.status.as_str(), "A" | "D") {
        let paths: Vec<_> = std::iter::once(file.path.as_str())
            .chain(file.old_path.as_deref())
            .collect();
        let untracked = compare_untracked_paths(repo, &paths)?;
        let restored: Vec<_> = untracked
            .split_terminator('\0')
            .filter(|path| paths.contains(path))
            .collect();
        run_compare_worktree_diff(repo, &args, base, &restored)?
    } else {
        git_cli::run(repo, &args)?
    };
    if raw.is_empty() && head.is_none() && file.status == "A" {
        if let Some(rows) = untracked_file_rows(repo, &file.path, ext) {
            return Ok(rows);
        }
    }
    Ok(parse_with_ext(&raw, ext)?)
}

/// Lists untracked paths eligible for the working-tree comparison.
pub(crate) fn compare_untracked_paths(
    repo: &Path,
    paths: &[&str],
) -> Result<String, GitCraftError> {
    let mut args = vec![
        "--literal-pathspecs",
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
    ];
    args.extend_from_slice(paths);
    git_cli::run(repo, &args)
}

/// Supplies a temporary index when a path from the base has been staged for
/// removal and recreated. Git can then diff its on-disk version as usual.
pub(crate) fn run_compare_worktree_diff(
    repo: &Path,
    args: &[&str],
    base: &str,
    restored_paths: &[&str],
) -> Result<String, GitCraftError> {
    if restored_paths.is_empty() {
        return git_cli::run(repo, args);
    }
    let temp = tempfile::tempdir()?;
    let temp_index = temp.path().join("index");
    let index = git_cli::run(
        repo,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
    )?;
    match std::fs::copy(index.strip_suffix('\n').unwrap_or(&index), &temp_index) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }

    let mut tree_args = vec!["--literal-pathspecs", "ls-tree", "-r", "-z", base, "--"];
    tree_args.extend_from_slice(restored_paths);
    let entries = git_cli::run(repo, &tree_args)?;
    let env = [("GIT_INDEX_FILE", temp_index.into_os_string())];
    git_cli::run_with_env(
        repo,
        &[
            "-c",
            "core.splitIndex=false",
            "-c",
            "core.fsmonitor=false",
            "update-index",
            "-z",
            "--index-info",
        ],
        &env,
        Some(entries.into_bytes()),
    )?;
    git_cli::run_with_env(repo, args, &env, None)
}

pub(crate) fn compare_file_content_pair(
    repo_path: &Path,
    sync_repo: &gix::ThreadSafeRepository,
    base: &str,
    head: Option<&str>,
    file: &CompareFile,
) -> Result<FileContentPair, GitCraftError> {
    let old_path = file.old_path.as_deref().unwrap_or(&file.path);
    let old_content = if file.status == "A" {
        None
    } else {
        commit_file_content(sync_repo, base, old_path)?
    };
    let new_content = match head {
        Some(oid) => commit_file_content(sync_repo, oid, &file.path)?,
        None if file.status == "D" => None,
        None => working_file_content(repo_path, sync_repo, &file.path, false)?,
    };
    Ok(FileContentPair {
        old_content,
        new_content,
    })
}

/// Maximum file size (1 MiB) allowed for full-file preview.
const MAX_PREVIEW_BYTES: usize = 1024 * 1024;

/// Reads a working-tree or staged file's full UTF-8 text for previewing.
/// Returns `Ok(None)` if the file does not exist (e.g. deleted).
pub fn working_file_content(
    repo_path: &Path,
    sync_repo: &gix::ThreadSafeRepository,
    path: &str,
    staged: bool,
) -> Result<Option<String>, crate::GitCraftError> {
    if staged {
        let repo = sync_repo.to_thread_local();
        return index_blob_text(&repo, path);
    }
    let full_path = repo_path.join(path);
    let Ok(meta) = std::fs::symlink_metadata(&full_path) else {
        return Ok(None);
    };
    if meta.file_type().is_symlink() {
        let target = std::fs::read_link(&full_path)?;
        return Ok(Some(target.to_string_lossy().into_owned()));
    }
    if !meta.is_file() {
        return Ok(None);
    }
    let Ok(canonical_root) = std::fs::canonicalize(repo_path) else {
        return Ok(None);
    };
    let Ok(canonical_file) = std::fs::canonicalize(&full_path) else {
        return Ok(None);
    };
    if !canonical_file.starts_with(&canonical_root) {
        return Ok(None);
    }
    if meta.len() as usize > MAX_PREVIEW_BYTES {
        return Err(crate::GitCraftError::message(format!(
            "File is too large to preview ({} bytes)",
            meta.len()
        )));
    }
    let bytes = std::fs::read(&canonical_file)?;
    if bytes.contains(&0) {
        return Err(crate::GitCraftError::message(
            "Binary file cannot be previewed",
        ));
    }
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

/// Reads a file's full UTF-8 text at a specific commit for previewing.
/// Returns `Ok(None)` if the file does not exist at that commit (e.g. deleted).
pub fn commit_file_content(
    sync_repo: &gix::ThreadSafeRepository,
    oid_hex: &str,
    path: &str,
) -> Result<Option<String>, crate::GitCraftError> {
    let oid =
        gix::ObjectId::from_hex(oid_hex.as_bytes()).map_err(crate::GitCraftError::from_display)?;
    let repo = sync_repo.to_thread_local();
    commit_tree_blob_text(&repo, oid, path)
}

/// Reads both the old and new versions of a working-tree or staged file for rich diffing.
pub fn working_file_content_pair(
    repo_path: &Path,
    sync_repo: &gix::ThreadSafeRepository,
    path: &str,
    staged: bool,
) -> Result<crate::FileContentPair, crate::GitCraftError> {
    let repo = sync_repo.to_thread_local();
    let old_content = if staged {
        head_blob_text(&repo, path)?
    } else if is_tracked(repo_path, path) {
        index_blob_text(&repo, path)?
    } else {
        None
    };
    let new_content = working_file_content(repo_path, sync_repo, path, staged)?;
    Ok(crate::FileContentPair {
        old_content,
        new_content,
    })
}

/// Reads both the parent and commit versions of a file for rich diffing.
pub fn commit_file_content_pair(
    repo_path: &Path,
    sync_repo: &gix::ThreadSafeRepository,
    oid_hex: &str,
    path: &str,
) -> Result<crate::FileContentPair, crate::GitCraftError> {
    let oid =
        gix::ObjectId::from_hex(oid_hex.as_bytes()).map_err(crate::GitCraftError::from_display)?;
    let repo = sync_repo.to_thread_local();
    let parent_id = repo
        .find_commit(oid)
        .map_err(crate::GitCraftError::from_display)?
        .parent_ids()
        .next()
        .map(|p| p.detach());
    let new_content = commit_tree_blob_text(&repo, oid, path)?;
    let old_content = match parent_id {
        Some(pid) => {
            let mut old = commit_tree_blob_text(&repo, pid, path)?;
            if old.is_none() && new_content.is_some() {
                // The file may have been renamed or moved in this commit.
                if let Some(old_path) = renamed_from(repo_path, pid, oid, path)? {
                    old = commit_tree_blob_text(&repo, pid, &old_path)?;
                }
            }
            old
        }
        None => None,
    };
    Ok(crate::FileContentPair {
        old_content,
        new_content,
    })
}

/// The path `path` had in `parent` when `commit` renamed it within the same directory
/// (rename detection). Moves to another directory are not followed: the preview resolves
/// relative assets of deleted blocks against the new path, which would pick the wrong files.
/// `Ok(None)` means the lookup succeeded and found no such rename.
fn renamed_from(
    repo_path: &Path,
    parent: gix::ObjectId,
    commit: gix::ObjectId,
    path: &str,
) -> Result<Option<String>, crate::GitCraftError> {
    let out = git_cli::run(
        repo_path,
        &[
            "diff-tree",
            "-r",
            "-M",
            "--diff-filter=R",
            "--name-status",
            "-z",
            &parent.to_string(),
            &commit.to_string(),
        ],
    )?;
    let mut fields = out.split('\0').filter(|f| !f.is_empty());
    while let (Some(status), Some(old), Some(new)) = (fields.next(), fields.next(), fields.next()) {
        if status.starts_with('R') && new == path {
            let same_dir = Path::new(old).parent() == Path::new(new).parent();
            return Ok(same_dir.then(|| old.to_owned()));
        }
    }
    Ok(None)
}

fn index_blob_text(
    repo: &gix::Repository,
    path: &str,
) -> Result<Option<String>, crate::GitCraftError> {
    let index = repo
        .index_or_empty()
        .map_err(crate::GitCraftError::from_display)?;
    let Some(entry) = index.entry_by_path(path.into()) else {
        return Ok(None);
    };
    odb_blob_text(repo, entry.id)
}

fn head_blob_text(
    repo: &gix::Repository,
    path: &str,
) -> Result<Option<String>, crate::GitCraftError> {
    let head = repo.head().map_err(crate::GitCraftError::from_display)?;
    if head.is_unborn() {
        return Ok(None);
    }
    let head_id = repo.head_id().map_err(crate::GitCraftError::from_display)?;
    commit_tree_blob_text(repo, head_id.detach(), path)
}

fn commit_tree_blob_text(
    repo: &gix::Repository,
    commit_id: gix::ObjectId,
    path: &str,
) -> Result<Option<String>, crate::GitCraftError> {
    let commit = repo
        .find_commit(commit_id)
        .map_err(crate::GitCraftError::from_display)?;
    let tree = commit.tree().map_err(crate::GitCraftError::from_display)?;
    let Some(entry) = tree
        .lookup_entry_by_path(path)
        .map_err(crate::GitCraftError::from_display)?
    else {
        return Ok(None);
    };
    odb_blob_text(repo, entry.oid().into())
}

fn odb_blob_text(
    repo: &gix::Repository,
    oid: gix::ObjectId,
) -> Result<Option<String>, crate::GitCraftError> {
    use gix::prelude::HeaderExt;
    let header = repo
        .objects
        .header(oid)
        .map_err(crate::GitCraftError::from_display)?;
    if header.size() > MAX_PREVIEW_BYTES as u64 {
        return Err(crate::GitCraftError::message(format!(
            "File is too large to preview ({} bytes)",
            header.size()
        )));
    }
    let obj = repo
        .find_object(oid)
        .map_err(crate::GitCraftError::from_display)?;
    if obj.kind != gix::object::Kind::Blob {
        return Ok(None);
    }
    if obj.data.contains(&0) {
        return Err(crate::GitCraftError::message(
            "Binary file cannot be previewed",
        ));
    }
    Ok(Some(String::from_utf8_lossy(&obj.data).into_owned()))
}

/// Maximum asset size (16 MiB) allowed when loading images/assets in Markdown preview.
const MAX_ASSET_BYTES: usize = 16 * 1024 * 1024;

/// Reads raw asset bytes from the matching diff side (commit tree or its parent, HEAD or index,
/// or working tree) with symlink containment and a size cap.
pub fn read_repo_asset(
    repo_path: &Path,
    sync_repo: &gix::ThreadSafeRepository,
    path: &str,
    commit_oid: Option<&str>,
    staged: bool,
    old_side: bool,
) -> Result<Option<Vec<u8>>, crate::GitCraftError> {
    if let Some(oid_hex) = commit_oid {
        let oid = gix::ObjectId::from_hex(oid_hex.as_bytes())
            .map_err(crate::GitCraftError::from_display)?;
        let repo = sync_repo.to_thread_local();
        let target_oid = if old_side {
            let Some(parent_id) = repo
                .find_commit(oid)
                .ok()
                .and_then(|c| c.parent_ids().next())
                .map(|p| p.detach())
            else {
                return Ok(None);
            };
            parent_id
        } else {
            oid
        };
        let Ok(commit) = repo.find_commit(target_oid) else {
            return Ok(None);
        };
        let Ok(tree) = commit.tree() else {
            return Ok(None);
        };
        let Ok(Some(entry)) = tree.lookup_entry_by_path(path) else {
            return Ok(None);
        };
        return odb_blob_bytes(&repo, entry.oid().into());
    }

    if staged {
        let repo = sync_repo.to_thread_local();
        if old_side {
            let Ok(head_id) = repo.head_id() else {
                return Ok(None);
            };
            let Ok(commit) = repo.find_commit(head_id.detach()) else {
                return Ok(None);
            };
            let Ok(tree) = commit.tree() else {
                return Ok(None);
            };
            let Ok(Some(entry)) = tree.lookup_entry_by_path(path) else {
                return Ok(None);
            };
            return odb_blob_bytes(&repo, entry.oid().into());
        }
        let Ok(index) = repo.index() else {
            return Ok(None);
        };
        let Some(entry) = index.entry_by_path(path.into()) else {
            return Ok(None);
        };
        return odb_blob_bytes(&repo, entry.id);
    }

    if old_side {
        let repo = sync_repo.to_thread_local();
        let Ok(index) = repo.index() else {
            return Ok(None);
        };
        let Some(entry) = index.entry_by_path(path.into()) else {
            return Ok(None);
        };
        return odb_blob_bytes(&repo, entry.id);
    }

    let Ok(canonical_root) = std::fs::canonicalize(repo_path) else {
        return Ok(None);
    };
    let Ok(canonical_file) = std::fs::canonicalize(repo_path.join(path)) else {
        return Ok(None);
    };
    if !canonical_file.starts_with(&canonical_root) {
        return Ok(None);
    }
    let Ok(meta) = std::fs::metadata(&canonical_file) else {
        return Ok(None);
    };
    if !meta.is_file() || meta.len() as usize > MAX_ASSET_BYTES {
        return Ok(None);
    }
    Ok(Some(std::fs::read(&canonical_file)?))
}

fn odb_blob_bytes(
    repo: &gix::Repository,
    oid: gix::ObjectId,
) -> Result<Option<Vec<u8>>, crate::GitCraftError> {
    use gix::prelude::HeaderExt;
    let Ok(header) = repo.objects.header(oid) else {
        return Ok(None);
    };
    if header.size() > MAX_ASSET_BYTES as u64 {
        return Ok(None);
    }
    let Ok(obj) = repo.find_object(oid) else {
        return Ok(None);
    };
    if obj.kind != gix::object::Kind::Blob {
        return Ok(None);
    }
    Ok(Some(obj.detach().data))
}

#[cfg(test)]
pub fn parse(input: &str) -> io::Result<Vec<DiffRow>> {
    parse_with_ext(input, None)
}

/// Diffs longer than this are cut off so a huge generated file can't stall the UI.
const MAX_DIFF_ROWS: usize = 20_000;

fn parse_with_ext(input: &str, default_ext: Option<&str>) -> io::Result<Vec<DiffRow>> {
    let mut rows = Vec::new();
    let mut highlighter = default_ext.map(highlight::LineHighlighter::new);
    let mut old_line: u32 = 0;
    let mut new_line: u32 = 0;
    // Lines of the current hunk still to come, from the counts in its `@@` header. While any
    // remain, a line starting with `--- ` or `+++ b/` is a deleted or added line (for example
    // the SQL comment `-- note`), not a file header.
    let mut old_left: u32 = 0;
    let mut new_left: u32 = 0;

    for line in input.lines() {
        if line.starts_with("diff --git ") {
            old_left = 0;
            new_left = 0;
        }
        let in_hunk = old_left > 0 || new_left > 0;
        if rows.len() >= MAX_DIFF_ROWS {
            rows.push(DiffRow::meta(
                "hunk",
                format!("Diff truncated: showing the first {MAX_DIFF_ROWS} lines"),
            ));
            break;
        }
        if let Some(file_path) = line.strip_prefix("+++ b/").filter(|_| !in_hunk) {
            highlighter = file_ext(file_path).map(highlight::LineHighlighter::new);
            rows.push(DiffRow::meta("header", line));
            continue;
        }

        if line.starts_with("diff --git ")
            || (!in_hunk
                && (line.starts_with("index ")
                    || line.starts_with("--- ")
                    || line == "+++ /dev/null"
                    || line.starts_with("new file mode")
                    || line.starts_with("deleted file mode")))
        {
            rows.push(DiffRow::meta("header", line));
            continue;
        }

        if line.starts_with("@@") {
            if let Some(hunk) = parse_hunk_start(line) {
                old_line = hunk.old_start;
                new_line = hunk.new_start;
                old_left = hunk.old_count;
                new_left = hunk.new_count;
            }
            rows.push(DiffRow::meta("hunk", line));
            continue;
        }

        let (kind, row_old, row_new, code_slice) = if let Some(rest) = line.strip_prefix('+') {
            let nl = new_line;
            new_line += 1;
            new_left = new_left.saturating_sub(1);
            ("addition", None, Some(nl), Some(rest))
        } else if let Some(rest) = line.strip_prefix('-') {
            let ol = old_line;
            old_line += 1;
            old_left = old_left.saturating_sub(1);
            ("deletion", Some(ol), None, Some(rest))
        } else if let Some(rest) = line.strip_prefix(' ') {
            let ol = old_line;
            let nl = new_line;
            old_line += 1;
            new_line += 1;
            old_left = old_left.saturating_sub(1);
            new_left = new_left.saturating_sub(1);
            ("context", Some(ol), Some(nl), Some(rest))
        } else {
            ("context", None, None, None)
        };

        let spans = code_slice
            .map(|code| highlight_code(code, highlighter.as_mut()))
            .unwrap_or_default();

        rows.push(DiffRow {
            kind: kind.into(),
            text: line.to_owned(),
            old_line: row_old,
            new_line: row_new,
            spans,
        });
    }

    Ok(rows)
}

/// Longer lines are shown plain: they are minified or generated, and highlighting them stalls
/// the diff.
const MAX_HIGHLIGHTED_LINE_BYTES: usize = 512;

/// Highlights a line of code, with spans placed after the row's `+`, `-` or space marker.
fn highlight_code(
    code: &str,
    highlighter: Option<&mut highlight::LineHighlighter>,
) -> Vec<crate::StyleSpan> {
    match highlighter {
        Some(hl) if !code.is_empty() && code.len() <= MAX_HIGHLIGHTED_LINE_BYTES => {
            shift_spans(hl.highlight_line(code), 1)
        }
        _ => Vec::new(),
    }
}

fn shift_spans(mut spans: Vec<crate::StyleSpan>, delta_utf16: u32) -> Vec<crate::StyleSpan> {
    for span in &mut spans {
        span.start_utf16 += delta_utf16;
    }
    spans
}

struct HunkHeader {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
}

fn parse_hunk_start(line: &str) -> Option<HunkHeader> {
    // Format: @@ -old_start,old_count +new_start,new_count @@
    let after_at = line.strip_prefix("@@ ")?;
    let end = after_at.find(" @@")?;
    let header = &after_at[..end];
    let mut parts = header.split_whitespace();
    let old_part = parts.next()?.strip_prefix('-')?;
    let new_part = parts.next()?.strip_prefix('+')?;
    // A missing count means one line.
    let range = |part: &str| -> Option<(u32, u32)> {
        let mut pieces = part.split(',');
        let start = pieces.next()?.parse::<u32>().ok()?;
        let count = match pieces.next() {
            Some(c) => c.parse::<u32>().ok()?,
            None => 1,
        };
        Some((start, count))
    };
    let (old_start, old_count) = range(old_part)?;
    let (new_start, new_count) = range(new_part)?;
    Some(HunkHeader {
        old_start,
        old_count,
        new_start,
        new_count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_lines_of_untracked_files_are_not_highlighted() {
        let dir = tempfile::tempdir().unwrap();
        git_cli::run(dir.path(), &["init", "-q"]).unwrap();
        let long = "var a=1;".repeat(100);
        std::fs::write(dir.path().join("min.js"), format!("var b=2;\n{long}\n")).unwrap();

        let rows = working_tree_file(dir.path(), Some("min.js"), false).unwrap();

        assert!(!rows[1].spans.is_empty());
        assert_eq!(rows[2].text, format!("+{long}"));
        assert!(rows[2].spans.is_empty());
    }

    #[test]
    fn very_long_diffs_are_truncated_with_a_notice() {
        let mut input = String::from("@@ -1,30000 +1,30000 @@\n");
        for i in 0..30_000 {
            input.push_str(&format!("+line {i}\n"));
        }
        let rows = parse(&input).unwrap();
        assert_eq!(rows.len(), MAX_DIFF_ROWS + 1);
        assert!(rows.last().unwrap().text.starts_with("Diff truncated"));
    }

    #[test]
    fn deleted_line_starting_with_dashes_is_not_a_header() {
        let input = "diff --git a/q.sql b/q.sql\n--- a/q.sql\n+++ b/q.sql\n@@ -1,4 +1,3 @@\n select 1;\n--- old comment\n select 2;\n select 3;\n";
        let rows = parse(input).unwrap();
        let gone = rows.iter().find(|r| r.text == "--- old comment").unwrap();
        assert_eq!(gone.kind, "deletion");
        assert_eq!(gone.old_line, Some(2));
        let last = rows.last().unwrap();
        assert_eq!((last.old_line, last.new_line), (Some(4), Some(3)));
        // The real headers before the hunk are still headers.
        assert_eq!(rows[1].kind, "header");
        assert_eq!(rows[2].kind, "header");
    }

    #[test]
    fn added_line_starting_with_plus_plus_is_not_a_header() {
        let input = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n keep\n+++ b/fake\n";
        let rows = parse(input).unwrap();
        let added = rows.iter().find(|r| r.text == "+++ b/fake").unwrap();
        assert_eq!(added.kind, "addition");
        assert_eq!(added.new_line, Some(2));
    }

    #[test]
    fn second_file_after_a_hunk_still_gets_headers() {
        let input = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -1 +1 @@\n-p\n+q\n";
        let rows = parse(input).unwrap();
        assert_eq!(rows.iter().filter(|r| r.kind == "header").count(), 6);
    }

    #[test]
    fn classifies_unified_lines_and_line_numbers() {
        let rows = parse("@@ -10,2 +20,2 @@\n-old\n+new\n same").unwrap();
        assert_eq!(rows[0].kind, "hunk");
        assert_eq!(rows[1].kind, "deletion");
        assert_eq!(rows[1].old_line, Some(10));
        assert_eq!(rows[1].new_line, None);
        assert_eq!(rows[2].kind, "addition");
        assert_eq!(rows[2].old_line, None);
        assert_eq!(rows[2].new_line, Some(20));
        assert_eq!(rows[3].kind, "context");
        assert_eq!(rows[3].old_line, Some(11));
        assert_eq!(rows[3].new_line, Some(21));
    }
}
