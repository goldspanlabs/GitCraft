import AppKit
import SwiftUI

@main
struct GitCraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = WorkspaceState()

    var body: some Scene {
        // One window per repository; macOS groups them into native tabs. A window with
        // no value (what the tab bar's "+" button opens) shows the welcome screen.
        WindowGroup("GitCraft", for: URL.self) { $url in
            RepoWindowView(url: url)
                .environmentObject(workspace)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .commands {
            RepoCommands(workspace: workspace)
        }

        // Adds "GitCraft ▸ Settings…" (⌘,) to the macOS application menu.
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        // GitCraft restores its own open repositories (see `WorkspaceState.restoreTabsIfNeeded`).
        // Letting macOS restore the windows too opens every repository twice.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        WorkspaceState.isTerminating = true
        return .terminateNow
    }
}

private struct ActiveRepoTabKey: FocusedValueKey {
    typealias Value = RepoTab
}

extension FocusedValues {
    var activeRepoTab: RepoTab? {
        get { self[ActiveRepoTabKey.self] }
        set { self[ActiveRepoTabKey.self] = newValue }
    }
}

struct RepoCommands: Commands {
    let workspace: WorkspaceState
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.activeRepoTab) private var activeTab

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Repository…") {
                workspace.install(openWindow: openWindow)
                workspace.chooseRepository()
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("New Repository Tab…") {
                workspace.install(openWindow: openWindow)
                workspace.chooseRepository()
            }
            .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Refresh") { activeTab?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(activeTab == nil)
        }
    }
}

/// Content of every window: a repository when `url` is set, otherwise the welcome screen.
struct RepoWindowView: View {
    let url: URL?
    @EnvironmentObject private var workspace: WorkspaceState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Group {
            if let url {
                RepositoryWindowContent(url: url)
            } else {
                WelcomeWindowContent()
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        // Applies the saved appearance at launch. Changes made in Settings are applied
        // by `SettingsView` itself, so this still works if no repository window is open.
        .onAppear {
            workspace.install(openWindow: openWindow)
            AppearancePreference.apply(appearance)
        }
    }
}

private struct RepositoryWindowContent: View {
    let url: URL
    @EnvironmentObject private var workspace: WorkspaceState
    @StateObject private var binding = RepoWindowBinding()
    @State private var tab: RepoTab?

    var body: some View {
        Group {
            if let tab {
                RepoWorkspaceView(workspace: workspace, tab: tab)
                    .focusedSceneValue(\.activeRepoTab, tab)
            } else {
                VStack(spacing: 0) {
                    if let error = workspace.openError {
                        ErrorBanner(message: error) { workspace.openError = nil }
                    }
                    Spacer()
                }
            }
        }
        .background(WindowAccessor { binding.attach(window: $0) })
        .onAppear {
            guard tab == nil else { return }
            // A second window for a repository that's already open (macOS restoring a
            // window that GitCraft's own restore also opened) just closes itself.
            if workspace.isOpen(url) && workspace.hasNoPendingTab(for: url) {
                binding.closeWindow()
                return
            }
            guard let claimed = workspace.claimTab(for: url) else { return }
            tab = claimed
            binding.bind(tab: claimed) { workspace.releaseTab($0) }
        }
    }
}

private struct WelcomeWindowContent: View {
    @EnvironmentObject private var workspace: WorkspaceState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var holder = WindowHolder()

    var body: some View {
        VStack(spacing: 0) {
            if let error = workspace.openError {
                ErrorBanner(message: error) { workspace.openError = nil }
            }
            WelcomeView(workspace: workspace) {
                // The repository opens in its own tab; this welcome tab is done.
                holder.window?.close()
            }
        }
        .background(WindowAccessor { [holder] window in
            holder.window = window
            window.title = "Repository Manager"
            WindowTabs.joinRepositoryTabs(window)
        })
        .onAppear {
            // Child views appear before their parents, so install here rather than relying
            // on `RepoWindowView` having done it already.
            workspace.install(openWindow: openWindow)
            // At launch, bring back the repositories that were open last time.
            if workspace.restoreTabsIfNeeded() {
                // Give the restored repository windows time to appear (and join tabs) first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { holder.window?.close() }
            }
        }
    }
}

struct RepoWorkspaceView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject var tab: RepoTab
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText = ""

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
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
                        onSelectCommit: { tab.selectCommitFromTable($0) },
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
                        EmptyHistoryHint()
                    }
                }
                .frame(minHeight: 200)

                InspectorView(tab: tab)
                    .frame(minHeight: 210, idealHeight: 290)
            }
        }
        // Hidden shortcut for Cmd+Shift+S sidebar toggle
        .background(
            Button("") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .opacity(0)
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(tab: tab)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .navigationTitle(tab.name)
        .navigationSubtitle(tab.currentBranch)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter commits")
        .onChange(of: searchText) { newValue in
            tab.updateSearch(newValue)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    Button {
                        workspace.chooseRepository()
                    } label: {
                        TopBarIconLabel(title: "Quick Launch") {
                            ToolbarIconView(icon: .quickLaunch)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open Repository (Cmd+O)")

                    HStack(spacing: 0) {
                        Button {
                            tab.runRemote(.fetch)
                        } label: {
                            TopBarIconLabel(title: "Fetch") {
                                ToolbarIconView(icon: .fetch)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(tab.isBusy)
                        .help("Fetch from remote")

                        TopBarSeparator()

                        Button {
                            tab.runRemote(.pull)
                        } label: {
                            TopBarIconLabel(title: "Pull", badgeCount: tab.currentBranchBehindCount) {
                                ToolbarIconView(icon: .pull)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(tab.isBusy)
                        .help("Pull from remote")

                        TopBarSeparator()

                        Button {
                            tab.runRemote(.push)
                        } label: {
                            TopBarIconLabel(title: "Push", badgeCount: tab.currentBranchAheadCount) {
                                ToolbarIconView(icon: .push)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(tab.isBusy)
                        .help("Push to remote")
                    }

                    TopBarStashItem(tab: tab)

                    Button {
                        tab.toggleScopeToCurrentBranch()
                    } label: {
                        TopBarIconLabel(title: tab.scopeToCurrentBranch ? "Branch" : "All") {
                            ToolbarIconView(icon: .filter)
                                .opacity(tab.scopeToCurrentBranch ? 1 : 0.55)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(tab.scopeToCurrentBranch
                        ? "Showing the current branch and its base branch — click to show all branches"
                        : "Showing all branches — click to show only the current branch and its base branch")

                    if tab.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 4)
                    }
                }
                .fixedSize()
                .background(ToolbarPillRemovalView())
            }
        }
        .modifier(RepoSheets(tab: tab))
        .onAppear {
            searchText = tab.searchQuery
        }
    }
}

/// Sheets and the destructive-action dialog for a repository window.
private struct RepoSheets: ViewModifier {
    @ObservedObject var tab: RepoTab

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $tab.isShowingNewBranchSheet) {
            NewBranchSheet(tab: tab)
        }
        .sheet(isPresented: $tab.isShowingNewTagSheet) {
            NewTagSheet(tab: tab)
        }
        .sheet(isPresented: $tab.isShowingStashSheet) {
            NewStashSheet(tab: tab)
        }
        .sheet(isPresented: $tab.isShowingRemotesSheet) {
            RemotesSheet(tab: tab)
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

private struct ToolbarPillRemovalView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PillRemovalProbeView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PillRemovalProbeView)?.stripToolbarBezel()
    }

    private final class PillRemovalProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stripToolbarBezel()
            DispatchQueue.main.async { [weak self] in
                self?.stripToolbarBezel()
            }
        }

        override func layout() {
            super.layout()
            stripToolbarBezel()
        }

        func stripToolbarBezel() {
            if let items = window?.toolbar?.items {
                for item in items {
                    item.isBordered = false
                }
            }
            // Walk up to the enclosing NSToolbarItemViewer and hide any background platter/glass subviews.
            var cursor: NSView? = superview
            while let current = cursor {
                let className = String(describing: type(of: current))
                if className.contains("ToolbarItemViewer") || className.contains("ToolbarItemGroup") {
                    for sub in current.subviews {
                        let subName = String(describing: type(of: sub))
                        if subName.contains("Bezel") || subName.contains("Glass") || subName.contains("Platter") || subName.contains("Background") || subName.contains("VisualEffect") {
                            sub.isHidden = true
                            sub.alphaValue = 0
                        }
                    }
                }
                cursor = current.superview
            }
        }
    }
}

private struct TopBarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 1, height: 18)
            .padding(.bottom, 12)
    }
}

private struct TopBarIconLabel<Icon: View>: View {
    let title: String
    var badgeCount: Int = 0
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                icon()
                    .frame(height: 20)

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .secondaryLabelColor))
                        )
                        .offset(x: 18, y: -4)
                }
            }
            .frame(minWidth: 40, minHeight: 20)

            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct TopBarStashItem: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    tab.isShowingStashSheet = true
                } label: {
                    ToolbarIconView(icon: .stash)
                        .frame(height: 20)
                }
                .buttonStyle(.plain)
                .disabled(tab.totalChangesCount == 0 || tab.isBusy)
                .help("Stash working changes")

                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 1, height: 15)

                StashMenuTriggerButton(tab: tab)
            }
            .frame(height: 20)

            Text("Stash")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

private struct StashMenuTriggerButton: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        Button {
            showMenu()
        } label: {
            ToolbarIconView(icon: .chevronDown)
                .frame(width: 14, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func showMenu() {
        let menu = NSMenu()
        let handler = StashMenuHandler(tab: tab)

        let saveItem = NSMenuItem(
            title: "Save Stash…",
            action: #selector(StashMenuHandler.saveStash),
            keyEquivalent: ""
        )
        saveItem.target = handler
        saveItem.representedObject = handler
        saveItem.isEnabled = tab.totalChangesCount > 0 && !tab.isBusy
        menu.addItem(saveItem)

        if !tab.stashes.isEmpty {
            menu.addItem(.separator())

            let popItem = NSMenuItem(
                title: "Pop Latest Stash (\(tab.stashes[0].name))",
                action: #selector(StashMenuHandler.popLatest),
                keyEquivalent: ""
            )
            popItem.target = handler
            popItem.representedObject = handler
            menu.addItem(popItem)

            let applyItem = NSMenuItem(
                title: "Apply Latest Stash (\(tab.stashes[0].name))",
                action: #selector(StashMenuHandler.applyLatest),
                keyEquivalent: ""
            )
            applyItem.target = handler
            applyItem.representedObject = handler
            menu.addItem(applyItem)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

@MainActor
private final class StashMenuHandler: NSObject {
    let tab: RepoTab

    init(tab: RepoTab) {
        self.tab = tab
    }

    @objc func saveStash() {
        tab.isShowingStashSheet = true
    }

    @objc func popLatest() {
        guard let first = tab.stashes.first else { return }
        tab.stashPop(first.index)
    }

    @objc func applyLatest() {
        guard let first = tab.stashes.first else { return }
        tab.stashApply(first.index)
    }
}
