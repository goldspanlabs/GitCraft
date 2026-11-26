use std::{io, path::Path};

use crate::{git_cli, highlight, DiffRow};

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
    let ext = path.and_then(|p| Path::new(p).extension().and_then(|e| e.to_str()));

    // An empty unstaged diff only means "untracked" if git doesn't know the
    // path. A tracked file with no unstaged changes must yield no rows.
    if raw.trim().is_empty() && !staged {
        if let Some(rel_path) = path {
            let is_tracked = git_cli::run(
                repo,
                &[
                    "--literal-pathspecs",
                    "ls-files",
                    "--error-unmatch",
                    "--",
                    rel_path,
                ],
            )
            .is_ok();
            let full_path = repo.join(rel_path);
            if !is_tracked && full_path.is_file() {
                if let Ok(bytes) = std::fs::read(&full_path) {
                    if bytes.len() > 256 * 1024 || bytes.contains(&0) {
                        return Ok(vec![DiffRow::meta(
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
                        let spans = hl
                            .as_mut()
                            .map(|h| h.highlight_line(line))
                            .unwrap_or_default();
                        rows.push(DiffRow {
                            kind: "addition".into(),
                            text: format!("+{line}"),
                            old_line: None,
                            new_line: Some((idx + 1) as u32),
                            spans: shift_spans(spans, 1),
                        });
                    }
                    return Ok(rows);
                }
            }
        }
    }

    Ok(parse_with_ext(&raw, ext)?)
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
    let ext = path.and_then(|p| Path::new(p).extension().and_then(|e| e.to_str()));
    Ok(parse_with_ext(&raw, ext)?)
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
            let ext = Path::new(file_path).extension().and_then(|e| e.to_str());
            highlighter = ext.map(highlight::LineHighlighter::new);
            rows.push(DiffRow::meta("header", line));
            continue;
        }

        if line.starts_with("diff --git ")
            || (!in_hunk
                && (line.starts_with("index ")
                    || line.starts_with("--- ")
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

        let spans = match (code_slice, highlighter.as_mut()) {
            (Some(code), Some(hl)) if !code.is_empty() && code.len() <= 512 => {
                shift_spans(hl.highlight_line(code), 1)
            }
            _ => Vec::new(),
        };

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
