use crate::{git_cli, DiffRow};
use std::{io, path::Path};

pub fn working_tree(repo: &Path) -> io::Result<Vec<DiffRow>> {
    parse(&git_cli::run(
        repo,
        &["diff", "--no-ext-diff", "--unified=3"],
    )?)
}

pub fn parse(input: &str) -> io::Result<Vec<DiffRow>> {
    Ok(input
        .lines()
        .map(|line| DiffRow {
            kind: if line.starts_with('+') && !line.starts_with("+++") {
                "addition"
            } else if line.starts_with('-') && !line.starts_with("---") {
                "deletion"
            } else if line.starts_with("@@") {
                "hunk"
            } else {
                "context"
            }
            .into(),
            text: line.to_owned(),
            spans: Vec::new(),
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn classifies_unified_lines() {
        let rows = parse("@@ -1 +1 @@\n-old\n+new\n same").unwrap();
        assert_eq!(rows[0].kind, "hunk");
        assert_eq!(rows[1].kind, "deletion");
        assert_eq!(rows[2].kind, "addition");
    }
}
