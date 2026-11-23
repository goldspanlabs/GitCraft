import SwiftUI

@main
struct MiniGitApp: App {
    @StateObject private var workspace = WorkspaceState()

    var body: some Scene {
        WindowGroup("MiniGit") {
            RootView()
                .environmentObject(workspace)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear {
                    workspace.restoreTabs()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Repository…", action: workspace.chooseRepository)
                    .keyboardShortcut("o", modifiers: .command)
                Button("New Repository Tab…", action: workspace.chooseRepository)
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab", action: workspace.closeActiveTab)
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(workspace.selectedTabID == nil)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var workspace: WorkspaceState

    var body: some View {
        Group {
            if let activeTab = workspace.activeTab {
                RepoWorkspaceView(workspace: workspace, tab: activeTab)
                    .id(activeTab.id)
            } else {
                VStack(spacing: 0) {
                    if let error = workspace.openError {
                        ErrorBanner(message: error) {
                            workspace.openError = nil
                        }
                    }
                    WelcomeView(workspace: workspace)
                }
            }
        }
    }
}

struct RepoWorkspaceView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject var tab: RepoTab
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(tab: tab)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                TabBarView(workspace: workspace)
                Divider()

                if let error = workspace.openError {
                    ErrorBanner(message: error) {
                        workspace.openError = nil
                    }
                }

                if let error = tab.errorMessage {
                    ErrorBanner(message: error) {
                        tab.errorMessage = nil
                    }
                }

                if tab.isMerging || tab.hasConflicts {
                    MergeBanner(hasConflicts: tab.hasConflicts) {
                        tab.pendingConfirmation = .abortMerge
                    }
                }

                // Main Split: Commit Graph (top) + Diff/Staging Inspector (bottom)
                VSplitView {
                    ZStack(alignment: .bottom) {
                        CommitTableView(
                            rows: tab.commits,
                            graphRevision: tab.graphRevision,
                            workingChangesCount: tab.totalChangesCount,
                            scrollRequest: tab.scrollRequest,
                            onLoadMore: { tab.loadMoreCommits() },
                            onSelectCommit: { tab.selectCommit($0) },
                            onCopyOid: { tab.copyOid($0) },
                            onCreateBranchAtCommit: { oid in
                                tab.newBranchStartPoint = oid
                                tab.isShowingNewBranchSheet = true
                            },
                            onCreateTagAtCommit: { oid in
                                tab.newTagTarget = oid
                                tab.isShowingNewTagSheet = true
                            },
                            onCheckoutCommit: { oid in
                                tab.checkoutBranch(oid)
                            }
                        )

                        if tab.commits.isEmpty && tab.searchQuery.isEmpty {
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
                    .frame(minHeight: 200)

                    InspectorView(tab: tab)
                        .frame(minHeight: 210, idealHeight: 290)
                }
            }
            // Hidden shortcuts for Cmd+F search focus and Cmd+Shift+S sidebar toggle
            .background(
                Group {
                    Button("") { isSearchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                    Button("") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                        }
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .opacity(0)
                }
            )
        }
        .navigationTitle(tab.name)
        .navigationSubtitle(tab.currentBranch)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if tab.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Filter commits…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($isSearchFocused)
                        .onChange(of: searchText) { newValue in
                            tab.updateSearch(newValue)
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: 210)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

                Button {
                    tab.runRemote(.fetch)
                } label: {
                    Label("Fetch", systemImage: "arrow.down.circle")
                }
                .disabled(tab.isBusy)

                Button {
                    tab.runRemote(.pull)
                } label: {
                    Label("Pull", systemImage: "arrow.down.to.line")
                }
                .disabled(tab.isBusy)

                Button {
                    tab.runRemote(.push)
                } label: {
                    Label("Push", systemImage: "arrow.up.to.line")
                }
                .disabled(tab.isBusy)

                Button {
                    tab.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (Cmd+R)")
            }
        }
        .sheet(isPresented: $tab.isShowingNewBranchSheet) {
            NewBranchSheet(tab: tab)
        }
        .sheet(isPresented: $tab.isShowingNewTagSheet) {
            NewTagSheet(tab: tab)
        }
        .sheet(isPresented: $tab.isShowingStashSheet) {
            NewStashSheet(tab: tab)
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
        .onAppear {
            searchText = tab.searchQuery
        }
    }
}

private struct MergeBanner: View {
    let hasConflicts: Bool
    let onAbort: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            Text(
                hasConflicts
                    ? "Merge in progress with conflicts — resolve conflicts, stage files, and commit, or abort."
                    : "Merge in progress — review staged changes and commit, or abort."
            )
            .font(.caption)
            .lineLimit(2)
            Spacer()
            Button("Abort Merge…", action: onAbort)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.14))
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.12))
    }
}
