use gix::bstr::ByteSlice;

use crate::{CommitDetail, FileChange, GitCraftError};

/// Common commit metadata shared by both graph rows and commit detail inspection.
pub(crate) struct CommitMetadata {
    pub summary: String,
    pub body: String,
    pub author_name: String,
    pub author_email: String,
    pub timestamp: i64,
}

pub(crate) fn extract_commit_metadata(
    commit: &gix::Commit<'_>,
    include_body: bool,
) -> CommitMetadata {
    let raw_msg = commit.message_raw_sloppy().to_str_lossy();
    let mut lines = raw_msg.lines();
    let summary = lines.next().unwrap_or_default().trim().to_owned();
    let body = if include_body {
        lines.collect::<Vec<_>>().join("\n").trim().to_owned()
    } else {
        String::new()
    };

    let (author_name, author_email) = commit
        .author()
        .map(|a| {
            (
                a.name.to_str_lossy().into_owned(),
                a.email.to_str_lossy().into_owned(),
            )
        })
        .unwrap_or_default();

    let timestamp = commit.time().map(|t| t.seconds).unwrap_or_default();

    CommitMetadata {
        summary,
        body,
        author_name,
        author_email,
        timestamp,
    }
}

pub fn get_commit_detail(
    repo_path: &std::path::Path,
    sync_repo: &gix::ThreadSafeRepository,
    oid_hex: &str,
) -> Result<CommitDetail, GitCraftError> {
    let oid = gix::ObjectId::from_hex(oid_hex.as_bytes()).map_err(GitCraftError::from_display)?;
    let repo = sync_repo.to_thread_local();
    let commit = repo.find_commit(oid).map_err(GitCraftError::from_display)?;

    let meta = extract_commit_metadata(&commit, true);
    let parent_oids: Vec<String> = commit
        .parent_ids()
        .map(|p| p.detach().to_hex().to_string())
        .collect();

    let single_commit = || {
        crate::git_cli::run(
            repo_path,
            &[
                "diff-tree",
                "--no-commit-id",
                "--name-status",
                "-z",
                "-r",
                "--root",
                oid_hex,
            ],
        )
    };
    // `diff-tree <commit>` prints nothing for a merge, so a merge lists its changes against
    // its first parent, matching the diff the inspector shows. At a shallow-clone boundary
    // the parent object is missing, so fall back to the plain form instead of failing.
    let files_output = match parent_oids.as_slice() {
        [first, _, ..] => crate::git_cli::run(
            repo_path,
            &["diff-tree", "--name-status", "-z", "-r", first, oid_hex],
        )
        .or_else(|_| single_commit())?,
        _ => single_commit()?,
    };

    // -z output is "<status>\0<path>\0" per file, with no quoting of unusual paths.
    let mut files = Vec::new();
    let mut fields = files_output.split('\0');
    while let (Some(status), Some(path)) = (fields.next(), fields.next()) {
        let status = status.trim();
        if status.is_empty() || path.is_empty() {
            continue;
        }
        files.push(FileChange {
            path: path.to_owned(),
            status: status.chars().next().unwrap_or('M').to_string(),
            staged: false,
        });
    }

    Ok(CommitDetail {
        oid_hex: oid_hex.to_owned(),
        short_oid: super::short_oid(oid_hex),
        summary: meta.summary,
        body: meta.body,
        author_name: meta.author_name,
        author_email: meta.author_email,
        timestamp: meta.timestamp,
        parent_oids,
        files,
    })
}
