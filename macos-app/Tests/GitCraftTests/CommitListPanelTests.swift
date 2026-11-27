import AppKit
import XCTest
@testable import GitCraft

/// The scrolling commit list in the Squash and force push sheets.
final class CommitListPanelTests: XCTestCase {
    func testAShortListIsAsTallAsItsRows() {
        XCTAssertEqual(CommitListPanel.listHeight(rows: 3, limit: 6), 60)
        XCTAssertEqual(CommitListPanel.listHeight(rows: 6, limit: 6), 120)
    }

    func testAnOverflowingListCutsARowInHalfToShowThereIsMore() {
        XCTAssertEqual(CommitListPanel.listHeight(rows: 7, limit: 6), 130)
        XCTAssertEqual(CommitListPanel.listHeight(rows: 90, limit: 6), 130)
    }

    @MainActor
    func testTheScrollbarShowsOnlyWhileHoveringAnOverflowingList() throws {
        let list = HoverScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        list.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        list.layoutSubtreeIfNeeded()
        let scroller = try XCTUnwrap(list.verticalScroller)

        XCTAssertTrue(scroller.isHidden)
        list.isHovered = true
        XCTAssertFalse(scroller.isHidden)
        list.isHovered = false
        XCTAssertTrue(scroller.isHidden)
    }

    @MainActor
    func testAListThatFitsNeverShowsAScrollbar() {
        let list = HoverScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        list.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))

        list.isHovered = true

        XCTAssertTrue(list.verticalScroller?.isHidden ?? true)
    }
}
