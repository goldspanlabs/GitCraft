use std::path::{Path, PathBuf};

use crate::{
    git_cli,
    validation::{trim_optional_text, validate_ref_arg, validate_remote_arg},
    GitCraftError,
};

/// Initializes a new local Git repository at `path`.
pub fn init_repository(path: String, initial_branch: Option<String>) -> Result<(), GitCraftError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(GitCraftError::message("destination path must not be empty"));
    }
    let target = PathBuf::from(trimmed);
    if target.join(".git").exists() {
        return Err(GitCraftError::message(
            "a Git repository already exists at that location",
        ));
    }
    if !target.exists() {
        std::fs::create_dir_all(&target)
            .map_err(|e| GitCraftError::message(format!("unable to create folder: {e}")))?;
    }

    let branch = match trim_optional_text(initial_branch.as_deref()) {
        Some(name) => Some(validate_ref_arg(&name)?),
        None => None,
    };

    match branch.as_deref() {
        Some(name) => git_cli::mutate(&target, &["init", "-b", name])?,
        None => git_cli::mutate(&target, &["init"])?,
    }
    Ok(())
}

/// Clones a remote repository from `url` into `destination`.
pub fn clone_repository(url: String, destination: String) -> Result<(), GitCraftError> {
    let url = validate_remote_arg(&url)?;
    let dest = destination.trim();
    if dest.is_empty() {
        return Err(GitCraftError::message("destination path must not be empty"));
    }
    let dest_path = Path::new(dest);
    let working_dir = dest_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("/"));
    if !working_dir.exists() {
        std::fs::create_dir_all(working_dir)
            .map_err(|e| GitCraftError::message(format!("unable to create parent folder: {e}")))?;
    }

    git_cli::mutate(working_dir, &["clone", "--", &url, dest])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RepoSession;

    #[test]
    fn init_repository_creates_repo_and_rejects_existing() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("new-repo");

        init_repository(target.to_string_lossy().into_owned(), Some("main".into())).unwrap();
        assert!(target.join(".git").exists());

        let session = RepoSession::open(&target).unwrap();
        let status = session.status().unwrap();
        assert_eq!(status.branch, "main");

        let err = init_repository(target.to_string_lossy().into_owned(), None).unwrap_err();
        assert!(err.to_string().contains("already exists"));
    }

    #[test]
    fn clone_repository_clones_local_repo_and_rejects_flag_url() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        init_repository(source.to_string_lossy().into_owned(), Some("main".into())).unwrap();
        std::fs::write(source.join("README.md"), "hello\n").unwrap();
        git_cli::mutate(&source, &["config", "user.name", "Tester"]).unwrap();
        git_cli::mutate(&source, &["config", "user.email", "tester@example.com"]).unwrap();
        git_cli::mutate(&source, &["add", "README.md"]).unwrap();
        git_cli::mutate(&source, &["commit", "-m", "Initial commit"]).unwrap();

        let dest = dir.path().join("cloned");
        clone_repository(
            source.to_string_lossy().into_owned(),
            dest.to_string_lossy().into_owned(),
        )
        .unwrap();
        assert!(dest.join(".git").exists());
        assert!(dest.join("README.md").exists());

        let err = clone_repository(
            "--upload-pack=evil".into(),
            dest.to_string_lossy().into_owned(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("invalid remote value"));
    }
}
