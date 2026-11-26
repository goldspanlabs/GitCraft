import AppKit
import XCTest
@testable import GitCraft

/// Edit ▸ Copy in the commit list.
final class CommitCopyTests: XCTestCase {
    @MainActor
    func testCopySendsTheSelectedOidAndDisablesWithoutOne() {
        let table = CommitNSTableView()
        var copied: [String] = []
        var oid: String?
        table.oidForCopy = { oid }
        table.onCopy = { copied.append($0) }
        let item = NSMenuItem(title: "Copy", action: #selector(CommitNSTableView.copy(_:)), keyEquivalent: "c")

        XCTAssertFalse(table.validateMenuItem(item))
        table.copy(nil)
        XCTAssertEqual(copied, [])

        oid = "abc123"
        XCTAssertTrue(table.validateMenuItem(item))
        table.copy(nil)
        XCTAssertEqual(copied, ["abc123"])
    }
}
