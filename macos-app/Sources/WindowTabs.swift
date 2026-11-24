import AppKit
import Combine
import SwiftUI

/// Hands the hosting `NSWindow` to SwiftUI code once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

enum WindowTabs {
    static let identifier = "GitCraft.repository"

    /// Makes `window` a native macOS tab of an existing repository window, if there is one.
    /// Windows opened together (restoring several repositories) may not be on screen yet
    /// when the next one looks for a host, so the search is retried briefly.
    @MainActor
    static func joinRepositoryTabs(_ window: NSWindow, retries: Int = 6) {
        // GitCraft reopens its repositories itself; AppKit restoring the windows as well
        // brings every repository back twice.
        window.isRestorable = false
        window.tabbingIdentifier = identifier
        window.tabbingMode = .preferred
        guard window.tabbedWindows == nil else { return } // already tabbed
        let host = NSApp.windows.first {
            $0 !== window
                && $0.tabbingIdentifier == identifier
                && $0.tabbingMode == .preferred
                && !$0.isMiniaturized
                && ($0.tabbedWindows != nil || $0.isVisible)
        }
        if let host {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                joinRepositoryTabs(window, retries: retries - 1)
            }
        }
    }
}

/// Keeps a reference to a view's window. (SwiftUI `@State` can't be written from the
/// window accessor, which can fire before the view is installed.)
@MainActor
final class WindowHolder: ObservableObject {
    weak var window: NSWindow?
}

/// Connects a repository's `RepoTab` to its window: joins the tab group, shows the
/// clean/dirty dot on the tab, and releases the repository when the window closes.
@MainActor
final class RepoWindowBinding: ObservableObject {
    private var window: NSWindow?
    private var tab: RepoTab?
    private var closeObserver: NSObjectProtocol?
    private var changes: AnyCancellable?
    private let dot = TabStatusDot()
    private var onClose: ((RepoTab) -> Void)?

    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        WindowTabs.joinRepositoryTabs(window)
        window.tab.accessoryView = dot
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tab = self.tab else { return }
                self.onClose?(tab)
            }
        }
        updateTab()
    }

    func closeWindow() {
        window?.close()
    }

    func bind(tab: RepoTab, onClose: @escaping (RepoTab) -> Void) {
        guard self.tab !== tab else { return }
        self.tab = tab
        self.onClose = onClose
        changes = tab.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTab() }
        updateTab()
    }

    private func updateTab() {
        guard let tab else { return }
        dot.isDirty = tab.totalChangesCount > 0
        window?.tab.toolTip = tab.totalChangesCount > 0
            ? "\(tab.name): \(tab.totalChangesCount) uncommitted changes"
            : "\(tab.name): clean"
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}

/// Small coloured circle shown inside the tab: orange with uncommitted changes, green when clean.
final class TabStatusDot: NSView {
    var isDirty = false {
        didSet { if isDirty != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }

    override func draw(_ dirtyRect: NSRect) {
        (isDirty ? NSColor.systemOrange : NSColor.systemGreen).setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 6, height: 6)).fill()
    }
}
