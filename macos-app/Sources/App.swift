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
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty {
                TabBarView(workspace: workspace)
                Divider()
            }

            if let error = workspace.openError {
                ErrorBanner(message: error) {
                    workspace.openError = nil
                }
            }

            if let activeTab = workspace.activeTab {
                RepoWorkspaceView(tab: activeTab)
                    .id(activeTab.id)
            } else {
                WelcomeView(workspace: workspace)
            }
        }
    }
}

struct RepoWorkspaceView: View {
    @ObservedObject var tab: RepoTab
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(tab: tab)
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                // Top Action Header
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .help("Toggle Sidebar (Cmd+Shift+S)")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.name)
                            .font(.headline)
                            .lineLimit(1)
                        if !tab.currentBranch.isEmpty {
                            Text(tab.currentBranch)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if tab.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 2)
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
                    .padding(.vertical, 5)
                    .frame(width: 220)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                    ControlGroup {
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
                    }

                    Button {
                        tab.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh (Cmd+R)")
                }
                .controlSize(.regular)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(nsColor: .windowBackgroundColor))

                if let error = tab.errorMessage {
                    ErrorBanner(message: error) {
                        tab.errorMessage = nil
                    }
                }

                Divider()

                // Main Split: Commit Graph (top) + Diff/Staging Inspector (bottom)
                VSplitView {
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
                    .frame(minHeight: 200)

                    InspectorView(tab: tab)
                        .frame(minHeight: 210, idealHeight: 290)
                }
            }
            // Hidden shortcut button for Cmd+F search focus
            .background(
                Button("") { isSearchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
            )
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
        .onAppear {
            searchText = tab.searchQuery
        }
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
