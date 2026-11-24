import AppKit
import Combine
import SwiftUI

extension NSToolbarItem.Identifier {
    static let repoActions = NSToolbarItem.Identifier("GitCraft.repoActions")
    static let repoSearch = NSToolbarItem.Identifier("GitCraft.repoSearch")
}

enum WindowTabs {
    static let identifier = "GitCraft.repository"

    /// Shows `window`, as a native tab of an existing GitCraft window if there is one.
    @MainActor
    static func show(_ window: NSWindow) {
        window.isRestorable = false // GitCraft reopens its own repositories at launch
        window.tabbingIdentifier = identifier
        window.tabbingMode = .preferred
        let host = NSApp.windows.first {
            $0 !== window
                && $0.tabbingIdentifier == identifier
                && $0.tabbingMode == .preferred
                && $0.isVisible
                && !$0.isMiniaturized
        }
        if let host {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Brings the tab holding `window` to the front.
    @MainActor
    static func reveal(_ window: NSWindow) {
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// One repository: an AppKit window (sidebar + detail in an `NSSplitViewController`, an
/// `NSToolbar`) that macOS groups with the other repository windows as native tabs.
@MainActor
final class RepoWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let tab: RepoTab
    private unowned let workspace: WorkspaceState
    private let dot = TabStatusDot()
    private var changes: AnyCancellable?
    private var searchField: NSSearchField?

    init(tab: RepoTab, workspace: WorkspaceState) {
        self.tab = tab
        self.workspace = workspace

        let sidebar = NSHostingController(rootView: AppearanceScoped { SidebarView(tab: tab) })
        sidebar.sizingOptions = []
        let detail = NSHostingController(rootView: AppearanceScoped {
            RepoDetailView(workspace: workspace, tab: tab)
        })
        detail.sizingOptions = []

        let split = NSSplitViewController()
        // macOS remembers the sidebar's collapsed state and width under this name.
        split.splitView.autosaveName = "GitCraft.repoSplit"
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 340
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(Self.savedContentSize())
        window.contentMinSize = NSSize(width: 1040, height: 680)
        window.title = tab.name
        window.subtitle = tab.currentBranch

        super.init(window: window)
        window.delegate = self
        window.tab.accessoryView = tab.totalChangesCount > 0 ? dot : nil

        let toolbar = NSToolbar(identifier: "GitCraft.repoToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        changes = tab.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshChrome() }
        refreshChrome()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func showInTabs() { WindowTabs.show(window!) }
    func reveal() { WindowTabs.reveal(window!) }

    private func refreshChrome() {
        window?.title = tab.name
        window?.subtitle = tab.currentBranch
        dot.isDirty = true
        window?.tab.accessoryView = tab.totalChangesCount > 0 ? dot : nil
        window?.tab.toolTip = tab.totalChangesCount > 0
            ? "\(tab.name): \(tab.totalChangesCount) uncommitted changes"
            : "\(tab.name): clean"
    }

    /// The tab bar's "+" button asks the responder chain for this.
    @objc override func newWindowForTab(_: Any?) {
        workspace.openWelcome()
    }

    func windowWillClose(_: Notification) {
        workspace.windowClosed(self)
    }

    // MARK: Window size (position is intentionally not remembered)

    private static let sizeKey = "repoWindowContentSize"

    private static func savedContentSize() -> NSSize {
        let fallback = NSSize(width: 1180, height: 760)
        guard let text = UserDefaults.standard.string(forKey: sizeKey) else { return fallback }
        let size = NSSizeFromString(text)
        return size.width >= 1040 && size.height >= 680 ? size : fallback
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !window.styleMask.contains(.fullScreen)
        else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .repoActions, .flexibleSpace, .repoSearch]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .repoActions:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let (workspace, tab) = (self.workspace, self.tab)
            let hosting = NSHostingView(rootView: AppearanceScoped {
                RepoToolbarActionsView(workspace: workspace, tab: tab)
            })
            item.view = hosting
            item.isBordered = false
            item.label = "Actions"
            return item
        case .repoSearch:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = "Filter commits"
            item.searchField.stringValue = tab.searchQuery
            item.searchField.delegate = self
            item.label = "Filter"
            searchField = item.searchField
            return item
        default:
            return nil
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        tab.updateSearch(field.stringValue)
    }
}

/// The "Repository Manager" tab: open a repository or pick a recent one.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private unowned let workspace: WorkspaceState

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        let window = NSWindow(contentViewController: NSViewController())
        super.init(window: window)

        let root = AppearanceScoped { [weak self] in
            WelcomeWindowContent(workspace: workspace) { self?.window?.close() }
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.contentMinSize = NSSize(width: 1040, height: 680)
        window.title = "Repository Manager"
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func showInTabs() { WindowTabs.show(window!) }

    func windowWillClose(_: Notification) {
        workspace.welcomeClosed(self)
    }

    @objc override func newWindowForTab(_: Any?) {
        workspace.openWelcome()
    }
}

private struct WelcomeWindowContent: View {
    @ObservedObject var workspace: WorkspaceState
    let onOpened: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = workspace.openError {
                ErrorBannerView(message: error) { workspace.openError = nil }
            }
            WelcomeView(workspace: workspace, onOpened: onOpened)
        }
    }
}

/// Small orange circle shown inside the tab while the repository has uncommitted changes.
/// It is removed from the tab entirely when the working tree is clean.
final class TabStatusDot: NSView {
    var isDirty = false {
        didSet { if isDirty != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 6, height: 6)).fill()
    }
}
