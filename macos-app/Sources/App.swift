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
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .help("Toggle Sidebar (Cmd+Shift+S)")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.name)
                            .font(.headline)
                        if !tab.currentBranch.isEmpty {
                            Text(tab.currentBranch)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if tab.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }

                    TextField("Filter commits…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                        .focused($isSearchFocused)
                        .onChange(of: searchText) { newValue in
                            tab.updateSearch(newValue)
                        }

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
                        Image(systemName: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh (Cmd+R)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
                        workingChangesCount: tab.totalChangesCount,
                        scrollRequest: tab.scrollRequest,
                        onLoadMore: { tab.loadMoreCommits() },
                        onSelectCommit: { tab.selectCommit($0) },
                        onCopyOid: { tab.copyOid($0) },
                        onCreateBranchAtCommit: { oid in
                            tab.newBranchStartPoint = oid
                            tab.isShowingNewBranchSheet = true
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
