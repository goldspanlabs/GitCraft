import AppKit
import SwiftUI

enum RemoteOperation {
    case fetch, pull, push
}

/// App-wide state shared by every repository window. Each repository lives in its own
/// `RepoWindowController` window; macOS groups those windows into native tabs.
@MainActor
final class WorkspaceState: ObservableObject {
    static let shared = WorkspaceState()

    @Published var recentPaths: [String] = []
    @Published var openError: String?

    /// Set to true by the app delegate when quitting, so windows closing during
    /// shutdown don't erase the saved list of open repositories.
    static var isTerminating = false

    private static let recentKey = "recentRepositories"
    private static let openTabsKey = "openRepositoryTabs"

    private var repoControllers: [RepoWindowController] = []
    private var welcomeControllers: [WelcomeWindowController] = []

    /// The repository shown in the frontmost GitCraft window.
    var activeTab: RepoTab? {
        (NSApp.keyWindow?.windowController as? RepoWindowController)?.tab
    }

    init() {
        recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        if let legacy = UserDefaults.standard.string(forKey: "recentRepository"),
           !recentPaths.contains(legacy)
        {
            recentPaths.insert(legacy, at: 0)
        }
    }

    /// Reopens the repositories that were open when the app last quit.
    /// Returns true if it opened any.
    func restoreTabs() -> Bool {
        let saved = UserDefaults.standard.stringArray(forKey: Self.openTabsKey) ?? []
        var opened = false
        for path in saved where FileManager.default.fileExists(atPath: path) {
            if openRepository(at: URL(fileURLWithPath: path)) { opened = true }
        }
        return opened
    }

    @discardableResult
    func chooseRepository() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return openRepository(at: url)
    }

    /// Opens `url` in a new tab, or brings its existing tab to the front.
    @discardableResult
    func openRepository(at url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = repoControllers.first(where: { $0.tab.contains(checkoutPath: resolved.path) }) {
            existing.reveal()
            return true
        }
        do {
            let tab = try RepoTab(url: resolved)
            if let existing = repoControllers.first(where: { $0.tab.repoPath == tab.repoPath }) {
                existing.reveal()
                return true
            }
            openError = nil
            recordRecent(path: tab.repoPath)
            let controller = RepoWindowController(tab: tab, workspace: self)
            repoControllers.append(controller)
            saveOpenTabs()
            tab.startWatcher()
            tab.refresh()
            controller.showInTabs()
            return true
        } catch {
            openError = "Unable to open \(resolved.lastPathComponent): \(error.displayMessage)"
            return false
        }
    }

    func openWelcome() {
        let controller = WelcomeWindowController(workspace: self)
        welcomeControllers.append(controller)
        controller.showInTabs()
    }

    func windowClosed(_ controller: RepoWindowController) {
        controller.tab.stopWatcher()
        repoControllers.removeAll { $0 === controller }
        if !Self.isTerminating {
            saveOpenTabs()
        }
    }

    func welcomeClosed(_ controller: WelcomeWindowController) {
        welcomeControllers.removeAll { $0 === controller }
    }

    private func recordRecent(path: String) {
        var updated = recentPaths.filter { $0 != path }
        updated.insert(path, at: 0)
        if updated.count > 8 {
            updated = Array(updated.prefix(8))
        }
        recentPaths = updated
        UserDefaults.standard.set(updated, forKey: Self.recentKey)
    }

    /// Saves the checkout each open tab shows, so relaunch returns to the same worktree.
    func saveOpenTabs() {
        UserDefaults.standard.set(repoControllers.map { $0.tab.activeCheckoutPath }, forKey: Self.openTabsKey)
    }
}
