import AppKit

/// The commit list's table. Adds Edit ▸ Copy (⌘C), which copies the selected commit's SHA.
final class CommitNSTableView: NSTableView, NSMenuItemValidation {
    /// The selected commit's SHA, or `nil` when the selection isn't a commit.
    var oidForCopy: () -> String? = { nil }
    var onCopy: (String) -> Void = { _ in }

    @objc func copy(_: Any?) {
        guard let oid = oidForCopy() else { return }
        onCopy(oid)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return oidForCopy() != nil
        case #selector(selectAll(_:)): return allowsMultipleSelection
        default: return true
        }
    }
}
