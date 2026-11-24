import AppKit
import SwiftUI

@main
struct GitCraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Windows are plain AppKit windows (see `RepoWindowController`), so the only SwiftUI
    // scene is Settings. It also carries the app-wide menu commands.
    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            RepoCommands()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_: Notification) {
        let saved = UserDefaults.standard.string(forKey: AppearancePreference.storageKey) ?? ""
        AppearancePreference.apply(AppearancePreference(rawValue: saved) ?? .system)

        let workspace = WorkspaceState.shared
        // UI tests open a fixture repository with `-UITestOpenRepository <path>` instead of
        // driving the open panel. Normal launches never set this key.
        if let path = UserDefaults.standard.string(forKey: "UITestOpenRepository"),
           workspace.openRepository(at: URL(fileURLWithPath: path))
        {
            return
        }
        if !workspace.restoreTabs() {
            workspace.openWelcome()
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WorkspaceState.shared.openWelcome() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        WorkspaceState.isTerminating = true
        return .terminateNow
    }
}

struct RepoCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Repository…") { WorkspaceState.shared.chooseRepository() }
                .keyboardShortcut("o", modifiers: .command)
            Button("New Repository Tab…") { WorkspaceState.shared.chooseRepository() }
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Refresh") { WorkspaceState.shared.activeTab?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

/// Applies the user's appearance preference to a hosted SwiftUI tree.
struct AppearanceScoped<Content: View>: View {
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .preferredColorScheme((AppearancePreference(rawValue: appearanceRaw) ?? .system).colorScheme)
    }
}

/// The window's detail column: banners, commit graph and inspector.
struct RepoDetailView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject var tab: RepoTab

    var body: some View {
        VStack(spacing: 0) {
            if let error = workspace.openError {
                ErrorBannerView(message: error) {
                    workspace.openError = nil
                }
            }

            if let error = tab.errorMessage {
                ErrorBannerView(message: error) {
                    tab.errorMessage = nil
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
                    onContinue: tab.hasConflicts || tab.isBusy ? nil : { tab.continueRebase() }
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
            PersistentVSplit(minTop: 200, minBottom: 210) {
                ZStack(alignment: .bottom) {
                    CommitTableView(
                        rows: tab.commits,
                        graphRevision: tab.graphRevision,
                        workingChangesCount: tab.totalChangesCount,
                        remoteHosts: Dictionary(
                            tab.remotes.map { ($0.name, RemoteHost(url: $0.fetchUrl)) },
                            uniquingKeysWith: { first, _ in first }
                        ),
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
                            tab.requestCheckoutCommit(oid)
                        }
                    )

                    if tab.commits.isEmpty && tab.searchQuery.isEmpty {
                        EmptyHistoryHint()
                    }
                }
            } bottom: {
                InspectorView(tab: tab)
            }
        }
        .modifier(RepoSheets(tab: tab))
        // Hairline under the toolbar: the title bar's own separator doesn't show here.
        .safeAreaInset(edge: .top, spacing: 0) {
            Divider()
        }
    }
}

/// The toolbar's centre cluster (Fetch/Pull/Push, Stash, branch filter).
/// Hosted in an `NSToolbarItem` by `RepoWindowController`.
struct RepoToolbarActionsView: View {
    let workspace: WorkspaceState
    @ObservedObject var tab: RepoTab

    var body: some View {
        HStack(spacing: 10) {
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

        }
        .fixedSize()
        .padding(.horizontal, 6)
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
        .sheet(isPresented: $tab.isShowingCheckoutCommitSheet) {
            CheckoutCommitSheet(tab: tab)
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

/// Banner for an operation that is paused mid-way (merge or rebase).
private struct OperationBanner: View {
    let title: String
    let abortLabel: String
    let onAbort: () -> Void
    var continueLabel: String?
    var onContinue: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            Text(title)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            if let continueLabel {
                Button(continueLabel) { onContinue?() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(onContinue == nil)
            }
            Button(abortLabel, action: onAbort)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.14))
    }
}

struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void
    @State private var showingDetails = false

    private var parts: ErrorSummary { ErrorSummary(message) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(parts.summary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(parts.hasDetails ? "Click Show Details for the full output" : "")
            Spacer(minLength: 8)
            if parts.hasDetails {
                Button("Show Details…") { showingDetails = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.12))
        .sheet(isPresented: $showingDetails) {
            ErrorDetailsSheet(text: parts.full)
        }
    }
}

/// The full text of an error (for example a failing hook's output): scrollable,
/// selectable, and copyable.
private struct ErrorDetailsSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            )

            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 320, idealHeight: 420)
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
