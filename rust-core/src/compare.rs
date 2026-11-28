use std::{collections::HashSet, path::Path};

use crate::{
    diff, git_cli, graph, CompareFile, CompareSummary, DiffRow, FileContentPair, GitCraftError,
    RepoSession,
};

const WORKTREE: &str = "WORKTREE";

impl RepoSession {
    pub fn compare_branches(
        &self,
        base_ref: String,
        head_ref: String,
    ) -> Result<CompareSummary, GitCraftError> {
        if base_ref == "HEAD" && !has_attached_head(&self.path)? {
            return Err(GitCraftError::message("HEAD is detached."));
        }
        let base_oid = resolve(&self.path, &base_ref)?;
        let head_oid = resolve(&self.path, &head_ref)?;
        self.compare_summary(head_ref, base_ref, base_oid, head_oid, false)
    }

    pub fn compare_working_tree(&self, base_ref: String) -> Result<CompareSummary, GitCraftError> {
        let base_oid = resolve(&self.path, &base_ref)?;
        let head_oid = resolve(&self.path, "HEAD")?;
        self.compare_summary(base_ref, WORKTREE.into(), base_oid, head_oid, true)
    }

    fn compare_summary(
        &self,
        target_ref: String,
        source_ref: String,
        base_oid: String,
        head_oid: String,
        working: bool,
    ) -> Result<CompareSummary, GitCraftError> {
        let merge_base_oid = merge_base(&self.path, &base_oid, &head_oid)?
            .ok_or_else(|| GitCraftError::message("No merge base (unrelated histories)."))?;
        let counts = git_cli::run(
            &self.path,
            &[
                "rev-list",
                "--left-right",
                "--count",
                &format!("{base_oid}...{head_oid}"),
            ],
        )?;
        let (behind, ahead) = counts
            .trim()
            .split_once('\t')
            .and_then(|(left, right)| Some((left.parse().ok()?, right.parse().ok()?)))
            .ok_or_else(|| {
                GitCraftError::message("Git returned invalid ahead and behind counts.")
            })?;

        let mut args = vec![
            "diff",
            "--name-status",
            "-z",
            "-M",
            "--no-ext-diff",
            &merge_base_oid,
        ];
        if !working {
            args.push(&head_oid);
        }
        args.push("--");
        let mut files = parse_files(&git_cli::run(&self.path, &args)?)?;
        if working {
            let untracked = diff::compare_untracked_paths(&self.path, &[])?;
            let untracked: HashSet<_> = untracked.split_terminator('\0').collect();
            // Git's real index can omit a base file that was staged for deletion
            // and then recreated. Include those paths in the net tree comparison.
            let revived: HashSet<_> = files
                .iter()
                .filter_map(|file| {
                    let deleted_path = file
                        .old_path
                        .as_deref()
                        .or_else(|| (file.status == "D").then_some(file.path.as_str()))?;
                    untracked.get(deleted_path).copied()
                })
                .collect();
            if !revived.is_empty() {
                let paths: Vec<_> = revived.iter().copied().collect();
                let raw =
                    diff::run_compare_worktree_diff(&self.path, &args, &merge_base_oid, &paths)?;
                files = parse_files(&raw)?;
            }
            let listed: HashSet<_> = files.iter().map(|file| file.path.as_str()).collect();
            let mut added: Vec<_> = untracked
                .difference(&revived)
                .copied()
                .filter(|path| !listed.contains(path))
                .collect();
            added.sort_unstable();
            files.extend(added.into_iter().map(|path| CompareFile {
                path: path.into(),
                old_path: None,
                status: "A".into(),
            }));
        }
        Ok(CompareSummary {
            target_ref,
            source_ref,
            base_oid,
            head_oid: if working { WORKTREE.into() } else { head_oid },
            merge_base_oid,
            ahead,
            behind,
            files,
        })
    }

    /// HEAD and the branch tips are checked off the UI thread when the sidebar refreshes.
    pub fn comparable_branch_tips(&self, tips: Vec<String>) -> Result<Vec<String>, GitCraftError> {
        if !has_attached_head(&self.path)? {
            return Ok(Vec::new());
        }
        let head = resolve(&self.path, "HEAD")?;
        let mut seen = HashSet::new();
        let mut comparable = Vec::new();
        for tip in &tips {
            if seen.insert(tip) {
                validate_oid(tip)?;
                if *tip == head || merge_base(&self.path, &head, tip)?.is_some() {
                    comparable.push(tip.clone());
                }
            }
        }
        Ok(comparable)
    }

    pub fn compare_default_branch(&self) -> Option<String> {
        graph::default_base(&self.sync_repo.to_thread_local()).map(|(name, _)| name)
    }

    pub fn get_compare_diff(
        &self,
        merge_base_oid: String,
        head_oid: String,
        file: CompareFile,
    ) -> Result<Vec<DiffRow>, GitCraftError> {
        let head = compare_file_args(&merge_base_oid, &head_oid, &file)?;
        diff::compare_file_diff(&self.path, &merge_base_oid, head, &file)
    }

    pub fn get_compare_file_contents(
        &self,
        merge_base_oid: String,
        head_oid: String,
        file: CompareFile,
    ) -> Result<FileContentPair, GitCraftError> {
        let head = compare_file_args(&merge_base_oid, &head_oid, &file)?;
        diff::compare_file_content_pair(&self.path, &self.sync_repo, &merge_base_oid, head, &file)
    }
}

fn has_attached_head(repo: &Path) -> Result<bool, GitCraftError> {
    let result = git_cli::run_status(repo, &["symbolic-ref", "-q", "HEAD"])?;
    match result.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err(GitCraftError::message(result.stderr.trim())),
    }
}

fn resolve(repo: &Path, name: &str) -> Result<String, GitCraftError> {
    let revision = format!("{name}^{{commit}}");
    let result = git_cli::run_status(
        repo,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            "--end-of-options",
            &revision,
        ],
    )?;
    match result.status.code() {
        Some(0) => Ok(result.stdout.trim().into()),
        Some(1) => Err(GitCraftError::UnknownCompareRef { name: name.into() }),
        _ => Err(GitCraftError::message(result.stderr.trim())),
    }
}

fn merge_base(repo: &Path, left: &str, right: &str) -> Result<Option<String>, GitCraftError> {
    let result = git_cli::run_status(repo, &["merge-base", left, right])?;
    match result.status.code() {
        Some(0) => Ok(Some(result.stdout.trim().into())),
        Some(1) => Ok(None),
        _ => Err(GitCraftError::message(result.stderr.trim())),
    }
}

fn parse_files(raw: &str) -> Result<Vec<CompareFile>, GitCraftError> {
    let mut fields = raw.split_terminator('\0');
    let mut files = Vec::new();
    let invalid = || GitCraftError::message("Git returned an invalid comparison file list.");
    while let Some(status) = fields.next() {
        let status = status.get(..1).ok_or_else(invalid)?;
        let first_path = fields.next().ok_or_else(invalid)?;
        let (path, old_path) = if matches!(status, "R" | "C") {
            (fields.next().ok_or_else(invalid)?, Some(first_path.into()))
        } else {
            (first_path, None)
        };
        files.push(CompareFile {
            path: path.into(),
            old_path,
            status: status.into(),
        });
    }
    Ok(files)
}

fn validate_oid(oid: &str) -> Result<(), GitCraftError> {
    if matches!(oid.len(), 40 | 64) && oid.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(GitCraftError::message(
            "Expected a full comparison commit ID.",
        ))
    }
}

fn compare_file_args<'a>(
    base: &str,
    head: &'a str,
    file: &CompareFile,
) -> Result<Option<&'a str>, GitCraftError> {
    validate_oid(base)?;
    for path in std::iter::once(file.path.as_str()).chain(file.old_path.as_deref()) {
        if path
            .split('/')
            .any(|part| matches!(part, "" | "." | ".." | ".git"))
        {
            return Err(GitCraftError::message(
                "Expected a repository-relative file path.",
            ));
        }
    }
    if head == WORKTREE {
        Ok(None)
    } else {
        validate_oid(head)?;
        Ok(Some(head))
    }
}
