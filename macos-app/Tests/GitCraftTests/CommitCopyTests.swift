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

    func testWorkingChangesIsNeverPartOfAMultiSelection() {
        typealias Coordinator = CommitTableView.Coordinator

        XCTAssertEqual(Coordinator.allowedSelection(IndexSet([0, 1, 2])), IndexSet([1, 2]))
        XCTAssertEqual(Coordinator.allowedSelection(IndexSet([0, 3])), IndexSet([3]))
        XCTAssertEqual(Coordinator.allowedSelection(IndexSet([0])), IndexSet([0]))
        XCTAssertEqual(Coordinator.allowedSelection(IndexSet([2, 4])), IndexSet([2, 4]))
    }
}
