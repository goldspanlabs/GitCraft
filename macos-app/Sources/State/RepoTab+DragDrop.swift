import AppKit

extension RepoTab {
    var gitDropUnavailable: Bool {
        isBusy || isPreparingGitDrop || activeSheet != nil || pendingConfirmation != nil
            || isMerging || isRebasing || isCherryPicking || isReverting || hasConflicts
    }

    var dragHeadOID: String? { branches.first { $0.isHead && !$0.isRemote }?.targetOidHex }

    func makeGitDrag(oids: [String], sourceRef: String? = nil, label: String) -> GitDragPayload? {
        guard !gitDropUnavailable, !oids.isEmpty, oids.count <= 100, let head = dragHeadOID else { return nil }
        return GitDragPayload(checkout: activeCheckoutPath, headOID: head, branch: currentBranch,
                              oids: oids, sourceRef: sourceRef, label: label)
    }

    func gitDropResolution(_ payload: GitDragPayload, target: GitDropTarget, option: Bool) -> GitDropResolution {
        GitDropResolution.resolve(payload, target: target, checkout: activeCheckoutPath,
                                  branch: currentBranch, headOID: dragHeadOID,
                                  unavailable: gitDropUnavailable,
                                  option: option)
    }

    func receiveGitDrop(_ payload: GitDragPayload, target: GitDropTarget, option: Bool) {
        gitDragHint = nil
        let resolution = gitDropResolution(payload, target: target, option: option)
        guard let action = resolution.action else { showToast(resolution.message); return }
        switch action {
        case .createBranch:
            presentNewBranch(startPoint: payload.oids[0])
        case .createTag:
            presentNewTag(target: payload.oids[0])
        case .merge, .rebase, .cherryPick:
            activeSheet = .gitDrop(GitDropPlan(payload: payload, target: target, action: action,
                                             message: resolution.message))
        case .squash, .fixup:
            guard case let .commit(targetOID) = target else { return }
            isPreparingGitDrop = true
            let oids = payload.oids + [targetOID]
            loadInBackground({ try $0.squashPreview(oids: oids) }, apply: { [weak self] preview in
                guard let self else { return }
                self.isPreparingGitDrop = false
                guard self.activeCheckoutPath == payload.checkout,
                      preview.head.oid == payload.headOID,
                      preview.head.branch == "refs/heads/\(payload.branch)" else {
                    self.showToast("The branch changed. Start the drag again."); return
                }
                guard preview.commits.first?.oidHex == targetOID else {
                    self.showToast("Drop onto the oldest commit in the consecutive range"); return
                }
                guard !self.gitDropUnavailable else { return }
                self.activeSheet = .dropSquash(preview, checkout: payload.checkout, fixup: action == .fixup)
            }, onFailure: { [weak self] error in
                self?.isPreparingGitDrop = false
                self?.showToast(error.displayMessage)
            }, reportsError: false, always: { [weak self] in self?.isPreparingGitDrop = false })
        }
    }

    /// Only the pinned commit is passed to Git. The core rechecks the destination and source
    /// under its mutation lock; Undo and conflict recovery use the normal mutation machinery.
    func executeGitDrop(_ plan: GitDropPlan, action: GitDropAction) {
        guard !isBusy else { return }
        guard activeCheckoutPath == plan.payload.checkout else {
            showToast("The checkout changed. Start the drag again."); return
        }
        let integration: DropIntegration
        switch action {
        case .merge: integration = .merge
        case .rebase: integration = .rebase
        case .cherryPick: integration = .cherryPick
        default: return
        }
        let payload = plan.payload
        performUndoableHeadMove(actionName: action.rawValue,
                                message: "\(action.rawValue) completed on \"\(payload.branch)\".",
                                undoMode: .keep) { session in
            try session.integrateDrop(commit: payload.oids[0], sourceRef: payload.sourceRef,
                                      action: integration,
                                      expected: HeadPosition(oid: payload.headOID, branch: "refs/heads/\(payload.branch)"))
        }
    }
}
