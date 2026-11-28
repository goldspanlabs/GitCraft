import AppKit
import SwiftUI

extension GitDragPayload {
    static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)

    var itemProvider: NSItemProvider {
        guard let data else { return NSItemProvider() }
        return NSItemProvider(item: data as NSData, typeIdentifier: Self.typeIdentifier)
    }

    static func read(from pasteboard: NSPasteboard) -> Self? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        return decode(data)
    }
}

/// SwiftUI and the AppKit table use the same payload and resolver. Reading the local drag
/// pasteboard synchronously lets us refuse invalid destinations before accepting a drop.
@MainActor
private struct GitSidebarDropDelegate: DropDelegate {
    let tab: RepoTab
    let target: GitDropTarget
    @Binding var highlighted: Bool

    private func resolution() -> GitDropResolution? {
        guard let payload = GitDragPayload.read(from: NSPasteboard(name: .drag)) else { return nil }
        return tab.gitDropResolution(payload, target: target, option: NSEvent.modifierFlags.contains(.option))
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [GitDragPayload.typeIdentifier])
    }

    func dropEntered(info: DropInfo) { update() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update()
        return DropProposal(operation: resolution()?.isAllowed == true ? .copy : .forbidden)
    }

    private func update() {
        let result = resolution()
        highlighted = result?.isAllowed == true
        tab.gitDragHint = result?.hint
    }

    func dropExited(info: DropInfo) {
        highlighted = false
        tab.gitDragHint = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        highlighted = false
        tab.gitDragHint = nil
        guard let payload = GitDragPayload.read(from: NSPasteboard(name: .drag)),
              resolution()?.isAllowed == true else { return false }
        tab.receiveGitDrop(payload, target: target, option: NSEvent.modifierFlags.contains(.option))
        return true
    }
}

private struct GitDropTargetModifier: ViewModifier {
    @ObservedObject var tab: RepoTab
    let target: GitDropTarget
    @State private var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.accentColor.opacity(0.2) : .clear))
            .onDrop(of: [GitDragPayload.typeIdentifier],
                    delegate: GitSidebarDropDelegate(tab: tab, target: target, highlighted: $highlighted))
    }
}

extension View {
    func gitDropTarget(tab: RepoTab, target: GitDropTarget) -> some View {
        modifier(GitDropTargetModifier(tab: tab, target: target))
    }
}
