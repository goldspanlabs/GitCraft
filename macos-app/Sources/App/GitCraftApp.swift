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
    @ObservedObject private var workspace = WorkspaceState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { workspace.openNewWindow() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { workspace.openWelcome() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Restore Closed Tab") { workspace.restoreClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(workspace.closedTabPaths.isEmpty)

            Divider()

            Button("Create New Local Repository…") { workspace.presentCreateRepositorySheet() }
            Button("Clone…") { workspace.presentCloneRepositorySheet() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Open…") { workspace.chooseRepository() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                if workspace.recentPaths.isEmpty {
                    Text("No Recent Repositories")
                } else {
                    ForEach(workspace.recentPaths, id: \.self) { path in
                        Button(recentMenuLabel(for: path, among: workspace.recentPaths)) {
                            workspace.openRepository(at: URL(fileURLWithPath: path))
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
