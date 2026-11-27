import AppKit

extension RepoTab {
    /// Applies a `LocalChangesHandling` strategy around an operation (checkout or branch creation),
    /// stashing and rolling back on error or discarding dirty files before running `operation`.
    nonisolated static func withLocalChanges(
        _ handling: LocalChangesHandling,
        hasChanges: Bool,
        stashMessage: String,
        session: RepoSession,
        operation: () throws -> Void
    ) throws {
        guard hasChanges else {
            try operation()
            return
        }
        switch handling {
        case .doNotChange:
            try operation()
        case .stashAndReapply:
            // `git stash push` succeeds without creating anything when there is nothing to
            // save (the tab's change list can be a moment stale). Popping then would apply and
            // drop an older stash the person kept, so only pop an entry this call created.
            let stashesBefore = try session.listStashes().count
            try session.stashPush(message: stashMessage, includeUntracked: true)
            let didStash = try session.listStashes().count > stashesBefore
            do {
                try operation()
            } catch {
                if didStash { try? session.stashPop(index: 0) }
                throw error
            }
            if didStash { try session.stashPop(index: 0) }
        case .discard:
            try session.discardAll()
            try operation()
        }
    }

    // MARK: - Working Tree & Staging

    /// Stages a file, or everything changed in a folder.
    func stagePath(_ path: String) {
        performMutation { try $0.stage(path: path) }
    }

    /// Unstages a file, or everything staged in a folder.
    func unstagePath(_ path: String) {
        performMutation { try $0.unstage(path: path) }
    }

    func stageAll() {
        performMutation { try $0.stageAll() }
    }

    func unstageAll() {
        performMutation { try $0.unstageAll() }
    }

    func discardFile(_ path: String) {
        performMutation { try $0.discardFile(path: path) }
    }

    func ignorePath(_ path: String, localOnly: Bool) {
        performMutation { try $0.ignorePath(path: path, localOnly: localOnly) }
    }

    // MARK: - Remotes

    /// Runs a remote mutation and reports success/failure to the caller (used by the
    /// remotes sheet so it can keep the form open on error).
    func addRemote(name: String, url: String, onSuccess: (@MainActor () -> Void)? = nil) {
        performMutation { try $0.addRemote(name: name, url: url) } onSuccess: { onSuccess?() }
    }

    /// Applies a URL change and/or rename in one mutation so the two steps stay ordered.
    func updateRemote(_ remote: RemoteInfo, newName: String, newURL: String) {
        let name = newName.trimmed
        let url = newURL.trimmed
        performMutation { session in
            if url != remote.fetchUrl || url != remote.pushUrl {
                try session.setRemoteUrl(name: remote.name, url: url)
            }
            if name != remote.name {
                try session.renameRemote(oldName: remote.name, newName: name)
            }
        }
    }

    func removeRemote(_ name: String) {
        performMutation { try $0.removeRemote(name: name) }
    }

    func fetchRemote(_ name: String) {
        let includeTags = GitPreferences.fetchIncludesTags
        performMutation(busyLabel: "Fetching \(name)…") {
            try $0.fetchRemote(name: name, includeTags: includeTags)
        }
    }

    func testRemoteConnection(url: String) async throws {
        let session = self.session
        try await Task.detached(priority: .userInitiated) {
            try session.testRemoteConnection(url: url)
        }.value
    }

    // MARK: - Commit & Amend

    /// Turns Amend on or off. Turning it on fills an empty message with HEAD's message.
    func setAmend(_ on: Bool) {
        amendCommit = on
        guard on, commitSummary.isEmpty, commitBody.isEmpty else { return }
        let session = self.session
        Task {
            guard let message = try? await Task.detached(operation: { try session.headCommitMessage() }).value,
                  // A read from a checkout the tab has since left must not fill the new composer.
                  self.session === session,
                  self.amendCommit, self.commitSummary.isEmpty, self.commitBody.isEmpty else { return }
            let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            self.commitSummary = String(lines.first ?? "")
            self.commitBody = lines.count > 1
                ? String(lines[1]).trimmed
                : ""
        }
    }

    /// Commits the staged changes. The Commit menu's "Commit and Push" item passes `pushAfter: true`.
    func commitChanges(pushAfter: Bool = false) {
        let summary = commitSummary.trimmed
        guard !summary.isEmpty else { return }
        let body = commitBody.trimmed
        let fullMessage = body.isEmpty ? summary : "\(summary)\n\n\(body)"
        // Hand-picked staging wins: auto-staging only fills in when nothing is staged.
        let autoStage = GitPreferences.shouldStageAll(
            autoStage: GitPreferences.autoStageOnCommit,
            stagedCount: stagedFiles.count
        )
        let skip = skipHooks
        let amend = amendCommit
        let moved = SendableBox<HeadMove?>(nil)
        // One mutation, so staging and committing happen together and the UI sees a single step.
        performMutation { session in
            if autoStage {
                try session.stageAll()
            }
            moved.value = try session.commitWithOptions(message: fullMessage, skipHooks: skip, amend: amend)
        } onSuccess: { [weak self] in
            guard let self else { return }
            self.commitSummary = ""
            self.commitBody = ""
            self.amendCommit = false
            self.skipHooks = false
            if let move = moved.value {
                self.recordUndo(
                    actionName: amend ? "Amend" : "Commit",
                    step: .moveHead(move, mode: .soft),
                    message: amend ? "Amended \"\(summary)\"." : "Committed \"\(summary)\"."
                )
            }
            if pushAfter {
                // Hop to the next run-loop turn so this mutation finishes (and clears
                // `isBusy`) before the push starts its own. After amending a pushed commit,
                // the push asks before forcing.
                DispatchQueue.main.async { self.runRemote(.push) }
            }
        }
    }

    // MARK: - Branches & History

    /// Detached checkout of `oid`, handling local changes the same way creating a branch does.
    func checkoutCommit(_ oid: String, localChanges: LocalChangesHandling = .doNotChange) {
        let hasLocalChanges = totalChangesCount > 0
        if localChanges == .doNotChange {
            performUndoableCheckout(
                actionName: "Checkout",
                message: "Checked out \(oid.shortOid)."
            ) {
                try $0.checkoutBranch(branchName: oid)
            }
            return
        }
        performMutation { session in
            try RepoTab.withLocalChanges(
                localChanges,
                hasChanges: hasLocalChanges,
                stashMessage: "Auto-stash before checking out \(oid.shortOid)",
                session: session
            ) {
                _ = try session.checkoutBranch(branchName: oid)
            }
        }
    }

    func checkoutBranch(_ branchName: String) {
        performUndoableCheckout(
            actionName: "Checkout",
            message: "Switched to \"\(branchName)\"."
        ) {
            try $0.checkoutBranch(branchName: branchName)
        }
    }

    func createBranch(
        name: String,
        startPoint: String?,
        checkout: Bool,
        localChanges: LocalChangesHandling = .doNotChange
    ) {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty else { return }
        if !checkout {
            performUndoableRefMove(
                actionName: "Create Branch",
                message: "Created branch \"\(trimmed)\"."
            ) {
                try $0.createBranch(branchName: trimmed, startPoint: startPoint, checkout: false)
            }
            return
        }
        let hasLocalChanges = totalChangesCount > 0
        performMutation { session in
            try RepoTab.withLocalChanges(
                localChanges,
                hasChanges: hasLocalChanges,
                stashMessage: "Auto-stash before creating \(trimmed)",
                session: session
            ) {
                _ = try session.createBranch(branchName: trimmed, startPoint: startPoint, checkout: checkout)
            }
        }
    }

    func deleteBranch(_ branchName: String, force: Bool) {
        performUndoableRefMove(
            actionName: "Delete Branch",
            message: "Deleted branch \"\(branchName)\".",
            onFailure: { [weak self] error in
                // A safe delete refused because the branch has unmerged commits: ask before forcing.
                guard !force, error.displayMessage.contains("is not fully merged") else { return false }
                self?.pendingConfirmation = .forceDeleteBranch(name: branchName)
                return true
            }
        ) {
            try $0.deleteBranch(branchName: branchName, force: force)
        }
    }

    func deleteRemoteBranch(_ branchName: String) {
        performMutation { try $0.deleteRemoteBranch(branchName: branchName) }
    }

    func fastForwardBranch(_ branchName: String) {
        performUndoableRefMove(
            actionName: "Fast-Forward",
            message: "Fast-forwarded \"\(branchName)\"."
        ) {
            try $0.fastForwardBranch(branchName: branchName)
        }
    }

    func mergeBranch(_ branchName: String) {
        performUndoableHeadMove(
            actionName: "Merge",
            message: "Merged \"\(branchName)\".",
            undoMode: .keep
        ) {
            try $0.mergeBranch(branchName: branchName)
        }
    }

    /// Merges `oid` into the checked-out branch, joined as `mergeType` says.
    func mergeCommit(_ oid: String, mergeType: MergeType) {
        performUndoableHeadMove(
            actionName: "Merge",
            message: "Merged \(oid.shortOid).",
            undoMode: .keep
        ) {
            try $0.mergeCommit(commit: oid, mergeType: mergeType)
        }
    }

    /// Whether merging `oid` would conflict, or nil if git couldn't say.
    func checkMergeConflicts(_ oid: String) async -> Bool? {
        let session = self.session
        return try? await Task.detached { try session.mergeHasConflicts(commit: oid) }.value
    }

    /// Rebasing rewrites the branch's commits, so it goes through the confirmation dialog.
    func requestRebase(onto oid: String) {
        pendingConfirmation = .rebase(branch: currentBranch, commit: oid)
    }

    func rebaseOnto(_ oid: String) {
        performUndoableHeadMove(
            actionName: "Rebase",
            message: "Rebased \"\(currentBranchLabel)\" onto \(oid.shortOid).",
            undoMode: .keep
        ) {
            try $0.rebaseOnto(commit: oid)
        }
    }

    /// Hard resets go through the confirmation dialog; soft and mixed resets run directly and
    /// can be undone.
    func resetTo(_ oid: String, mode: ResetMode) {
        switch mode {
        case .hard:
            pendingConfirmation = .resetHard(branch: currentBranch, commit: oid)
        case .soft, .mixed:
            let kept = mode == .soft ? "staged" : "unstaged"
            performUndoableHeadMove(
                actionName: "Reset",
                message: "Reset \"\(currentBranchLabel)\" to \(oid.shortOid). Its changes are \(kept).",
                undoMode: mode
            ) { try $0.resetTo(commit: oid, mode: mode) }
        case .keep:
            performReset(oid, mode: .keep)
        }
    }

    /// Runs the reset without asking again. The confirmed hard reset calls this directly,
    /// because `resetTo` would re-arm the dialog. It isn't undoable: the uncommitted changes
    /// it discards can't be brought back.
    private func performReset(_ oid: String, mode: ResetMode) {
        performMutation({ _ = try $0.resetTo(commit: oid, mode: mode) }, onSuccess: { [weak self] in
            // It may not move HEAD, but it changed files, so nothing undone can be redone.
            self?.redoStack.removeAll()
        })
    }

    func cherryPick(_ oid: String) {
        // Keep mode on undo: the picked changes go, other local changes stay.
        performUndoableHeadMove(
            actionName: "Cherry Pick",
            message: "Cherry-picked \(oid.shortOid) onto \"\(currentBranchLabel)\".",
            undoMode: .keep
        ) { try $0.cherryPick(commit: oid) }
    }

    func revertCommit(_ oid: String) {
        performUndoableHeadMove(
            actionName: "Revert",
            message: "Reverted \(oid.shortOid) on \"\(currentBranchLabel)\".",
            undoMode: .keep
        ) { try $0.revertCommit(commit: oid) }
    }

    func abortRebase() {
        performMutation { try $0.abortRebase() }
    }

    func continueRebase() {
        performMutation { try $0.continueRebase() }
    }

    func abortCherryPick() {
        performMutation { try $0.abortCherryPick() }
    }

    func continueCherryPick() {
        performMutation { try $0.continueCherryPick() }
    }

    func abortRevert() {
        performMutation { try $0.abortRevert() }
    }

    func continueRevert() {
        performMutation { try $0.continueRevert() }
    }

    func abortMerge() {
        performMutation { try $0.abortMerge() }
    }

    func executeConfirmed(_ action: DestructiveAction) {
        pendingConfirmation = nil
        switch action {
        case let .discardFile(path):
            discardFile(path)
        case let .deleteBranch(name, force):
            deleteBranch(name, force: force)
        case let .forceDeleteBranch(name):
            deleteBranch(name, force: true)
        case let .deleteRemoteBranch(name):
            deleteRemoteBranch(name)
        case let .removeRemote(name):
            removeRemote(name)
        case let .deleteTag(name, deleteRemote):
            deleteTag(name, deleteRemote: deleteRemote)
        case let .removeWorktree(path, label, _):
            removeWorktree(path: path, label: label, force: false)
        case let .forceRemoveWorktree(path, label, _):
            removeWorktree(path: path, label: label, force: true)
        case .abortMerge:
            abortMerge()
        case .abortRebase:
            abortRebase()
        case .abortCherryPick:
            abortCherryPick()
        case .abortRevert:
            abortRevert()
        case let .dropStash(index, _):
            stashDrop(index)
        case let .resetHard(_, commit):
            performReset(commit, mode: .hard)
        case let .rebase(_, commit):
            rebaseOnto(commit)
        }
    }

    // MARK: - Tags, Stashes & Sync

    func createTag(name: String, target: String?, message: String?, pushToRemote: Bool) {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty else { return }
        // The core trims the message and treats a blank one as none.
        performUndoableRefMove(
            actionName: "Create Tag",
            message: "Created tag \"\(trimmed)\"."
        ) {
            try $0.createTag(
                tagName: trimmed,
                target: target,
                message: message,
                pushToRemote: pushToRemote
            )
        }
    }

    func deleteTag(_ tagName: String, deleteRemote: Bool) {
        performUndoableRefMove(
            actionName: "Delete Tag",
            message: "Deleted tag \"\(tagName)\"."
        ) {
            try $0.deleteTag(tagName: tagName, deleteRemote: deleteRemote)
        }
    }

    func pushTag(_ tagName: String) {
        performMutation { try $0.pushTag(tagName: tagName) }
    }

    func stashPush(message: String?, includeUntracked: Bool) {
        // The core trims the message and treats a blank one as none.
        performMutation { try $0.stashPush(message: message, includeUntracked: includeUntracked) }
    }

    func stashApply(_ index: UInt32) {
        performMutation { try $0.stashApply(index: index) }
    }

    func stashPop(_ index: UInt32) {
        performMutation { try $0.stashPop(index: index) }
    }

    func stashDrop(_ index: UInt32) {
        performMutation { try $0.stashDrop(index: index) }
    }

    func runRemote(_ operation: RemoteOperation) {
        let pullStrategy = PullStrategyPreference.current.core
        let includeTags = GitPreferences.fetchIncludesTags
        let message = SendableBox<String?>(nil)
        let rewrite = SendableBox<ForcePushPlan?>(nil)
        performMutation(busyLabel: operation.busyLabel, { session in
            if operation == .push {
                // Rewritten commits that are already on the remote need a confirmed force push.
                if let plan = try session.forcePushPlan() {
                    rewrite.value = plan
                    return
                }
                message.value = RemoteOperation.pushMessage(try session.push())
                return
            }
            // Read the branches on both sides, so the note says what actually changed.
            let before = (try? session.listBranches()) ?? []
            switch operation {
            case .fetch: try session.fetch(includeTags: includeTags)
            case .pull: try session.pull(strategy: pullStrategy)
            case .push: break
            }
            let after = (try? session.listBranches()) ?? []
            message.value = RemoteOperation.successMessage(for: operation, before: before, after: after)
        }, onSuccess: { [weak self] in
            if let plan = rewrite.value {
                self?.activeSheet = .forcePush(plan)
            }
            guard let text = message.value else { return }
            self?.showToast(text, isSuccess: true)
        })
    }

    func addWorktree(
        path: String,
        branchName: String?,
        startPoint: String?,
        detach: Bool,
        switchAfterCreate: Bool
    ) {
        let trimmedPath = path.trimmed
        guard !trimmedPath.isEmpty else { return }
        let resolvedPath = Self.resolvePath(trimmedPath, relativeTo: activeCheckoutPath)
        // The core trims the branch and start point and treats blank ones as none.
        performMutation({ session in
            try session.addWorktree(
                path: resolvedPath,
                branchName: branchName,
                startPoint: startPoint,
                detach: detach
            )
        }, onSuccess: { [weak self] in
            if switchAfterCreate {
                self?.switchCheckout(to: resolvedPath)
            }
        })
    }

    func removeWorktree(path: String, label: String, force: Bool) {
        let canonical = Self.canonicalPath(for: path)
        let wasActive = (canonical == activeCheckoutPath)
        let fallback = fallbackCheckoutPath(excluding: canonical)
        // Removing the checkout this tab shows needs somewhere to go afterwards. The menu only
        // offers it when a fallback exists, but that was checked against a list that may be
        // stale by now (and the force-remove prompt comes back here too), so check again. The
        // fallback's session is opened in the background work, before anything is deleted, and
        // handed back for the switch. If any of that fails, nothing is removed and the tab
        // stays where it is.
        if wasActive, fallback == nil {
            errorMessage = "Can't remove the checkout this tab shows, because no other checkout "
                + "of this repository is available to switch to."
            return
        }
        let prepared = SendableBox<RepoSession?>(nil)
        performMutation({ session in
            if wasActive, let fallback {
                // Opening runs `git worktree list`, so it stays off the main actor. The fallback
                // must still be a checkout of this repository: its own worktree list has to
                // include the checkout being removed.
                let next = try RepoSession(path: fallback)
                let sameRepository = FileManager.default.fileExists(atPath: fallback)
                    && (try? next.listWorktreeEntries())?
                        .contains(where: { $0.path == canonical }) == true
                guard sameRepository else {
                    throw GitCraftError.Message(
                        msg: "Can't remove the checkout this tab shows, because \(fallback) is no longer "
                            + "a checkout of this repository to switch to."
                    )
                }
                prepared.value = next
            }
            try session.removeWorktree(path: canonical, force: force)
        }, onSuccess: { [weak self] in
            guard let self else { return }
            if self.repoPath == canonical, let fallback {
                self.repoPath = fallback
            }
            if let fallback, let next = prepared.value {
                self.switchCheckout(to: fallback, using: next)
            }
        }, onFailure: { [weak self] error in
            // A safe remove refused because the worktree has modified, staged, or untracked
            // files: ask for explicit confirmation before force-removing.
            guard !force,
                  error.displayMessage.contains("modified or untracked files")
                  || error.displayMessage.contains("--force")
            else { return false }
            self?.pendingConfirmation = .forceRemoveWorktree(
                path: canonical,
                label: label,
                isActive: wasActive
            )
            return true
        })
    }

    func lockWorktree(_ path: String) {
        performMutation { try $0.lockWorktree(path: path, reason: nil) }
    }

    func unlockWorktree(_ path: String) {
        performMutation { try $0.unlockWorktree(path: path) }
    }

    func pruneWorktrees() {
        performMutation { try $0.pruneWorktrees() }
    }

    func copyOid(_ oid: String) {
        Clipboard.copy(oid)
    }
}
