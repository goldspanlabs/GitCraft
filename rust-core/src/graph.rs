use std::io;
use std::path::Path;

use crate::{git_cli, CommitRow, GraphEdge};

pub fn history(repo: &Path, limit: usize) -> io::Result<Vec<CommitRow>> {
    let format = "%H%x1f%an%x1f%at%x1f%s%x1e";
    let output = git_cli::run(
        repo,
        &[
            "log",
            "--topo-order",
            "--date-order",
            "--all",
            &format!("--pretty=format:{format}"),
            &format!("-n{limit}"),
        ],
    )?;
    let mut rows = Vec::new();
    for (index, record) in output
        .split('\x1e')
        .filter(|r| !r.trim().is_empty())
        .enumerate()
    {
        let fields: Vec<_> = record.split('\x1f').collect();
        if fields.len() == 4 {
            rows.push(CommitRow {
                hash: fields[0].into(),
                author: fields[1].into(),
                timestamp: fields[2].parse().unwrap_or_default(),
                summary: fields[3].into(),
                lane: 0,
                max_lanes: 1,
                edges: vec![GraphEdge {
                    from_lane: 0,
                    to_lane: 0,
                    is_merge: false,
                    color_idx: index % 8,
                }],
            });
        }
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn empty_history_is_valid() {
        let path = tempfile::tempdir().unwrap();
        assert!(history(path.path(), 10).is_err());
    }
}
