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
        // UI tests that don't open a fixture still must not reach GitHub.
        if UserDefaults.standard.string(forKey: "UITestGitAvailability") == nil {
            Task { await UpdateChecker.shared.checkAutomatically() }
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
        CommandGroup(replacing: .appInfo) {
            Button("About GitCraft") {
                // A blank build number leaves just "Version x.y.z" in the About window.
                NSApp.orderFrontStandardAboutPanel(options: [.version: ""])
            }
            Button("Check for Updates…") {
                Task { await UpdatePrompt.checkNow() }
            }
        }
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
            Button("Close Tab") { workspace.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            UndoRedoMenuItems(tab: workspace.activeTab)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Filter Commits") { workspace.focusCommitFilter() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace.activeTab == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh") { workspace.activeTab?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workspace.activeTab == nil)
            Divider()
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            GraphFilterMenuItems(tab: workspace.activeTab)
            Divider()
            NavigationMenuItems(tab: workspace.activeTab)
            Divider()
            BottomPanelMenuItems(tab: workspace.activeTab)
        }
        CommandMenu("Repository") {
            RepositoryMenuItems(tab: workspace.activeTab)
        }
    }

    private func recentMenuLabel(for path: String, among paths: [String]) -> String {
        let name = path.folderName
        let hasDuplicate = paths.filter { URL(fileURLWithPath: $0).lastPathComponent == name }.count > 1
        guard hasDuplicate else { return name }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shortParent = parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
        return "\(name) — \(shortParent)"
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
