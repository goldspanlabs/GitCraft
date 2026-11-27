use std::io;

#[derive(Debug, thiserror::Error)]
pub enum GitCraftError {
    #[error("{msg}")]
    Message { msg: String },
    /// The operation didn't fail, but there's nothing for it to do; shown as a warning.
    #[error("{msg}")]
    Warning { msg: String },
    /// The `git` executable could not be found in PATH or standard macOS locations.
    #[error("Git is not installed or could not be found.")]
    GitNotFound,
}

impl GitCraftError {
    pub fn message(msg: impl Into<String>) -> Self {
        Self::Message { msg: msg.into() }
    }

    pub fn warning(msg: impl Into<String>) -> Self {
        Self::Warning { msg: msg.into() }
    }

    /// An error whose message is `err`'s text, for `map_err` on gix and other library errors.
    pub fn from_display(err: impl std::fmt::Display) -> Self {
        Self::message(err.to_string())
    }
}

impl From<io::Error> for GitCraftError {
    fn from(err: io::Error) -> Self {
        Self::Message {
            msg: err.to_string(),
        }
    }
}

/// Whether the `git` CLI is usable on this system.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GitAvailability {
    Available,
    Missing,
    /// macOS `/usr/bin/git` shim is present, but Xcode Command Line Tools are not installed.
    NeedsCommandLineTools,
    /// Git runs but is older than the minimum version.
    Outdated,
}

/// Order in which the commit graph lists commits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommitSort {
    /// Newest commit time first (the default).
    ByDate,
    /// Children before parents without interleaving separate lines of history.
    Topological,
}

impl CommitSort {
    /// The value kept in an atomic, as read back by [`CommitSort::from_u8`].
    pub(crate) fn to_u8(self) -> u8 {
        match self {
            CommitSort::ByDate => 0,
            CommitSort::Topological => 1,
        }
    }

    pub(crate) fn from_u8(value: u8) -> Self {
        match value {
            1 => CommitSort::Topological,
            _ => CommitSort::ByDate,
        }
    }
}

/// How `pull` reconciles diverged branches.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PullStrategy {
    /// Follow the repository's git config (`pull.rebase` / `pull.ff`); when neither is
    /// set, merge, as git did before it started asking.
    GitConfig,
    Merge,
    Rebase,
    /// Refuse to create a merge commit or rewrite history; fail if branches diverged.
    FastForwardOnly,
}

/// How `merge_commit` joins a commit to the checked-out branch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MergeType {
    /// Fast-forward when the history allows it, otherwise create a merge commit.
    Default,
    /// Always create a merge commit.
    NoFastForward,
    /// Refuse unless the branch can fast-forward.
    FastForwardOnly,
    /// Stage the combined changes without committing; the user commits them.
    Squash,
}

/// How far `reset_to` moves the branch and what happens to the working tree.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResetMode {
    /// Move the branch; keep all changes staged.
    Soft,
    /// Move the branch; keep changes in the working tree, unstaged.
    Mixed,
    /// Move the branch and discard all uncommitted changes.
    Hard,
    /// Move the branch and update the files that differ between the two commits, keeping
    /// other local changes. Refuses when a local change is in one of those files.
    Keep,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RefKind {
    LocalBranch,
    RemoteBranch,
    Tag,
    Head,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RefBadge {
    pub name: String,
    pub kind: RefKind,
    pub is_current: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GraphEdge {
    pub from_lane: u32,
    pub to_lane: u32,
    pub is_merge: bool,
    pub color_idx: u8,
}

#[derive(Clone, Debug)]
pub struct StyleSpan {
    pub start_utf16: u32,
    pub len_utf16: u32,
    pub foreground: String,
}

#[derive(Clone, Debug)]
pub struct DiffRow {
    pub kind: String,
    pub text: String,
    pub old_line: Option<u32>,
    pub new_line: Option<u32>,
    pub spans: Vec<StyleSpan>,
}

impl DiffRow {
    /// Constructs a metadata row (header, hunk, notice) with no line numbers or spans.
    pub(crate) fn meta(kind: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            kind: kind.into(),
            text: text.into(),
            old_line: None,
            new_line: None,
            spans: Vec::new(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct FileChange {
    pub path: String,
    pub status: String,
    pub staged: bool,
}

#[derive(Clone, Debug)]
pub struct CommitRow {
    pub oid_hex: String,
    pub short_oid: String,
    pub summary: String,
    pub author_name: String,
    pub author_email: String,
    pub timestamp: i64,
    pub lane: u32,
    pub color_idx: u8,
    pub max_lanes: u32,
    pub edges: Vec<GraphEdge>,
    pub refs: Vec<RefBadge>,
    pub is_remote_only: bool,
    /// On the checked-out branch and not contained in any remote branch.
    pub is_unpushed: bool,
}

#[derive(Clone, Debug)]
pub struct CommitDetail {
    pub oid_hex: String,
    pub short_oid: String,
    pub summary: String,
    pub body: String,
    pub author_name: String,
    pub author_email: String,
    pub timestamp: i64,
    pub parent_oids: Vec<String>,
    pub files: Vec<FileChange>,
}

#[derive(Clone, Debug)]
pub struct BranchInfo {
    pub name: String,
    pub full_ref: String,
    pub is_remote: bool,
    pub is_head: bool,
    pub target_oid_hex: String,
    pub ahead: u32,
    pub behind: u32,
    pub is_merged: bool,
    /// The local branch pinned to the top of the sidebar: origin's default branch, else main or master.
    pub is_default: bool,
}

#[derive(Clone, Debug)]
pub struct TagInfo {
    pub name: String,
    pub full_ref: String,
    pub target_oid_hex: String,
    pub created_timestamp: i64,
}

#[derive(Clone, Debug)]
pub struct RemoteInfo {
    pub name: String,
    pub fetch_url: String,
    pub push_url: String,
}

/// Where HEAD points: its commit and the checked-out branch, if any. An undo checks that
/// HEAD is still here before moving it back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HeadPosition {
    pub oid: String,
    /// The branch's full ref, such as `refs/heads/main`; nil when HEAD is detached.
    pub branch: Option<String>,
}

#[derive(Clone, Debug)]
pub struct StashInfo {
    pub index: u32,
    pub name: String,
    pub message: String,
}

#[derive(Clone, Debug)]
pub struct RepoStatus {
    pub files: Vec<String>,
    pub staged_files: Vec<FileChange>,
    pub unstaged_files: Vec<FileChange>,
    pub branch: String,
    pub is_clean: bool,
    pub is_merging: bool,
    pub is_rebasing: bool,
    /// A cherry-pick stopped partway, usually on a conflict (`CHERRY_PICK_HEAD` exists).
    pub is_cherry_picking: bool,
    /// A revert stopped partway, usually on a conflict (`REVERT_HEAD` exists).
    pub is_reverting: bool,
    pub has_conflicts: bool,
}
