//! Core, platform-independent building blocks for GitCraft.
pub mod diff;
pub mod git_cli;
pub mod graph;
pub mod highlight;
pub mod watcher;

pub use diff::{parse_unified_diff, DiffLine, DiffLineKind, FileDiff};
pub use graph::{CommitGraph, CommitNode};
