import AppKit
import Combine
import SwiftUI

extension NSToolbarItem.Identifier {
    static let repoTitle = NSToolbarItem.Identifier("GitCraft.repoTitle")
    static let repoActions = NSToolbarItem.Identifier("GitCraft.repoActions")
    static let repoSpinner = NSToolbarItem.Identifier("GitCraft.repoSpinner")
    static let repoSearch = NSToolbarItem.Identifier("GitCraft.repoSearch")
}

enum WindowTabs {
    static let identifier = "GitCraft.repository"

    /// Shows `window`, as a native tab of an existing GitCraft window if there is one
    /// (unless `inNewWindow` is true).
    @MainActor
    static func show(_ window: NSWindow, inNewWindow: Bool = false) {
        window.isRestorable = false // GitCraft reopens its own repositories at launch
        window.tabbingIdentifier = identifier
        window.tabbingMode = .preferred
        let host: NSWindow?
        if inNewWindow {
            host = nil
        } else {
            let isEligible: (NSWindow) -> Bool = {
                $0 !== window
                    && $0.tabbingIdentifier == identifier
                    && $0.tabbingMode == .preferred
                    && $0.isVisible
                    && !$0.isMiniaturized
            }
            host = NSApp.keyWindow.flatMap { isEligible($0) ? $0 : nil }
                ?? NSApp.windows.first(where: isEligible)
        }
        if let host {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Presents a SwiftUI view as a sheet on the key window, or as a standalone window if none is open.
    @MainActor
    static func presentSheet<Content: View>(
        @ViewBuilder content: @escaping (_ dismiss: @escaping () -> Void) -> Content
    ) {
        let controller = NSWindowController()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        controller.window = panel

        let parent = NSApp.keyWindow
        // Retain the controller until the sheet/window finishes closing.
        var retained: NSWindowController? = controller
        var closeObserver: NSObjectProtocol?
        let release: () -> Void = {
            if let observer = closeObserver {
                NotificationCenter.default.removeObserver(observer)
                closeObserver = nil
            }
            retained = nil
            _ = retained
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            release()
        }
        let dismiss: () -> Void = {
            if let parent {
                parent.endSheet(panel)
            } else {
                panel.close()
            }
            release()
        }

        let hosting = NSHostingController(rootView: AppearanceScoped { content(dismiss) })
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)

        if let parent {
            parent.beginSheet(panel) { _ in
                release()
            }
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Brings the tab holding `window` to the front.
    @MainActor
    static func reveal(_ window: NSWindow) {
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// A window that macOS groups with the app's other windows as tabs. The tab bar's "+" opens
/// a new Repository Manager tab.
@MainActor
class WorkspaceWindowController: NSWindowController {
    unowned let workspace: WorkspaceState

    init(window: NSWindow, workspace: WorkspaceState) {
        self.workspace = workspace
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func showInTabs() { WindowTabs.show(window!) }
    func showInNewWindow() { WindowTabs.show(window!, inNewWindow: true) }

    /// The tab bar's "+" button asks the responder chain for this.
    @objc override func newWindowForTab(_: Any?) {
        workspace.openWelcome()
    }
}

/// One repository: an AppKit window (sidebar + detail in an `NSSplitViewController`, an
/// `NSToolbar`) that macOS groups with the other repository windows as native tabs.
@MainActor
final class RepoWindowController: WorkspaceWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let tab: RepoTab
    /// Width of the repository / branch text: a fraction of the window width, clamped to this range,
    /// and narrower still (down to the minimum) when it would push the action buttons off centre.
    private static let titleTextWidthRange: ClosedRange<CGFloat> = 200...360
    private static let titleTextWidthFraction: CGFloat = 0.2
    private static let titleTextMinimumWidth: CGFloat = 60
    /// Everything in the title block besides the text: its edge insets.
    private static let titleChromeWidth: CGFloat = 16
    /// Space the toolbar keeps between the title block and the action buttons. macOS 26 needs
    /// 16; with less it pushes the buttons off centre.
    private static let titleActionsGap: CGFloat = 16
    /// Below this width of top bar (the window, less a showing sidebar) the filter is just a button.
    private static let searchCollapseWidth: CGFloat = 1100
    /// A search field held this narrow makes `NSSearchToolbarItem` show its button instead.
    private static let collapsedSearchWidth: CGFloat = 36
    private var titleWidthConstraints: [NSLayoutConstraint] = []
    private var searchCollapseConstraint: NSLayoutConstraint?
    private var isOpeningSearch = false
    private weak var titleRow: NSView?
    private weak var actionsView: NSView?
    private let sidebarItem: NSSplitViewItem
    private var sidebarResizes: AnyCancellable?
    private let dot = TabStatusDot()
    private let spinner: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()
    private let subtitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()
    private var changes: AnyCancellable?
    private var firstResponderObservation: NSKeyValueObservation?
    private var searchField: NSSearchField?

    init(tab: RepoTab, workspace: WorkspaceState) {
        self.tab = tab

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
        self.sidebarItem = sidebarItem

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(Self.savedContentSize())
        window.contentMinSize = NSSize(width: 1040, height: 680)
        window.title = tab.checkoutName
        window.subtitle = tab.currentBranch

        super.init(window: window, workspace: workspace)
        window.delegate = self
        tab.onCheckoutChanged = { [weak self] in self?.workspace.saveOpenTabs() }
        window.tab.accessoryView = tab.totalChangesCount > 0 ? dot : nil

        let toolbar = NSToolbar(identifier: "GitCraft.repoToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [.repoActions]
        window.toolbar = toolbar
        window.titleVisibility = .hidden

        // The title block starts at the sidebar's edge, so its room changes with the sidebar.
        sidebarResizes = NotificationCenter.default
            .publisher(for: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateToolbarLayout() }

        changes = tab.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshChrome() }
        refreshChrome()

        // Names the repository step in Edit ▸ Undo only while no text has the keyboard.
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            let editing = window.firstResponder is NSText
            DispatchQueue.main.async {
                // Expands the filter as soon as its button puts the cursor in it.
                self?.updateSearchCollapse()
                guard let self, self.tab.isEditingText != editing else { return }
                self.tab.isEditingText = editing
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func reveal() { WindowTabs.reveal(window!) }

    /// Puts the cursor in the toolbar's commit filter, expanding it if the toolbar collapsed it.
    func focusSearchField() {
        guard let window,
              let search = window.toolbar?.items.first(where: { $0.itemIdentifier == .repoSearch }) as? NSSearchToolbarItem
        else { return }

        expandSearchField()
        let field = search.searchField
        // AppKit can finish focusing after its animation starts. If the field is visible,
        // give it the keyboard now so the next keystroke reaches the filter.
        if field.window === window, !field.isHiddenOrHasHiddenAncestor,
           window.makeFirstResponder(field), let editor = field.currentEditor() {
            editor.selectAll(nil)
        } else {
            search.beginSearchInteraction()
        }
    }

    private func refreshChrome() {
        window?.title = tab.checkoutName
        window?.subtitle = tab.currentBranch
        titleLabel.stringValue = tab.checkoutName
        subtitleLabel.stringValue = tab.currentBranch
        // Middle truncation hides part of the name, so the tooltip carries the full text.
        titleLabel.toolTip = tab.checkoutName
        subtitleLabel.toolTip = tab.currentBranch
        if tab.isBusy {
            spinner.startAnimation(nil)
            let label = tab.busyLabel ?? "Working…"
            spinner.toolTip = label
            spinner.setAccessibilityLabel(label)
            spinner.setAccessibilityElement(true)
        } else {
            spinner.stopAnimation(nil)
            spinner.toolTip = nil
            spinner.setAccessibilityLabel(nil)
            spinner.setAccessibilityElement(false)
        }
        dot.isDirty = true
        window?.tab.accessoryView = tab.totalChangesCount > 0 ? dot : nil
        window?.tab.toolTip = tab.totalChangesCount > 0
            ? "\(tab.checkoutName): \(tab.totalChangesCount) uncommitted changes"
            : "\(tab.checkoutName): clean"
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

    private func updateToolbarLayout() {
        updateTitleWidth()
        updateSearchCollapse()
    }

    /// Where the top bar starts: the sidebar's edge, or the window's while the sidebar is hidden.
    private var topBarLeadingEdge: CGFloat {
        let sidebar = sidebarItem.viewController.view
        return sidebarItem.isCollapsed ? 0 : sidebar.convert(sidebar.bounds, to: nil).maxX
    }

    /// Shrinks the filter to a button on a narrow window, unless it's being typed in or holds a filter.
    private func updateSearchCollapse() {
        guard let window, let field = searchField, let constraint = searchCollapseConstraint else { return }
        let isEditing = field.currentEditor() != nil
        if isEditing { isOpeningSearch = false }
        let collapsed = window.frame.width - topBarLeadingEdge < Self.searchCollapseWidth
            && !isOpeningSearch
            && !isEditing
            && field.stringValue.isEmpty
        if constraint.isActive != collapsed { constraint.isActive = collapsed }
    }

    /// Lifts the collapsed width ahead of a search: macOS 26 won't put the cursor in a field
    /// still held to the size of its button.
    private func expandSearchField() {
        guard !isOpeningSearch else { return }
        // Window updates can run during layout and before AppKit installs the field editor.
        isOpeningSearch = true
        searchCollapseConstraint?.isActive = false
        window?.layoutIfNeeded()
    }

    func windowDidResignKey(_: Notification) {
        isOpeningSearch = false
        updateSearchCollapse()
    }

    /// Scales the title block with the window, so it is the same for every name at a given width,
    /// and keeps it short of the centred action buttons.
    private func updateTitleWidth() {
        let windowWidth = window?.frame.width ?? 0
        var width = min(max(windowWidth * Self.titleTextWidthFraction, Self.titleTextWidthRange.lowerBound),
                        Self.titleTextWidthRange.upperBound)
        if let row = titleRow, row.window != nil, let actions = actionsView {
            let leading = row.convert(row.bounds, to: nil).minX
            // AppKit centres the buttons over what's right of the sidebar, or the whole
            // window when the sidebar is hidden.
            let actionsLeading = (topBarLeadingEdge + windowWidth - actions.fittingSize.width) / 2
            let room = actionsLeading - leading - Self.titleActionsGap - Self.titleChromeWidth
            width = max(min(width, room.rounded(.down)), Self.titleTextMinimumWidth)
        }
        for constraint in titleWidthConstraints where constraint.constant != width {
            constraint.constant = width
        }
    }

    /// Catches the first toolbar layout, which neither a window nor a sidebar resize reports.
    func windowDidUpdate(_: Notification) {
        updateToolbarLayout()
    }

    func windowDidResize(_ notification: Notification) {
        updateToolbarLayout()
        guard let window = notification.object as? NSWindow,
              !window.styleMask.contains(.fullScreen)
        else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .repoTitle, .flexibleSpace, .repoActions, .flexibleSpace, .repoSpinner, .repoSearch]
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
        case .repoTitle:
            // The window title is drawn here (the system one is hidden).
            let text = NSStackView(views: [titleLabel, subtitleLabel])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0

            let row = NSStackView(views: [text])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
            // Fixed width (not a maximum) so the title block doesn't change with the name length.
            // Low compression resistance lets long names truncate in the middle, like the sidebar.
            titleWidthConstraints = [titleLabel, subtitleLabel].map { label in
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let constraint = label.widthAnchor.constraint(equalToConstant: Self.titleTextWidthRange.lowerBound)
                constraint.isActive = true
                return constraint
            }
            titleRow = row
            updateTitleWidth()

            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = row
            item.isBordered = false
            item.label = "Repository"
            return item
        case .repoActions:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let (workspace, tab) = (self.workspace, self.tab)
            let hosting = NSHostingView(rootView: AppearanceScoped {
                RepoToolbarActionsView(workspace: workspace, tab: tab)
            })
            item.view = hosting
            item.isBordered = false
            item.label = "Actions"
            actionsView = hosting
            return item
        case .repoSpinner:
            // Fixed-size slot: the layout doesn't shift when the spinner comes and goes.
            let slot = NSView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(spinner)
            NSLayoutConstraint.activate([
                slot.widthAnchor.constraint(equalToConstant: 16),
                slot.heightAnchor.constraint(equalToConstant: 16),
                spinner.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            ])

            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = slot
            item.isBordered = false
            item.label = "Busy"
            return item
        case .repoSearch:
            let item = CommitFilterToolbarItem(itemIdentifier: identifier)
            item.willBeginSearch = { [weak self] in self?.expandSearchField() }
            item.searchField.placeholderString = "Filter commits"
            item.searchField.stringValue = tab.searchQuery
            item.searchField.delegate = self
            item.label = "Filter"
            searchField = item.searchField
            searchCollapseConstraint = item.searchField.widthAnchor
                .constraint(lessThanOrEqualToConstant: Self.collapsedSearchWidth)
            updateSearchCollapse()
            return item
        default:
            return nil
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        tab.updateSearchDebounced(field.stringValue)
    }
}

/// The commit filter, which says when a search is about to begin, from its button or a command.
private final class CommitFilterToolbarItem: NSSearchToolbarItem {
    var willBeginSearch: (() -> Void)?

    override func beginSearchInteraction() {
        willBeginSearch?()
        super.beginSearchInteraction()
    }
}

/// The "Repository Manager" tab: open a repository or pick a recent one.
@MainActor
final class WelcomeWindowController: WorkspaceWindowController, NSWindowDelegate {
    init(workspace: WorkspaceState) {
        let window = NSWindow(contentViewController: NSViewController())
        super.init(window: window, workspace: workspace)

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

    func windowWillClose(_: Notification) {
        workspace.welcomeClosed(self)
    }
}

private struct WelcomeWindowContent: View {
    @ObservedObject var workspace: WorkspaceState
    let onOpened: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner(checker: .shared)
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
