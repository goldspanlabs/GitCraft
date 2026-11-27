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
    @Published private(set) var gitAvailability: GitAvailability = .available
    @Published private(set) var closedTabPaths: [String] = []

    /// Set to true by the app delegate when quitting, so windows closing during
    /// shutdown don't erase the saved list of open repositories.
    static var isTerminating = false

    private static let recentKey = "recentRepositories"
    /// The single recent repository older versions saved, read once and moved into `recentKey`.
    private static let legacyRecentKey = "recentRepository"
    private static let openTabsKey = "openRepositoryTabs"

    private var repoControllers: [RepoWindowController] = []
    private var welcomeControllers: [WelcomeWindowController] = []

    /// The repository shown in the frontmost GitCraft window.
    @Published private(set) var activeTab: RepoTab?

    private let gitAvailabilityProvider: @Sendable () -> GitAvailability
    private var hasDeferredTabRestore = false

    var hasOpenRepositories: Bool { !repoControllers.isEmpty }

    private nonisolated static var uiTestGitAvailabilityOverride: GitAvailability? {
        switch UserDefaults.standard.string(forKey: "UITestGitAvailability") {
        case "missing": return .missing
        case "needsCommandLineTools": return .needsCommandLineTools
        case "outdated": return .outdated
        case "available": return .available
        default: return nil
        }
    }

    init(gitAvailabilityProvider: @escaping @Sendable () -> GitAvailability = {
        WorkspaceState.uiTestGitAvailabilityOverride ?? checkGitAvailability()
    }) {
        self.gitAvailabilityProvider = gitAvailabilityProvider
        recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        if let legacy = UserDefaults.standard.string(forKey: Self.legacyRecentKey),
           !recentPaths.contains(legacy)
        {
            recentPaths.insert(legacy, at: 0)
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveTab()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveTab()
            }
        }
    }

    private func refreshActiveTab() {
        let current = (NSApp?.keyWindow?.windowController as? RepoWindowController)?.tab
        if activeTab !== current {
            activeTab = current
        }
    }

    func deferTabRestore() {
        hasDeferredTabRestore = true
    }

    @discardableResult
    func refreshGitAvailability() -> GitAvailability {
        let status = gitAvailabilityProvider()
        applyGitAvailability(status)
        return status
    }

    @discardableResult
    func refreshGitAvailabilityAsync() async -> GitAvailability {
        let provider = gitAvailabilityProvider
        let status = await Task.detached { provider() }.value
        applyGitAvailability(status)
        return status
    }

    private func applyGitAvailability(_ status: GitAvailability) {
        gitAvailability = status
        if status == .available, hasDeferredTabRestore {
            hasDeferredTabRestore = false
            _ = restoreTabs()
        }
    }

    func installCommandLineTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        try? process.run()
    }

    func openGitDownloadPage() {
        if let url = URL(string: "https://git-scm.com/downloads/mac") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reopens the repositories that were open when the app last quit.
    /// Returns true if it opened any.
    func restoreTabs() -> Bool {
        let saved = UserDefaults.standard.stringArray(forKey: Self.openTabsKey) ?? []
        var opened = false
        for path in saved where FileManager.default.fileExists(atPath: path) {
            if openRepository(at: URL(fileURLWithPath: path), validateGit: false) { opened = true }
        }
        return opened
    }

    /// True when git can be used. Otherwise shows the welcome window, which explains what is
    /// missing.
    private func requireGit() -> Bool {
        guard refreshGitAvailability() == .available else {
            ensureWelcomeVisible()
            return false
        }
        return true
    }

    /// Like `requireGit()`, checking for git off the main thread.
    private func requireGitAsync() async -> Bool {
        guard await refreshGitAvailabilityAsync() == .available else {
            ensureWelcomeVisible()
            return false
        }
        return true
    }

    @discardableResult
    func chooseRepository() -> Bool {
        requireGit() && presentOpenRepositoryPanel()
    }

    @discardableResult
    func chooseRepositoryAsync() async -> Bool {
        guard await requireGitAsync() else { return false }
        return presentOpenRepositoryPanel()
    }

    private func presentOpenRepositoryPanel() -> Bool {
        guard let url = pickFolder(prompt: "Open Repository", canCreateFolders: false) else { return false }
        return openRepository(at: url, validateGit: false)
    }

    enum NewRepositoryOutcome: Equatable {
        case opened
        /// The sheet was closed while the repository was being made, so it isn't opened.
        case cancelled
        case failed(String)
    }

    /// Runs `make`, which creates a repository at `path`, off the main thread, then opens it in a
    /// tab. `isCancelled` is asked once `make` has finished. `openFailure` is the message used
    /// when the new repository can't be opened and no better reason is known.
    func makeAndOpenRepository(
        at path: String,
        openFailure: String,
        isCancelled: () -> Bool,
        make: @escaping @Sendable () throws -> Void
    ) async -> NewRepositoryOutcome {
        do {
            try await Task.detached(priority: .userInitiated) { try make() }.value
        } catch {
            return .failed(error.displayMessage)
        }
        if isCancelled() { return .cancelled }
        return openRepository(at: URL(fileURLWithPath: path)) ? .opened : .failed(openError ?? openFailure)
    }

    /// Opens `url` in a new tab, or brings its existing tab to the front.
    @discardableResult
    func openRepository(at url: URL) -> Bool {
        openRepository(at: url, validateGit: true)
    }

    @discardableResult
    func openRepositoryAsync(at url: URL) async -> Bool {
        guard await requireGitAsync() else { return false }
        return openRepository(at: url, validateGit: false)
    }

    @discardableResult
    private func openRepository(at url: URL, validateGit: Bool) -> Bool {
        if validateGit, !requireGit() { return false }
        let resolvedPath = RepoTab.canonicalPath(for: url.path)
        let resolved = URL(fileURLWithPath: resolvedPath)
        if let existing = repoControllers.first(where: { $0.tab.contains(checkoutPath: resolvedPath) }) {
            reveal(existing, checkout: resolvedPath)
            return true
        }
        do {
            let tab = try RepoTab(url: resolved)
            if let existing = repoControllers.first(where: { $0.tab.repoPath == tab.repoPath }) {
                reveal(existing, checkout: tab.activeCheckoutPath)
                return true
            }
            openError = nil
            closedTabPaths.removeAll { $0 == resolvedPath || $0 == tab.activeCheckoutPath }
            recordRecent(path: tab.repoPath)
            let controller = RepoWindowController(tab: tab, workspace: self)
            repoControllers.append(controller)
            saveOpenTabs()
            tab.startWatcher()
            tab.refresh()
            controller.showInTabs()
            refreshActiveTab()
            return true
        } catch {
            openError = "Unable to open \(resolved.lastPathComponent): \(error.displayMessage)"
            return false
        }
    }

    /// Brings an existing tab to the front showing `checkout`, so opening a specific worktree
    /// folder lands on that checkout rather than whichever one the tab last showed.
    private func reveal(_ controller: RepoWindowController, checkout: String) {
        controller.reveal()
        let tab = controller.tab
        // Only switch to a checkout git lists; a subfolder or unknown path just reveals the tab.
        if tab.activeCheckoutPath != checkout, tab.worktrees.contains(where: { $0.path == checkout }) {
            tab.switchCheckout(to: checkout)
        }
    }

    func openWelcome() {
        addWelcomeController().showInTabs()
    }

    private func ensureWelcomeVisible() {
        guard NSApp != nil else { return }
        if let existing = welcomeControllers.first {
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            openWelcome()
        }
    }

    func openNewWindow() {
        addWelcomeController().showInNewWindow()
    }

    private func addWelcomeController() -> WelcomeWindowController {
        let controller = WelcomeWindowController(workspace: self)
        welcomeControllers.append(controller)
        refreshActiveTab()
        return controller
    }

    func restoreClosedTab() {
        guard requireGit() else { return }
        popAndRestoreClosedTab()
    }

    func restoreClosedTabAsync() async {
        guard await requireGitAsync() else { return }
        popAndRestoreClosedTab()
    }

    private func popAndRestoreClosedTab() {
        while let path = closedTabPaths.popLast() {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if openRepository(at: URL(fileURLWithPath: path), validateGit: false) {
                return
            }
        }
    }

    func clearRecentRepositories() {
        recentPaths = []
        guard !Self.isUITestRun else { return }
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyRecentKey)
    }

    func focusCommitFilter() {
        (NSApp.keyWindow?.windowController as? RepoWindowController)?.focusSearchField()
    }

    func closeActiveTab() {
        NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
    }

    func closeActiveWindow() {
        guard let window = NSApp.keyWindow else { return }
        if let group = window.tabGroup {
            for tabWindow in Array(group.windows) {
                tabWindow.performClose(nil)
            }
        } else {
            window.performClose(nil)
        }
    }

    func presentCreateRepositorySheet() {
        WindowTabs.presentSheet { dismiss in
            CreateRepositorySheet(workspace: self, onDismiss: dismiss)
        }
    }

    func presentCloneRepositorySheet() {
        WindowTabs.presentSheet { dismiss in
            CloneRepositorySheet(workspace: self, onDismiss: dismiss)
        }
    }

    func windowClosed(_ controller: RepoWindowController) {
        let closedPath = controller.tab.activeCheckoutPath
        controller.tab.stopWatcher()
        repoControllers.removeAll { $0 === controller }
        refreshActiveTab()
        if !Self.isTerminating {
            recordClosedTab(path: closedPath)
            saveOpenTabs()
        }
    }

    private func recordClosedTab(path: String) {
        closedTabPaths.removeAll { $0 == path }
        closedTabPaths.append(path)
        if closedTabPaths.count > 20 {
            closedTabPaths.removeFirst(closedTabPaths.count - 20)
        }
    }

    func welcomeClosed(_ controller: WelcomeWindowController) {
        welcomeControllers.removeAll { $0 === controller }
        refreshActiveTab()
    }

    /// UI tests open a throwaway fixture repository via `-UITestOpenRepository`. It must not leak
    /// into the user's recent repositories or the tabs restored on the next launch.
    private static var isUITestRun: Bool {
        UserDefaults.standard.string(forKey: "UITestOpenRepository") != nil
    }

    private func recordRecent(path: String) {
        guard !Self.isUITestRun else { return }
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
        guard !Self.isUITestRun else { return }
        UserDefaults.standard.set(repoControllers.map { $0.tab.activeCheckoutPath }, forKey: Self.openTabsKey)
    }
}
