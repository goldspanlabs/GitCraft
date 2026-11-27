import SwiftUI

/// The window's detail column: banners, commit graph and inspector.
struct RepoDetailView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject var tab: RepoTab
    @State private var isBottomExpandedToMax = false
    @AppStorage(BottomPanelDefaults.collapsedKey) private var isBottomCollapsed = false
    @AppStorage(BottomPanelDefaults.maximizedKey) private var isBottomMaximized = false

    /// The tooltip on a disabled Continue button while conflicts remain.
    private var conflictsBlockContinue: String? {
        tab.hasConflicts ? "Resolve the conflicts and stage the fixed files to continue." : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner(checker: .shared)

            if let error = workspace.openError {
                ErrorBannerView(message: error) {
                    workspace.openError = nil
                }
            }

            if tab.isRebasing {
                OperationBanner(
                    title: tab.hasConflicts
                        ? "Rebase stopped on conflicts — resolve them, stage the files, then continue, or abort."
                        : "Rebase in progress — continue to apply the remaining commits, or abort.",
                    abortLabel: "Abort Rebase…",
                    onAbort: { tab.pendingConfirmation = .abortRebase },
                    continueLabel: "Continue Rebase",
                    onContinue: tab.hasConflicts || tab.isBusy ? nil : { tab.continueRebase() },
                    continueBlockedReason: conflictsBlockContinue
                )
            } else if tab.isCherryPicking {
                OperationBanner(
                    title: tab.hasConflicts
                        ? "Cherry-pick stopped on conflicts — resolve them, stage the files, then continue, or abort."
                        : "Cherry-pick in progress — continue to commit it, or abort.",
                    abortLabel: "Abort Cherry Pick…",
                    onAbort: { tab.pendingConfirmation = .abortCherryPick },
                    continueLabel: "Continue Cherry Pick",
                    onContinue: tab.hasConflicts || tab.isBusy ? nil : { tab.continueCherryPick() },
                    continueBlockedReason: conflictsBlockContinue
                )
            } else if tab.isReverting {
                OperationBanner(
                    title: tab.hasConflicts
                        ? "Revert stopped on conflicts — resolve them, stage the files, then continue, or abort."
                        : "Revert in progress — continue to commit it, or abort.",
                    abortLabel: "Abort Revert…",
                    onAbort: { tab.pendingConfirmation = .abortRevert },
                    continueLabel: "Continue Revert",
                    onContinue: tab.hasConflicts || tab.isBusy ? nil : { tab.continueRevert() },
                    continueBlockedReason: conflictsBlockContinue
                )
            } else if tab.isMerging || tab.hasConflicts {
                OperationBanner(
                    title: tab.hasConflicts
                        ? "Merge in progress with conflicts — resolve conflicts, stage files, and commit, or abort."
                        : "Merge in progress — review staged changes and commit, or abort.",
                    abortLabel: "Abort Merge…",
                    onAbort: { tab.pendingConfirmation = .abortMerge }
                )
            }

            // Main Split: Commit Graph (top) + Diff/Staging Inspector (bottom)
            // The working-changes inspector has no tab strip to reopen a collapsed pane from, so
            // only a selected commit's inspector can be collapsed by dragging.
            PersistentVSplit(
                minTop: 200,
                minBottom: 312,
                canCollapse: tab.selectedCommit != nil,
                isExpandedToMax: $isBottomExpandedToMax
            ) {
                ZStack(alignment: .bottom) {
                    CommitTableView(
                        rows: tab.commits,
                        totalCommitCount: tab.totalCommitCount,
                        isSearchActive: tab.activeSearchQuery != nil,
                        graphRevision: tab.graphRevision,
                        graphGeneration: tab.graphGeneration,
                        workingChangesCount: tab.totalChangesCount,
                        remoteHosts: Dictionary(
                            tab.remotes.map { ($0.name, RemoteHost(url: $0.fetchUrl)) },
                            uniquingKeysWith: { first, _ in first }
                        ),
                        worktrees: tab.worktrees,
                        showTags: tab.showTags,
                        showAvatars: tab.showAvatars,
                        isBusy: tab.isBusy,
                        scrollRequest: tab.scrollRequest,
                        onLoadMore: { tab.loadMoreCommits() },
                        onFetchWindow: { offset, limit in
                            try await tab.fetchGraphWindow(offset: offset, limit: limit)
                        },
                        onCachedWindow: { offset, limit in
                            tab.cachedGraphWindow(offset: offset, limit: limit)
                        },
                        onSelectCommits: { commits in
                            if !commits.isEmpty {
                                isBottomExpandedToMax = false
                            }
                            tab.selectCommitsFromTable(commits)
                        },
                        onCopyOid: { tab.copyOid($0) },
                        onCopyOids: { tab.copyOids($0) },
                        squashCheck: tab.squashCheck,
                        onSquash: { tab.activeSheet = .squash($0) },
                        onCreateBranchAtCommit: { oid in
                            tab.presentNewBranch(startPoint: oid)
                        },
                        onCreateTagAtCommit: { oid in
                            tab.presentNewTag(target: oid)
                        },
                        onCreateWorktreeAtCommit: { oid in
                            tab.presentNewWorktree(source: .commit(oid: oid))
                        },
                        canRemoveWorktree: { worktree in
                            tab.canRemoveWorktree(worktree)
                        },
                        onRemoveWorktree: { worktree in
                            tab.requestRemoveWorktree(worktree)
                        },
                        onCheckoutCommit: { oid in
                            tab.requestCheckoutCommit(oid)
                        },
                        currentBranch: tab.currentBranch,
                        onCommitAction: { action, oid in
                            switch action {
                            case .merge: tab.requestMergeCommit(oid)
                            case .rebase: tab.requestRebase(onto: oid)
                            case let .reset(mode): tab.resetTo(oid, mode: mode)
                            case .cherryPick: tab.cherryPick(oid)
                            case .revert: tab.revertCommit(oid)
                            }
                        },
                        onClickWorkingChanges: {
                            isBottomCollapsed = false
                            isBottomMaximized = false
                            isBottomExpandedToMax = true
                        }
                    )

                    if tab.commits.isEmpty {
                        switch tab.historyState {
                        case .loading:
                            HistoryLoadingIndicator()
                        case .loaded where tab.searchQuery.isEmpty:
                            EmptyHistoryHint()
                        case .loaded, .failed:
                            EmptyView()
                        }
                    }
                }
            } bottom: {
                InspectorView(tab: tab)
            }
            // On the split, not the graph pane, so they stay visible while the bottom pane is maximized.
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    if let error = tab.errorMessage {
                        ToastView(message: error, tint: .red) {
                            tab.errorMessage = nil
                        }
                        // UI tests wait for this to see that an action failed.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("error-toast")
                        .id(error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    ForEach(tab.toasts) { toast in
                        ToastView(
                            message: toast.message,
                            tint: toast.isSuccess ? .green : .yellow,
                            icon: toast.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            // Longer when there's a button, so there's time to reach it.
                            autoDismissAfter: toast.action == nil ? 4 : 10,
                            actionTitle: toast.action?.title,
                            actionHelp: toast.action?.help,
                            onAction: toast.action.map { action in { action.perform() } },
                            actionDisabled: !tab.toastActionEnabled(toast)
                        ) {
                            tab.dismissToast(toast.id)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 10)
            }
            .animation(.easeOut(duration: 0.2), value: tab.toasts.map(\.id))
            .animation(.easeOut(duration: 0.2), value: tab.errorMessage)
            .onChange(of: tab.selectedCommit?.oidHex) { _, newValue in
                if newValue != nil, isBottomExpandedToMax {
                    isBottomExpandedToMax = false
                }
            }
            .onChange(of: tab.selectedCommits.isEmpty) { _, isEmpty in
                if !isEmpty, isBottomExpandedToMax {
                    isBottomExpandedToMax = false
                }
            }
        }
        .modifier(RepoSheets(tab: tab))
        // Hairline under the toolbar: the title bar's own separator doesn't show here.
        .safeAreaInset(edge: .top, spacing: 0) {
            Divider()
        }
    }
}

/// Sheets and the destructive-action dialog for a repository window.
private struct RepoSheets: ViewModifier {
    @ObservedObject var tab: RepoTab

    func body(content: Content) -> some View {
        content
            .sheet(item: $tab.activeSheet) { sheet in
                switch sheet {
                case let .newBranch(startPoint):
                    NewBranchSheet(tab: tab, startPoint: startPoint)
                case let .newWorktree(source):
                    NewWorktreeSheet(tab: tab, source: source)
                case let .checkoutCommit(oid):
                    CheckoutCommitSheet(tab: tab, oid: oid)
                case let .mergeCommit(oid):
                    MergeCommitSheet(tab: tab, oid: oid)
                case let .newTag(target):
                    NewTagSheet(tab: tab, target: target)
                case let .squash(preview):
                    SquashSheet(tab: tab, preview: preview)
                case let .forcePush(plan):
                    ForcePushSheet(tab: tab, plan: plan)
                case .newStash:
                    NewStashSheet(tab: tab)
                case .addRemote:
                    RemotesSheet(tab: tab, editing: nil)
                case let .editRemote(remote):
                    RemotesSheet(tab: tab, editing: remote)
                }
            }
            .confirmationDialog(
                tab.pendingConfirmation?.title ?? "",
                isPresented: Binding(
                    get: { tab.pendingConfirmation != nil },
                    set: { if !$0 { tab.pendingConfirmation = nil } }
                ),
                presenting: tab.pendingConfirmation
            ) { action in
                Button(action.confirmLabel, role: .destructive) {
                    tab.executeConfirmed(action)
                }
                Button("Cancel", role: .cancel) {
                    tab.pendingConfirmation = nil
                }
            } message: { action in
                Text(action.message)
            }
    }
}

/// Centred over the commit list while a repository's history is first being read.
private struct HistoryLoadingIndicator: View {
    var body: some View {
        ProgressView("Loading history…")
            .controlSize(.small)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

private struct EmptyHistoryHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text("No commits yet — stage your files below and make your first commit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .cornerRadius(8)
        .padding(.bottom, 14)
    }
}
