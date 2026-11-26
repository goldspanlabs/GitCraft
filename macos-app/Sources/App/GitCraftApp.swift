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
        AppearancePreference.apply(AppearancePreference.current)

        let workspace = WorkspaceState.shared
        // UI tests open a fixture repository with `-UITestOpenRepository <path>` instead of
        // driving the open panel. Normal launches never set this key.
        if let path = UserDefaults.standard.string(forKey: "UITestOpenRepository"),
           workspace.openRepository(at: URL(fileURLWithPath: path))
        {
            return
        }
        workspace.deferTabRestore()
        Task { @MainActor in
            let status = await workspace.refreshGitAvailabilityAsync()
            if status != .available || !workspace.hasOpenRepositories {
                workspace.openWelcome()
            }
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
    @ObservedObject private var workspace = WorkspaceState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { workspace.openNewWindow() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { workspace.openWelcome() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Restore Closed Tab") {
                Task { await workspace.restoreClosedTabAsync() }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(workspace.closedTabPaths.isEmpty)

            Divider()

            Button("Create New Local Repository…") { workspace.presentCreateRepositorySheet() }
            Button("Clone…") { workspace.presentCloneRepositorySheet() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Open…") {
                Task { await workspace.chooseRepositoryAsync() }
            }
            .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                if workspace.recentPaths.isEmpty {
                    Text("No Recent Repositories")
                } else {
                    ForEach(workspace.recentPaths, id: \.self) { path in
                        Button(recentMenuLabel(for: path, among: workspace.recentPaths)) {
                            Task { await workspace.openRepositoryAsync(at: URL(fileURLWithPath: path)) }
                        }
                    }
                    Divider()
                    Button("Clear Menu") { workspace.clearRecentRepositories() }
                }
            }

            Divider()

            Button("Close Window") { workspace.closeActiveWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!workspace.hasOpenWindows)
            Button("Close Tab") { workspace.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!workspace.hasOpenWindows)
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh") { workspace.activeTab?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workspace.activeTab == nil)
            Divider()
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            ShowTagsMenuItem(tab: workspace.activeTab)
            Divider()
            BottomPanelMenuItems(tab: workspace.activeTab)
        }
        CommandMenu("Repository") {
            RepositoryMenuItems(tab: workspace.activeTab)
        }
    }

    private func recentMenuLabel(for path: String, among paths: [String]) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let hasDuplicate = paths.filter { URL(fileURLWithPath: $0).lastPathComponent == name }.count > 1
        guard hasDuplicate else { return name }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shortParent = parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
        return "\(name) — \(shortParent)"
    }
}

private struct ShowTagsMenuItem: View {
    let tab: RepoTab?

    var body: some View {
        if let tab {
            ActiveTabShowTagsToggle(tab: tab)
        } else {
            Button("Show Tags") {}
                .disabled(true)
        }
    }
}

private struct ActiveTabShowTagsToggle: View {
    @ObservedObject var tab: RepoTab

    var body: some View {
        Toggle("Show Tags", isOn: $tab.showTags)
    }
}

/// View ▸ Maximize / Hide Bottom Panel: keyboard-reachable versions of the pane header's
/// maximize button and the divider drag that collapses it.
private struct BottomPanelMenuItems: View {
    let tab: RepoTab?

    var body: some View {
        if let tab {
            ActiveTabBottomPanelItems(tab: tab)
        } else {
            Button("Maximize Bottom Panel") {}
                .disabled(true)
            Button("Hide Bottom Panel") {}
                .disabled(true)
        }
    }
}

private struct ActiveTabBottomPanelItems: View {
    @ObservedObject var tab: RepoTab
    @AppStorage(BottomPanelDefaults.collapsedKey) private var isCollapsed = false
    @AppStorage(BottomPanelDefaults.maximizedKey) private var isMaximized = false

    var body: some View {
        // Only a selected commit's inspector can be collapsed or maximized; the working-changes
        // inspector has neither control.
        let hasCommit = tab.selectedCommit != nil

        Button(isMaximized ? "Restore Bottom Panel Size" : "Maximize Bottom Panel") {
            withAnimation(.easeInOut(duration: 0.18)) {
                // Same steps as the pane header's button: a collapsed pane reopens first.
                if isCollapsed {
                    isCollapsed = false
                } else {
                    isMaximized.toggle()
                }
            }
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!hasCommit)

        Button(isCollapsed ? "Show Bottom Panel" : "Hide Bottom Panel") {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isMaximized { isMaximized = false }
                isCollapsed.toggle()
            }
        }
        .keyboardShortcut("j", modifiers: .command)
        .disabled(!hasCommit)
    }
}

private struct RepositoryMenuItems: View {
    let tab: RepoTab?

    var body: some View {
        if let tab {
            ActiveTabRepositoryMenuItems(tab: tab)
        } else {
            Button("Commit") {}
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(true)
            Divider()
            Button("Fetch") {}
                .disabled(true)
            Button("Pull") {}
                .disabled(true)
            Button("Push") {}
                .disabled(true)
            Divider()
            Button("Save Stash…") {}
                .disabled(true)
            Menu("Checkout Branch") {
                Text("No Open Repository")
            }
            .disabled(true)
            Divider()
            Button("New Branch…") {}
                .keyboardShortcut("b", modifiers: .command)
                .disabled(true)
            Button("New Tag…") {}
                .disabled(true)
            Button("New Worktree…") {}
                .disabled(true)
        }
    }
}

private struct ActiveTabRepositoryMenuItems: View {
    @ObservedObject var tab: RepoTab
    @AppStorage(GitPreferences.autoStageOnCommitKey) private var autoStageOnCommit = true

    private var canCommit: Bool {
        GitPreferences.canCommit(
            summary: tab.commitSummary,
            stagedCount: tab.stagedFiles.count,
            changedCount: tab.totalChangesCount,
            autoStage: autoStageOnCommit,
            isBusy: tab.isBusy,
            amend: tab.amendCommit
        )
    }

    private var localBranches: [BranchInfo] {
        tab.branches.filter { !$0.isRemote }
    }

    var body: some View {
        Button("Commit") { tab.commitChanges() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCommit)

        Divider()

        Button("Fetch") { tab.runRemote(.fetch) }
            .disabled(tab.isBusy)
        Button("Pull") { tab.runRemote(.pull) }
            .disabled(tab.isBusy)
        Button("Push") { tab.runRemote(.push) }
            .disabled(tab.isBusy)

        Divider()

        Button("Save Stash…") { tab.presentNewStash() }
            .disabled(tab.totalChangesCount == 0 || tab.isBusy)
        Menu("Checkout Branch") {
            if localBranches.isEmpty {
                Text("No Local Branches")
            } else {
                ForEach(localBranches, id: \.fullRef) { branch in
                    let otherWorktree = tab.worktrees.first {
                        $0.branch == branch.name && $0.path != tab.activeCheckoutPath
                    }
                    let label: String = if branch.isHead {
                        "✓ \(branch.name)"
                    } else if otherWorktree != nil {
                        "\(branch.name) (Worktree)"
                    } else {
                        branch.name
                    }
                    Button(label) {
                        if let wt = otherWorktree {
                            tab.switchCheckout(to: wt.path)
                        } else {
                            tab.checkoutBranch(branch.name)
                        }
                    }
                    .disabled(branch.isHead || tab.isBusy || (otherWorktree?.isPrunable == true))
                }
            }
        }
        .disabled(tab.isBusy)

        Divider()

        Button("New Branch…") { tab.activeSheet = .newBranch(startPoint: nil) }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(tab.isBusy)
        Button("New Tag…") { tab.activeSheet = .newTag(target: nil) }
            .disabled(tab.isBusy)
        Button("New Worktree…") { tab.activeSheet = .newWorktree(source: .head) }
            .disabled(tab.isBusy)
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
