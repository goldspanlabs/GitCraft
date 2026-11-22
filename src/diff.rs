use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiffLineKind { Context, Added, Removed, FileHeader, HunkHeader, Metadata }

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiffLine { pub kind: DiffLineKind, pub text: String, pub old_lineno: Option<usize>, pub new_lineno: Option<usize> }

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct FileDiff { pub old_path: Option<String>, pub new_path: Option<String>, pub lines: Vec<DiffLine> }

impl FileDiff {
    pub fn additions(&self) -> usize { self.lines.iter().filter(|l| l.kind == DiffLineKind::Added).count() }
    pub fn deletions(&self) -> usize { self.lines.iter().filter(|l| l.kind == DiffLineKind::Removed).count() }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct DiffParseError(pub String);
impl fmt::Display for DiffParseError { fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { f.write_str(&self.0) } }
impl std::error::Error for DiffParseError {}

/// Parses the output of `git diff --unified=N`, preserving line numbers.
pub fn parse_unified_diff(input: &str) -> Result<Vec<FileDiff>, DiffParseError> {
    let mut files = Vec::new();
    let mut current: Option<FileDiff> = None;
    let mut old = 0usize;
    let mut new = 0usize;
    for raw in input.lines() {
        if raw.starts_with("diff --git ") {
            if let Some(file) = current.take() { files.push(file); }
            current = Some(FileDiff { lines: vec![DiffLine { kind: DiffLineKind::Metadata, text: raw.into(), old_lineno: None, new_lineno: None }], ..Default::default() });
        } else if raw.starts_with("--- ") || raw.starts_with("+++ ") {
            let path = raw[4..].split('\t').next().unwrap_or("").trim_start_matches("a/").trim_start_matches("b/").to_string();
            let kind = if raw.starts_with("--- ") { DiffLineKind::FileHeader } else { DiffLineKind::FileHeader };
            if let Some(file) = current.as_mut() { if raw.starts_with("--- ") { file.old_path = Some(path); } else { file.new_path = Some(path); } file.lines.push(DiffLine { kind, text: raw.into(), old_lineno: None, new_lineno: None }); }
        } else if raw.starts_with("@@ ") {
            let (o, n) = parse_hunk_header(raw).ok_or_else(|| DiffParseError(format!("invalid hunk header: {raw}")))?;
            old = o; new = n;
            if let Some(file) = current.as_mut() { file.lines.push(DiffLine { kind: DiffLineKind::HunkHeader, text: raw.into(), old_lineno: None, new_lineno: None }); }
        } else if let Some(file) = current.as_mut() {
            let (kind, ol, nl) = match raw.as_bytes().first() {
                Some(b'+') => { let x = (DiffLineKind::Added, None, Some(new)); new += 1; x },
                Some(b'-') => { let x = (DiffLineKind::Removed, Some(old), None); old += 1; x },
                Some(b' ') => { let x = (DiffLineKind::Context, Some(old), Some(new)); old += 1; new += 1; x },
                _ => (DiffLineKind::Metadata, None, None),
            };
            file.lines.push(DiffLine { kind, text: raw.into(), old_lineno: ol, new_lineno: nl });
        }
    }
    if let Some(file) = current { files.push(file); }
    Ok(files)
}

fn parse_hunk_header(line: &str) -> Option<(usize, usize)> {
    let mut parts = line.split_whitespace();
    parts.next()?;
    let old = parts.next()?.trim_start_matches('-').split(',').next()?.parse().ok()?;
    let new = parts.next()?.trim_start_matches('+').split(',').next()?.parse().ok()?;
    Some((old, new))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_hunk_and_counts() {
        let d = parse_unified_diff("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,2 +1,2 @@\n-old\n+new\n same").unwrap();
        assert_eq!(d[0].additions(), 1);
        assert_eq!(d[0].deletions(), 1);
        assert_eq!(d[0].lines[4].new_lineno, Some(1));
    }
}
