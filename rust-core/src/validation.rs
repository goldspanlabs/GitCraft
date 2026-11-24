use std::path::Path;

use crate::{git_cli, GitCraftError};

/// Resolves the default remote (`origin` if configured, otherwise the first remote, else `"origin"`).
pub(crate) fn resolve_default_remote(repo: &Path) -> String {
    if let Ok(output) = git_cli::run(repo, &["remote"]) {
        let remotes: Vec<&str> = output
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect();
        if remotes.contains(&"origin") {
            return "origin".to_owned();
        }
        if let Some(&first) = remotes.first() {
            return first.to_owned();
        }
    }
    "origin".to_owned()
}

/// Builds a root-anchored gitignore pattern for a literal path.
pub(crate) fn ignore_rule(path: &str) -> String {
    let trimmed = path.trim_start_matches("./").trim_start_matches('/');
    let mut rule = String::from("/");
    for (i, c) in trimmed.chars().enumerate() {
        let needs_escape =
            matches!(c, '*' | '?' | '[' | '\\') || (i == 0 && matches!(c, '#' | '!'));
        if needs_escape {
            rule.push('\\');
        }
        rule.push(c);
    }
    // Trailing spaces are significant only when escaped.
    if rule.ends_with(' ') {
        rule.pop();
        rule.push_str("\\ ");
    }
    rule
}

/// True when `full_ref` (e.g. `refs/heads/main`) exists.
pub(crate) fn ref_exists(repo: &Path, full_ref: &str) -> bool {
    git_cli::run(repo, &["show-ref", "--verify", "-q", full_ref]).is_ok()
}

/// True when HEAD resolves to a commit (false in a repository with no commits yet).
pub(crate) fn has_head(repo: &Path) -> bool {
    git_cli::run(repo, &["rev-parse", "--verify", "-q", "HEAD"]).is_ok()
}

/// Trims an optional message and collapses blank strings to `None`.
pub(crate) fn trim_optional_text(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// Shared argument sanitizer: trims whitespace and rejects empty or flag-like (`-...`) values.
fn validate_cli_arg(
    value: &str,
    empty_msg: &str,
    dash_msg: impl FnOnce(&str) -> String,
) -> Result<String, GitCraftError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(GitCraftError::message(empty_msg));
    }
    if value.starts_with('-') {
        return Err(GitCraftError::message(dash_msg(value)));
    }
    Ok(value.to_owned())
}

/// Trims a branch/tag/revision argument and rejects empty values or ones git would
/// parse as command-line options (e.g. a branch named `--force`).
pub(crate) fn validate_ref_arg(value: &str) -> Result<String, GitCraftError> {
    validate_cli_arg(value, "name must not be empty", |v| {
        format!("invalid name \"{v}\": it must not start with \"-\"")
    })
}

/// Trims a remote name/URL and rejects empty values or ones git would parse as options.
pub(crate) fn validate_remote_arg(value: &str) -> Result<String, GitCraftError> {
    validate_cli_arg(value, "remote name and URL must not be empty", |v| {
        format!("invalid remote value \"{v}\"")
    })
}

/// Formats a ref or full commit SHA for user-facing messages: 40-char hex SHAs are
/// shortened to 7 characters, while branch/tag names are preserved intact.
pub(crate) fn format_ref_display(value: &str) -> &str {
    if value.len() == 40 && value.bytes().all(|b| b.is_ascii_hexdigit()) {
        &value[..7]
    } else {
        value
    }
}
