import AppKit
import SwiftUI

/// Declarative entry for building AppKit `NSMenu`s without selector boilerplate.
enum MenuEntry {
    case item(String, enabled: Bool = true, action: () -> Void)
    case submenu(String, [MenuEntry])
    case separator
}

extension NSMenu {
    func populate(with entries: [MenuEntry]) {
        removeAllItems()
        autoenablesItems = false
        for entry in entries {
            switch entry {
            case let .item(title, enabled, action):
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let target = MenuAction(action)
                item.target = target
                item.representedObject = target // keeps the target alive while the menu is open
                item.isEnabled = enabled
                addItem(item)
            case let .submenu(title, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = NSMenu.build(from: children)
                addItem(item)
            case .separator:
                addItem(.separator())
            }
        }
    }

    static func build(from entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.populate(with: entries)
        return menu
    }
}

extension View {
    /// Right-click menu built on `NSMenu` rather than `.contextMenu`, so macOS does not
    /// append its "Ask Siri" item to text rows. Left-clicks and double-clicks pass through.
    func nativeContextMenu(_ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay(RightClickMenuArea(entries: entries))
    }
}

private struct RightClickMenuArea: NSViewRepresentable {
    let entries: () -> [MenuEntry]

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.entries = entries
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.entries = entries
    }
}

private final class RightClickView: NSView {
    var entries: () -> [MenuEntry] = { [] }

    /// Only claim right-clicks (and ctrl-clicks) so hover and left-clicks still reach
    /// the sidebar's native disclosure chevron underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown:
            return super.hitTest(point)
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu(for: event) } else { super.mouseDown(with: event) }
    }

    private func showMenu(for event: NSEvent) {
        let entries = entries()
        guard !entries.isEmpty else { return }
        let menu = NSMenu.build(from: entries)
        // popUp(...) rather than popUpContextMenu: the latter lets the system append
        // its own items (Ask Siri, Services).
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }
}

private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
