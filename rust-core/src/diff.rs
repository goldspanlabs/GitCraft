use std::{io, path::Path};

use crate::{git_cli, highlight, DiffRow};

pub fn working_tree(repo: &Path) -> io::Result<Vec<DiffRow>> {
    let raw = git_cli::run(repo, &["diff", "--no-ext-diff", "--unified=3"])?;
    parse_with_ext(&raw, None)
}

pub fn working_tree_file(
    repo: &Path,
    path: Option<&str>,
    staged: bool,
) -> io::Result<Vec<DiffRow>> {
    let mut args = vec!["diff", "--no-ext-diff", "--unified=3"];
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
            let is_tracked =
                git_cli::run(repo, &["ls-files", "--error-unmatch", "--", rel_path]).is_ok();
            let full_path = repo.join(rel_path);
            if !is_tracked && full_path.is_file() {
                if let Ok(bytes) = std::fs::read(&full_path) {
                    if bytes.len() > 256 * 1024 || bytes.contains(&0) {
                        return Ok(vec![DiffRow {
                            kind: "hunk".into(),
                            text: format!("Binary or large file ({} bytes)", bytes.len()),
                            old_line: None,
                            new_line: None,
                            spans: Vec::new(),
                        }]);
                    }
                    let text = String::from_utf8_lossy(&bytes);
                    let mut rows = vec![DiffRow {
                        kind: "hunk".into(),
                        text: format!("@@ -0,0 +1,{} @@ (untracked)", text.lines().count()),
                        old_line: None,
                        new_line: None,
                        spans: Vec::new(),
                    }];
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

    parse_with_ext(&raw, ext)
}

pub fn commit_diff(repo: &Path, oid_hex: &str, path: Option<&str>) -> io::Result<Vec<DiffRow>> {
    let mut args = vec!["show", "--no-ext-diff", "--unified=3", "--format=", oid_hex];
    if let Some(p) = path {
        args.push("--");
        args.push(p);
    }
    let raw = git_cli::run(repo, &args)?;
    let ext = path.and_then(|p| Path::new(p).extension().and_then(|e| e.to_str()));
    parse_with_ext(&raw, ext)
}

#[cfg(test)]
pub fn parse(input: &str) -> io::Result<Vec<DiffRow>> {
    parse_with_ext(input, None)
}

fn parse_with_ext(input: &str, default_ext: Option<&str>) -> io::Result<Vec<DiffRow>> {
    let mut rows = Vec::new();
    let mut highlighter = default_ext.map(highlight::LineHighlighter::new);
    let mut old_line: u32 = 0;
    let mut new_line: u32 = 0;

    for line in input.lines() {
        if let Some(file_path) = line.strip_prefix("+++ b/") {
            let ext = Path::new(file_path).extension().and_then(|e| e.to_str());
            highlighter = ext.map(highlight::LineHighlighter::new);
            rows.push(DiffRow {
                kind: "header".into(),
                text: line.to_owned(),
                old_line: None,
                new_line: None,
                spans: Vec::new(),
            });
            continue;
        }

        if line.starts_with("diff --git ")
            || line.starts_with("index ")
            || line.starts_with("--- ")
            || line.starts_with("new file mode")
            || line.starts_with("deleted file mode")
        {
            rows.push(DiffRow {
                kind: "header".into(),
                text: line.to_owned(),
                old_line: None,
                new_line: None,
                spans: Vec::new(),
            });
            continue;
        }

        if line.starts_with("@@") {
            if let Some((o, n)) = parse_hunk_start(line) {
                old_line = o;
                new_line = n;
            }
            rows.push(DiffRow {
                kind: "hunk".into(),
                text: line.to_owned(),
                old_line: None,
                new_line: None,
                spans: Vec::new(),
            });
            continue;
        }

        let (kind, row_old, row_new, code_slice) = if let Some(rest) = line.strip_prefix('+') {
            let nl = new_line;
            new_line += 1;
            ("addition", None, Some(nl), Some(rest))
        } else if let Some(rest) = line.strip_prefix('-') {
            let ol = old_line;
            old_line += 1;
            ("deletion", Some(ol), None, Some(rest))
        } else if let Some(rest) = line.strip_prefix(' ') {
            let ol = old_line;
            let nl = new_line;
            old_line += 1;
            new_line += 1;
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

fn parse_hunk_start(line: &str) -> Option<(u32, u32)> {
    // Format: @@ -old_start,old_count +new_start,new_count @@
    let after_at = line.strip_prefix("@@ ")?;
    let end = after_at.find(" @@")?;
    let header = &after_at[..end];
    let mut parts = header.split_whitespace();
    let old_part = parts.next()?.strip_prefix('-')?;
    let new_part = parts.next()?.strip_prefix('+')?;
    let old_start = old_part.split(',').next()?.parse::<u32>().ok()?;
    let new_start = new_part.split(',').next()?.parse::<u32>().ok()?;
    Some((old_start, new_start))
}

#[cfg(test)]
mod tests {
    use super::*;
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
