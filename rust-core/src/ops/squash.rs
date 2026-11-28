use std::{collections::HashSet, ffi::OsString, os::unix::ffi::OsStringExt};

use gix::bstr::ByteSlice;

use crate::{
    git_cli, graph::extract_commit_metadata, GitCraftError, HeadMove, HeadPosition, RepoSession,
    SquashCommit, SquashPreview, SquashResult,
};

const BRANCH_MOVED: &str = "The branch has changed since then. Select the commits again.";

/// The commits of an allowed squash.
struct Chain {
    /// The selected commits, oldest first.
    selected: Vec<gix::ObjectId>,
    /// The commits between the selection and HEAD, oldest first.
    above: Vec<gix::ObjectId>,
    /// The parent of the oldest selected commit; none when that is the first commit.
    base: Option<gix::ObjectId>,
}

impl RepoSession {
    /// Whether the commits `oids` can be squashed into one, and what that would combine.
    /// A refusal is a warning whose text says why.
    pub fn squash_preview(&self, oids: Vec<String>) -> Result<SquashPreview, GitCraftError> {
        let (head, chain) = self.squash_chain(&oids)?;
        let repo = self.sync_repo.to_thread_local();
        let commits = chain
            .selected
            .iter()
            .map(|id| {
                let commit = repo.find_commit(*id).map_err(GitCraftError::from_display)?;
                let meta = extract_commit_metadata(&commit, true);
                let oid_hex = id.to_string();
                Ok(SquashCommit {
                    short_oid: oid_hex[..7].to_owned(),
                    oid_hex,
                    summary: meta.summary,
                    body: meta.body,
                    author_name: meta.author_name,
                    author_email: meta.author_email,
                })
            })
            .collect::<Result<Vec<_>, GitCraftError>>()?;
        // The oldest commit is an ancestor of the rest, so it is on a remote if any of them is.
        let containing = git_cli::run(
            &self.path,
            &[
                "for-each-ref",
                "--count=1",
                "--contains",
                &commits[0].oid_hex,
                "refs/remotes",
            ],
        )?;
        Ok(SquashPreview {
            commits,
            head,
            is_pushed: !containing.trim().is_empty(),
        })
    }

    /// Combines the consecutive commits `oids` into one with `message`, and re-creates the
    /// commits above it. The final tree doesn't change, so neither the index nor any file is
    /// touched. Refuses if HEAD is no longer at `expected`.
    pub fn squash_commits(
        &self,
        oids: Vec<String>,
        message: String,
        expected: HeadPosition,
    ) -> Result<SquashResult, GitCraftError> {
        let message = message.trim_end();
        if message.trim().is_empty() {
            return Err(GitCraftError::message("Enter a commit message"));
        }
        self.combine_commits(oids, Some(format!("{message}\n").into_bytes()), expected)
    }

    /// Fixup preserves the oldest selected commit's raw message, including whitespace and
    /// encoding. Display metadata is deliberately never used to reconstruct it.
    pub fn fixup_commits(
        &self,
        oids: Vec<String>,
        expected: HeadPosition,
    ) -> Result<SquashResult, GitCraftError> {
        self.combine_commits(oids, None, expected)
    }

    fn combine_commits(
        &self,
        oids: Vec<String>,
        message: Option<Vec<u8>>,
        expected: HeadPosition,
    ) -> Result<SquashResult, GitCraftError> {
        self.with_mutation_lock(|| {
            if self.head_position().as_ref() != Some(&expected) {
                return Err(GitCraftError::message(BRANCH_MOVED));
            }
            let (head, chain) = self.squash_chain(&oids)?;
            // The chain reads HEAD again: it must still be what was confirmed, which also pins
            // the branch update below to that commit.
            if head != expected {
                return Err(GitCraftError::message(BRANCH_MOVED));
            }
            let Some(branch) = head.branch.as_deref() else {
                return Err(GitCraftError::message(BRANCH_MOVED));
            };
            let sign = git_cli::run(&self.path, &["config", "--bool", "commit.gpgsign"])
                .is_ok_and(|value| value.trim() == "true");

            let operation = if message.is_some() { "squash" } else { "fixup" };
            let newest = *chain.selected.last().expect("at least two commits");
            let mut squashed =
                self.rewrite_commit(chain.selected[0], newest, chain.base, message, sign)?;
            let squashed_oid = squashed.to_string();
            for &id in &chain.above {
                squashed = self.rewrite_commit(id, id, Some(squashed), None, sign)?;
            }
            let tip = squashed.to_string();

            // Moves the branch only if it is still where it was read.
            let reason = format!("{operation}: {} commits", chain.selected.len());
            git_cli::mutate(
                &self.path,
                &["update-ref", "-m", &reason, branch, &tip, &head.oid],
            )
            .map_err(|error| {
                if self.head_position().as_ref() == Some(&head) {
                    error
                } else {
                    GitCraftError::message(BRANCH_MOVED)
                }
            })?;
            let after = HeadPosition {
                oid: tip,
                branch: head.branch.clone(),
            };
            Ok(SquashResult {
                head_move: HeadMove {
                    before: head,
                    after,
                },
                squashed_oid,
            })
        })
    }

    /// Creates a commit with `source`'s author, the tree of `tree_of` and `parent`. The message
    /// is `message`, or else `source`'s own, byte for byte. The committer is the current user.
    fn rewrite_commit(
        &self,
        source: gix::ObjectId,
        tree_of: gix::ObjectId,
        parent: Option<gix::ObjectId>,
        message: Option<Vec<u8>>,
        sign: bool,
    ) -> Result<gix::ObjectId, GitCraftError> {
        let repo = self.sync_repo.to_thread_local();
        let tree = repo
            .find_commit(tree_of)
            .map_err(GitCraftError::from_display)?
            .tree_id()
            .map_err(GitCraftError::from_display)?
            .to_string();
        let commit = repo
            .find_commit(source)
            .map_err(GitCraftError::from_display)?;
        let author = commit.author().map_err(GitCraftError::from_display)?;
        let bytes = |value: &[u8]| OsString::from_vec(value.to_vec());
        let env = [
            ("GIT_AUTHOR_NAME", bytes(author.name.as_bytes())),
            ("GIT_AUTHOR_EMAIL", bytes(author.email.as_bytes())),
            (
                "GIT_AUTHOR_DATE",
                OsString::from(format!("@{}", author.time)),
            ),
        ];

        // A kept message stays in the encoding it was written in; a new one is UTF-8.
        let encoding = if message.is_none() {
            commit
                .decode()
                .map_err(GitCraftError::from_display)?
                .encoding
                .map(|e| e.to_str_lossy().into_owned())
        } else {
            None
        };
        let encoding = format!(
            "i18n.commitEncoding={}",
            encoding.as_deref().unwrap_or("UTF-8")
        );
        // The source's own author line and message, as bytes, for checking what git wrote.
        let (author_line, own_message) = commit_parts(&commit.data);
        let author_line = author_line.to_vec();
        let message = message.unwrap_or_else(|| own_message.to_vec());

        let parent = parent.map(|p| p.to_string());
        let mut args = vec!["-c", encoding.as_str(), "commit-tree", tree.as_str()];
        if let Some(parent) = &parent {
            args.extend(["-p", parent.as_str()]);
        }
        if sign {
            args.push("-S");
        }
        let oid = git_cli::mutate_with(&self.path, &args, &env, message.clone())?;
        let oid = parse_oid(&oid)?;
        self.keep_exact(source, oid, &author_line, &message, sign)
    }

    /// `commit-tree` tidies some author names and converts a message that isn't valid UTF-8.
    /// If it changed either, writes the commit again with the original bytes. A signed commit
    /// can't be edited like that, so then the squash is refused.
    fn keep_exact(
        &self,
        source: gix::ObjectId,
        written: gix::ObjectId,
        author_line: &[u8],
        message: &[u8],
        signed: bool,
    ) -> Result<gix::ObjectId, GitCraftError> {
        let repo = self.sync_repo.to_thread_local();
        let commit = repo
            .find_commit(written)
            .map_err(GitCraftError::from_display)?;
        let (written_author, written_message) = commit_parts(&commit.data);
        if written_author == author_line && written_message == message {
            return Ok(written);
        }
        if signed {
            return Err(GitCraftError::message(format!(
                "Commit {} can't be signed without changing its author or message. \
                 Turn off commit signing to squash.",
                &source.to_string()[..7]
            )));
        }
        let headers = &commit.data[..commit.data.len() - written_message.len() - 2];
        let mut object = Vec::new();
        for line in headers.split(|byte| *byte == b'\n') {
            object.extend_from_slice(if line.starts_with(b"author ") {
                author_line
            } else {
                line
            });
            object.push(b'\n');
        }
        object.push(b'\n');
        object.extend_from_slice(message);
        let args = ["hash-object", "-t", "commit", "-w", "--stdin"];
        parse_oid(&git_cli::mutate_with(&self.path, &args, &[], object)?)
    }

    /// Checks that `oids` can be squashed and puts them in history order. The rules are checked
    /// in a fixed order, and the first that fails gives the reason.
    fn squash_chain(&self, oids: &[String]) -> Result<(HeadPosition, Chain), GitCraftError> {
        let refuse = |reason: &str| Err(GitCraftError::warning(reason));
        let mut wanted = HashSet::new();
        for oid in oids {
            wanted.insert(
                gix::ObjectId::from_hex(oid.trim().as_bytes())
                    .map_err(GitCraftError::from_display)?,
            );
        }
        if wanted.len() < 2 {
            return refuse("Select at least two commits");
        }
        let Some(head) = self.head_position().filter(|h| h.branch.is_some()) else {
            return refuse("Check out a branch to squash commits");
        };
        let status = self.status()?;
        if status.is_merging
            || status.is_rebasing
            || status.is_cherry_picking
            || status.is_reverting
            || status.has_conflicts
        {
            return refuse("Finish the current operation first");
        }

        let repo = self.sync_repo.to_thread_local();
        let shallow: HashSet<gix::ObjectId> =
            std::fs::read_to_string(repo.common_dir().join("shallow"))
                .unwrap_or_default()
                .lines()
                .filter_map(|line| gix::ObjectId::from_hex(line.trim().as_bytes()).ok())
                .collect();

        // Down HEAD's first parents until every selected commit has turned up.
        let mut line: Vec<(gix::ObjectId, Vec<gix::ObjectId>)> = Vec::new();
        let mut found = Vec::new();
        let mut next = Some(
            gix::ObjectId::from_hex(head.oid.as_bytes()).map_err(GitCraftError::from_display)?,
        );
        while found.len() < wanted.len() {
            let Some(id) = next else {
                return refuse("Select commits on the current branch");
            };
            let commit = repo.find_commit(id).map_err(GitCraftError::from_display)?;
            let parents: Vec<gix::ObjectId> = commit.parent_ids().map(|p| p.detach()).collect();
            if wanted.contains(&id) {
                found.push(line.len());
            }
            // A shallow clone names parents it doesn't have.
            next = parents.first().copied().filter(|_| !shallow.contains(&id));
            line.push((id, parents));
        }

        let newest = found[0];
        let oldest = line.len() - 1;
        if oldest - newest + 1 != wanted.len() {
            return refuse("Select consecutive commits");
        }
        if line.iter().any(|(_, parents)| parents.len() > 1) {
            return refuse("Can't squash across a merge commit");
        }
        let (oldest_id, oldest_parents) = &line[oldest];
        if shallow.contains(oldest_id) {
            return refuse("History is incomplete in this shallow clone");
        }
        let base = oldest_parents.first().copied();

        let tree_of = |id: gix::ObjectId| -> Result<gix::ObjectId, GitCraftError> {
            let commit = repo.find_commit(id).map_err(GitCraftError::from_display)?;
            let tree = commit.tree_id().map_err(GitCraftError::from_display)?;
            Ok(tree.detach())
        };
        let base_tree = match base {
            Some(base) => tree_of(base)?,
            None => gix::ObjectId::empty_tree(repo.object_hash()),
        };
        if tree_of(line[newest].0)? == base_tree {
            return refuse("These commits cancel each other out");
        }

        let ids = |range: &[(gix::ObjectId, Vec<gix::ObjectId>)]| {
            range.iter().rev().map(|(id, _)| *id).collect::<Vec<_>>()
        };
        Ok((
            head,
            Chain {
                selected: ids(&line[newest..]),
                above: ids(&line[..newest]),
                base,
            },
        ))
    }
}

/// A raw commit object's `author` header line and its message.
fn commit_parts(data: &[u8]) -> (&[u8], &[u8]) {
    let end = data
        .windows(2)
        .position(|pair| pair == b"\n\n")
        .unwrap_or(data.len());
    let author = data[..end]
        .split(|byte| *byte == b'\n')
        .find(|line| line.starts_with(b"author "))
        .unwrap_or_default();
    (author, data.get(end + 2..).unwrap_or_default())
}

fn parse_oid(output: &str) -> Result<gix::ObjectId, GitCraftError> {
    gix::ObjectId::from_hex(output.trim().as_bytes()).map_err(GitCraftError::from_display)
}
