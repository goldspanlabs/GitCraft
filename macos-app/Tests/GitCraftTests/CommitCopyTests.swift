import AppKit
import XCTest
@testable import GitCraft

/// Edit ▸ Copy in the commit list.
final class CommitCopyTests: XCTestCase {
    @MainActor
    func testCopySendsTheSelectedOidsAndDisablesWithoutAny() {
        let table = CommitNSTableView()
        var copied: [[String]] = []
        var oids: [String] = []
        table.oidsForCopy = { oids }
        table.onCopy = { copied.append($0) }
        let item = NSMenuItem(title: "Copy", action: #selector(CommitNSTableView.copy(_:)), keyEquivalent: "c")

        XCTAssertFalse(table.validateMenuItem(item))
        table.copy(nil)
        XCTAssertEqual(copied, [])

        oids = ["abc123", "def456"]
        XCTAssertTrue(table.validateMenuItem(item))
        table.copy(nil)
        XCTAssertEqual(copied, [["abc123", "def456"]])
    }

    @MainActor
    func testRestoringNothingClearsTheOldRows() {
        final class Rows: NSObject, NSTableViewDataSource {
            func numberOfRows(in _: NSTableView) -> Int { 4 }
        }
        let source = Rows()
        let table = NSTableView()
        table.allowsMultipleSelection = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit")))
        table.dataSource = source
        table.reloadData()
        table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)

        // Every selected commit was rewritten, so none of the new rows matches.
        table.reloadData()
        CommitTableView.Coordinator.restoreSelection(in: table, oids: ["x", "y", "z"], selected: ["gone"], workingChanges: false)

        XCTAssertTrue(table.selectedRowIndexes.isEmpty)

        CommitTableView.Coordinator.restoreSelection(in: table, oids: ["x", "y", "z"], selected: ["y"], workingChanges: false)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 2))
        CommitTableView.Coordinator.restoreSelection(in: table, oids: ["x", "y", "z"], selected: [], workingChanges: true)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
    }

    func testWorkingChangesIsNeverPartOfAMultiSelection() {
        typealias Coordinator = CommitTableView.Coordinator

        XCTAssertEqual(Coordinator.allowedSelection(IndexSet([0, 1, 2])), IndexSet([1, 2]))
        XCTAssertEqual(Coordinator.allowedSelection(IndexSet([0, 3])), IndexSet([3]))
        XCTAssertEqual(Coordinator.allowedSelection(IndexSet([0])), IndexSet([0]))
        XCTAssertEqual(Coordinator.allowedSelection(IndexSet([2, 4])), IndexSet([2, 4]))
    }
}
