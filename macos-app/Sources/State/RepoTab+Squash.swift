import Foundation

/// Whether the selected commits can be squashed.
enum SquashCheck: Equatable {
    case checking
    case allowed(SquashPreview)
    /// Why not, in the core's words.
    case refused(String)
}

// Selecting several commits and squashing them, and publishing rewritten history.
extension RepoTab {
    /// The commit table's selection, in list order. Fewer than two rows is an ordinary
    /// selection.
    func selectCommitsFromTable(_ rows: [CommitRow]) {
        guard rows.count > 1 else {
            selectCommitFromTable(rows.first)
            return
        }
        revealTask?.cancel()
        revealTask = nil
        pendingSelectionOid = nil
        let isSameSelection = rows.map(\.oidHex) == selectedCommits.map(\.oidHex)
        selectedCommits = rows
        guard !isSameSelection else { return }
        selectedCommit = nil
        commitDetail = nil
        loadedDetailOid = nil
        resetMarkdownPreviewState()
        isMarkdownPreview = false
        squashCheck = .checking
        checkSquash()
    }

    /// Brings the selection up to date with a freshly loaded history.
    func reconcileSelection() {
        if let oid = pendingSelectionOid, commits.contains(where: { $0.oidHex == oid }) {
            pendingSelectionOid = nil
            scrollToCommit(oidHex: oid)
            return
        }
        guard !selectedCommits.isEmpty else { return }
        let selected = Set(selectedCommits.map(\.oidHex))
        let survivors = commits.filter { selected.contains($0.oidHex) }
        if survivors.count > 1 {
            if survivors.count < selected.count { squashCheck = .checking }
            selectedCommits = survivors
            // The branch may have moved even when every selected commit is still listed.
            checkSquash()
        } else {
            selectCommit(survivors.first)
        }
    }

    /// Asks again about a multi-selection, if there is one.
    func recheckSquash() {
        if !selectedCommits.isEmpty { checkSquash() }
    }

    /// Asks the core about the current multi-selection.
    private func checkSquash() {
        let oids = selectedCommits.map(\.oidHex)
        squashCheckGeneration += 1
        let generation = squashCheckGeneration
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            self?.squashCheckGeneration == generation && self?.selectedCommits.map(\.oidHex) == oids
        }
        loadInBackground({ session in
            try session.squashPreview(oids: oids)
        }, apply: { [weak self] preview in
            guard isCurrent() else { return }
            self?.publish(.allowed(preview), to: \.squashCheck)
        }, onFailure: { [weak self] error in
            guard isCurrent() else { return }
            self?.publish(.refused(error.displayMessage), to: \.squashCheck)
        }, reportsError: false)
    }

    /// Combines `preview`'s commits into one with the given message. Undoable.
    func squash(_ preview: SquashPreview, summary: String, description: String) {
        let summary = summary.trimmed
        guard !isBusy, !summary.isEmpty else { return }
        let body = description.trimmed
        let message = body.isEmpty ? summary : "\(summary)\n\n\(body)"
        let oids = preview.commits.map(\.oidHex)
        let branch = (preview.head.branch ?? "").replacingOccurrences(of: "refs/heads/", with: "")
        let outcome = SendableBox<SquashResult?>(nil)
        let expected = SendableBox(preview.head)
        performMutation(busyLabel: "Squashing…", { session in
            outcome.value = try session.squashCommits(oids: oids, message: message, expected: expected.value)
        }, onSuccess: { [weak self] in
            guard let self, let result = outcome.value else { return }
            self.selectCommit(nil)
            self.pendingSelectionOid = result.squashedOid
            // A soft reset moves back without touching the index or files, as the squash did.
            self.recordUndo(
                actionName: "Squash",
                step: .moveHead(result.headMove, mode: .soft),
                message: "Squashed \(oids.count) commits on \"\(branch)\"."
            )
        })
    }

    /// Replaces the remote branch as `plan` describes, once the person has confirmed. Not
    /// undoable.
    func forcePush(_ plan: ForcePushPlan) {
        guard !isBusy else { return }
        let confirmed = SendableBox(plan)
        let message = SendableBox<String?>(nil)
        performMutation(busyLabel: "Force pushing…", { session in
            message.value = RemoteOperation.pushMessage(try session.forcePush(plan: confirmed.value))
        }, onSuccess: { [weak self] in
            guard let text = message.value else { return }
            self?.showToast(text, isSuccess: true)
        })
    }

    /// Copies several commit SHAs, one per line.
    func copyOids(_ oids: [String]) {
        Clipboard.copy(oids.joined(separator: "\n"))
    }

    /// The context menu's Squash item. A refusal puts its reason in the title.
    nonisolated static func squashMenuTitle(check: SquashCheck) -> String {
        guard case let .refused(reason) = check else { return "Squash Commits…" }
        let lowered = reason.prefix(1).lowercased() + reason.dropFirst()
        return "Squash Commits (\(lowered))"
    }
}
