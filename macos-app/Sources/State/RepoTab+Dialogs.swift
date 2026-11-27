import Foundation

// The sheets a tab can show and the destructive actions it asks to confirm, with their text.
extension RepoTab {
    enum WorktreeSource: Equatable {
        case head
        case localBranch(name: String, isCheckedOut: Bool)
        case remoteBranch(name: String)
        case commit(oid: String)

        var id: String {
            switch self {
            case .head: return "head"
            case let .localBranch(name, isCheckedOut): return "local-\(name)-\(isCheckedOut)"
            case let .remoteBranch(name): return "remote-\(name)"
            case let .commit(oid): return "commit-\(oid)"
            }
        }
    }

    enum ActiveSheet: Identifiable {
        case newBranch(startPoint: String?)
        case newWorktree(source: WorktreeSource)
        case checkoutCommit(oid: String)
        case mergeCommit(oid: String)
        case newTag(target: String?)
        case squash(SquashPreview)
        case forcePush(ForcePushPlan)
        case newStash
        case addRemote
        case editRemote(RemoteInfo)

        var id: String {
            switch self {
            case let .newBranch(startPoint): return "new-branch-\(startPoint ?? "head")"
            case let .newWorktree(source): return "new-worktree-\(source.id)"
            case let .checkoutCommit(oid): return "checkout-commit-\(oid)"
            case let .mergeCommit(oid): return "merge-commit-\(oid)"
            case let .newTag(target): return "new-tag-\(target ?? "head")"
            case let .squash(preview):
                return "squash-\(preview.head.oid)-\(preview.commits.map(\.oidHex).joined(separator: "-"))"
            case let .forcePush(plan):
                return "force-push-\(plan.destination)-\(plan.expectedRemoteOid)-\(plan.head.oid)"
            case .newStash: return "new-stash"
            case .addRemote: return "add-remote"
            case let .editRemote(remote): return "edit-remote-\(remote.name)"
            }
        }
    }

    enum DestructiveAction: Identifiable {
        case discardFile(path: String)
        case deleteBranch(name: String, force: Bool)
        case forceDeleteBranch(name: String)
        case deleteRemoteBranch(name: String)
        case removeRemote(name: String)
        case deleteTag(name: String, deleteRemote: Bool)
        case removeWorktree(path: String, label: String, isActive: Bool)
        case forceRemoveWorktree(path: String, label: String, isActive: Bool)
        case abortMerge
        case abortRebase
        case abortCherryPick
        case abortRevert
        case dropStash(index: UInt32, name: String)
        case resetHard(branch: String, commit: String)
        case rebase(branch: String, commit: String)

        var id: String {
            switch self {
            case let .discardFile(path): return "discard-\(path)"
            case let .deleteBranch(name, force): return "del-branch-\(name)-\(force)"
            case let .forceDeleteBranch(name): return "force-del-branch-\(name)"
            case let .deleteRemoteBranch(name): return "del-remote-branch-\(name)"
            case let .removeRemote(name): return "remove-remote-\(name)"
            case let .deleteTag(name, remote): return "del-tag-\(name)-\(remote)"
            case let .removeWorktree(path, _, _): return "remove-worktree-\(path)"
            case let .forceRemoveWorktree(path, _, _): return "force-remove-worktree-\(path)"
            case .abortMerge: return "abort-merge"
            case .abortRebase: return "abort-rebase"
            case .abortCherryPick: return "abort-cherry-pick"
            case .abortRevert: return "abort-revert"
            case let .dropStash(index, _): return "drop-stash-\(index)"
            case let .resetHard(_, commit): return "reset-hard-\(commit)"
            case let .rebase(_, commit): return "rebase-\(commit)"
            }
        }

        var title: String {
            switch self {
            case let .discardFile(path): return "Discard changes to \"\(path)\"?"
            case let .deleteBranch(name, _): return "Delete branch \"\(name)\"?"
            case let .forceDeleteBranch(name): return "Branch \"\(name)\" isn't merged"
            case let .deleteRemoteBranch(name): return "Delete remote branch \"\(name)\"?"
            case let .removeRemote(name): return "Remove remote \"\(name)\"?"
            case let .deleteTag(name, remote):
                return remote ? "Delete tag \"\(name)\" locally and from remote?" : "Delete local tag \"\(name)\"?"
            case let .removeWorktree(_, label, _): return "Remove worktree \"\(label)\"?"
            case let .forceRemoveWorktree(_, label, _): return "Worktree \"\(label)\" has uncommitted changes"
            case .abortMerge: return "Abort in-progress merge?"
            case .abortRebase: return "Abort in-progress rebase?"
            case .abortCherryPick: return "Abort in-progress cherry-pick?"
            case .abortRevert: return "Abort in-progress revert?"
            case let .dropStash(_, name): return "Drop \"\(name)\"?"
            case let .resetHard(branch, commit): return "Reset \"\(branch)\" to \(commit.shortOid) and discard changes?"
            case let .rebase(branch, commit): return "Rebase \"\(branch)\" onto \(commit.shortOid)?"
            }
        }

        var message: String {
            switch self {
            case .discardFile:
                return "This will permanently revert your uncommitted changes to this file."
            case .deleteBranch:
                return "This will delete the local branch reference."
            case .forceDeleteBranch:
                return "It has commits that aren't in the checked-out branch. Deleting it removes the branch name, and those commits are lost unless they exist elsewhere. Git can often recover them from the reflog for a while."
            case .deleteRemoteBranch:
                return "This will delete the branch from the remote repository. The local branch of the same name, if any, is kept."
            case .removeRemote:
                return "This removes the remote and its remote-tracking branches from this repository. Local branches are kept. Nothing is changed on the server."
            case let .deleteTag(_, remote):
                return remote
                    ? "This will delete the tag locally and push the deletion to the remote repository."
                    : "This will remove the tag from your local repository."
            case let .removeWorktree(path, _, isActive):
                if isActive {
                    return "This will delete \"\(path.abbreviatingWithTilde)\" from disk and switch this tab to another checkout of this repository. Committed history on its branch is kept."
                }
                return "This will delete \"\(path.abbreviatingWithTilde)\" from disk. Committed history on its branch is kept."
            case let .forceRemoveWorktree(path, _, isActive):
                if isActive {
                    return "Modified, staged, or untracked files in \"\(path.abbreviatingWithTilde)\" will be permanently deleted, and this tab will switch to another checkout of this repository. Uncommitted changes can't be recovered from GitCraft."
                }
                return "Modified, staged, or untracked files in \"\(path.abbreviatingWithTilde)\" will be permanently deleted. Uncommitted changes can't be recovered from GitCraft."
            case .abortMerge:
                return "This will abort the current merge and restore the repository to its pre-merge state."
            case .abortRebase:
                return "This will stop the rebase and put your branch and files back as they were before the rebase started."
            case .abortCherryPick:
                return "This will stop the cherry-pick and put your branch and files back as they were before it started."
            case .abortRevert:
                return "This will stop the revert and put your branch and files back as they were before it started."
            case .dropStash:
                return "The stashed changes will be removed. This can't be undone from GitCraft."
            case .rebase:
                return "This replays the commits on your branch on top of the selected commit and rewrites their IDs. If you have already pushed this branch, you will need to force push afterwards."
            case .resetHard:
                return "Uncommitted changes to tracked files will be discarded, and commits after this one will leave the branch. Discarded changes can't be recovered from GitCraft."
            }
        }

        var confirmLabel: String {
            switch self {
            case .discardFile: return "Discard"
            case .deleteBranch, .deleteRemoteBranch, .deleteTag: return "Delete"
            case .removeRemote: return "Remove"
            case .forceDeleteBranch: return "Force Delete"
            case .removeWorktree: return "Remove"
            case .forceRemoveWorktree: return "Force Remove"
            case .abortMerge: return "Abort Merge"
            case .abortRebase: return "Abort Rebase"
            case .abortCherryPick: return "Abort Cherry Pick"
            case .abortRevert: return "Abort Revert"
            case .dropStash: return "Drop"
            case .resetHard: return "Reset"
            case .rebase: return "Rebase"
            }
        }
    }
}

private extension String {
    /// The path with the home folder shown as `~`.
    var abbreviatingWithTilde: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}
