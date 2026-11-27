import AppKit

/// The commit list's table. Adds Edit ▸ Copy (⌘C), which copies the selected commits' SHAs.
final class CommitNSTableView: NSTableView, NSMenuItemValidation {
    /// The selected commits' SHAs in list order; empty when the selection has no commit.
    var oidsForCopy: () -> [String] = { [] }
    var onCopy: ([String]) -> Void = { _ in }
    var onClickWorkingChanges: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let isPlainClick = event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        if clickedRow == 0 && isPlainClick {
            onClickWorkingChanges()
        }
        super.mouseDown(with: event)
    }

    @objc func copy(_: Any?) {
        let oids = oidsForCopy()
        guard !oids.isEmpty else { return }
        onCopy(oids)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return !oidsForCopy().isEmpty
        case #selector(selectAll(_:)): return allowsMultipleSelection
        default: return true
        }
    }
}
