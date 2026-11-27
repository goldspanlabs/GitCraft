import AppKit
import XCTest
@testable import GitCraft

final class GraphLayoutTests: XCTestCase {
    // leftPadding (4) * 2 + one lane (14) = 22 for a single lane.
    func testSingleLaneWidth() {
        XCTAssertEqual(GraphCellView.width(forLanes: 1), 22)
    }

    func testZeroLanesReservesTheSameSpaceAsOneLane() {
        XCTAssertEqual(GraphCellView.width(forLanes: 0), GraphCellView.width(forLanes: 1))
    }

    func testEachAdditionalLaneAddsOneLaneWidth() {
        let perLane = GraphCellView.width(forLanes: 3) - GraphCellView.width(forLanes: 2)
        XCTAssertEqual(perLane, 14)
        XCTAssertEqual(GraphCellView.width(forLanes: 3), 50)
    }

    func testManyLanesTruncateSummaryAndKeepRightColumnsUnobscured() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 26))
        let cell = CommitRowCellView(identifier: NSUserInterfaceItemIdentifier("test"))
        cell.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            cell.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            cell.topAnchor.constraint(equalTo: host.topAnchor),
            cell.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: 800),
            host.heightAnchor.constraint(equalToConstant: 26),
        ])

        // 15 lanes = 218pt graph, leaving ~162pt for a truncated summary on an 800pt row.
        let commit = CommitRow(
            oidHex: "abc1234",
            shortOid: "abc1234",
            summary: "feat: this is a very long commit summary that should truncate before the author column",
            authorName: "Alice Chen",
            authorEmail: "alice@example.com",
            timestamp: 1_700_000_000,
            lane: 0,
            colorIdx: 0,
            maxLanes: 15,
            edges: [],
            refs: [],
            isRemoteOnly: false,
            isUnpushed: false
        )
        cell.configure(commit: commit, hasIncomingLine: false)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(cell.leadingContentFrame.maxX, cell.authorFrame.minX)
        XCTAssertLessThanOrEqual(cell.summaryFrame.maxX, cell.leadingContentFrame.width + 2.5)
        XCTAssertEqual(cell.timeFrame.maxX, 790, accuracy: 2.5)
    }

    func testExtremeLanesClipLeadingContentBehindRightColumns() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 26))
        let cell = CommitRowCellView(identifier: NSUserInterfaceItemIdentifier("test"))
        cell.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            cell.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            cell.topAnchor.constraint(equalTo: host.topAnchor),
            cell.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: 700),
            host.heightAnchor.constraint(equalToConstant: 26),
        ])

        // 80 lanes = 1128pt graph, wider than the entire 700pt cell.
        let commit = CommitRow(
            oidHex: "def5678",
            shortOid: "def5678",
            summary: "fix: graph overflow should be clipped by right-hand columns",
            authorName: "Bob Martinez",
            authorEmail: "bob@example.com",
            timestamp: 1_700_000_000,
            lane: 0,
            colorIdx: 1,
            maxLanes: 80,
            edges: [],
            refs: [],
            isRemoteOnly: false,
            isUnpushed: false
        )
        cell.configure(commit: commit, hasIncomingLine: false)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(cell.leadingContentClipsToBounds)
        XCTAssertLessThanOrEqual(cell.leadingContentFrame.maxX, cell.authorFrame.minX)
        XCTAssertEqual(cell.timeFrame.maxX, 690, accuracy: 2.5)
    }
}
