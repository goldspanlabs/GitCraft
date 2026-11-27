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

    func testCoordinatorVirtualizedRowCountAndWindowCache() {
        let initialRow = CommitRow(
            oidHex: "aaa0000",
            shortOid: "aaa0000",
            summary: "Initial",
            authorName: "Alice",
            authorEmail: "alice@example.com",
            timestamp: 1_700_000_000,
            lane: 0,
            colorIdx: 0,
            maxLanes: 1,
            edges: [],
            refs: [],
            isRemoteOnly: false,
            isUnpushed: false
        )
        let deepRow = CommitRow(
            oidHex: "bbb9999",
            shortOid: "bbb9999",
            summary: "Deep commit",
            authorName: "Bob",
            authorEmail: "bob@example.com",
            timestamp: 1_700_000_000,
            lane: 0,
            colorIdx: 1,
            maxLanes: 1,
            edges: [],
            refs: [],
            isRemoteOnly: false,
            isUnpushed: false
        )

        let coordinator = CommitTableView.Coordinator(
            rows: [initialRow],
            totalCommitCount: 50_000,
            isSearchActive: false,
            workingChangesCount: 0,
            onLoadMore: {},
            onFetchWindow: { _, _ in [] },
            onSelectCommits: { _ in },
            onCopyOid: { _ in },
            onCreateBranchAtCommit: { _ in },
            onCreateTagAtCommit: { _ in },
            onCreateWorktreeAtCommit: { _ in },
            canRemoveWorktree: { _ in false },
            onRemoveWorktree: { _ in },
            onCheckoutCommit: { _ in }
        )

        let table = NSTableView()
        // Row 0 is Working Changes + 50,000 virtualized commit rows.
        XCTAssertEqual(coordinator.numberOfRows(in: table), 50_001)
        XCTAssertEqual(coordinator.commit(atRow: 1)?.oidHex, "aaa0000")
        XCTAssertNil(coordinator.commit(atRow: 25_001))

        coordinator.insertIntoWindowCache(offset: 25_000, fetched: [deepRow])
        XCTAssertEqual(coordinator.commit(atRow: 25_001)?.oidHex, "bbb9999")

        coordinator.clearWindowCache()
        XCTAssertNil(coordinator.commit(atRow: 25_001))
    }

    func testScrolledToRowIsFilledFromTheIndexWithoutAPlaceholder() {
        let coordinator = makeVirtualizedCoordinator()
        coordinator.onCachedWindow = { offset, limit in
            (offset..<(offset + limit)).map { Self.row($0) }
        }

        let cell = coordinator.tableView(NSTableView(), viewFor: nil, row: 25_601) as? CommitRowCellView

        XCTAssertEqual(cell?.isPlaceholder, false)
        // The row above is loaded too, so the incoming lane line can be drawn.
        XCTAssertEqual(coordinator.commit(atRow: 25_600)?.oidHex, "oid25599")
        XCTAssertEqual(coordinator.commit(atRow: 25_601)?.oidHex, "oid25600")
    }

    /// Scrolling on past a window must not throw away the fetch already running, or nothing
    /// ever lands until the scroll stops.
    func testFurtherScrollingKeepsTheRunningWindowFetch() async {
        var requests: [CheckedContinuation<[CommitRow], Never>] = []
        var offsets: [Int] = []
        let started = expectation(description: "fetch started")
        started.assertForOverFulfill = false
        let coordinator = makeVirtualizedCoordinator { offset, _ in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    offsets.append(offset)
                    requests.append(continuation)
                    started.fulfill()
                }
            }
        }
        let table = NSTableView()

        _ = coordinator.tableView(table, viewFor: nil, row: 1_001)
        _ = coordinator.tableView(table, viewFor: nil, row: 30_001)
        await fulfillment(of: [started], timeout: 2)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(requests.count, 1)
        guard let first = requests.first, let offset = offsets.first else { return }
        first.resume(returning: (offset..<(offset + 300)).map { Self.row($0) })
        requests.dropFirst().forEach { $0.resume(returning: []) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coordinator.commit(atRow: 1_001)?.oidHex, "oid1000")
    }

    private static func row(_ index: Int) -> CommitRow {
        CommitRow(
            oidHex: "oid\(index)",
            shortOid: "oid\(index)",
            summary: "Commit \(index)",
            authorName: "Alice",
            authorEmail: "alice@example.com",
            timestamp: 1_700_000_000,
            lane: 0,
            colorIdx: 0,
            maxLanes: 1,
            edges: [],
            refs: [],
            isRemoteOnly: false,
            isUnpushed: false
        )
    }

    private func makeVirtualizedCoordinator(
        onFetchWindow: @escaping (Int, Int) async throws -> [CommitRow] = { _, _ in [] }
    ) -> CommitTableView.Coordinator {
        CommitTableView.Coordinator(
            rows: [Self.row(0)],
            totalCommitCount: 50_000,
            isSearchActive: false,
            workingChangesCount: 0,
            onLoadMore: {},
            onFetchWindow: onFetchWindow,
            onSelectCommits: { _ in },
            onCopyOid: { _ in },
            onCreateBranchAtCommit: { _ in },
            onCreateTagAtCommit: { _ in },
            onCreateWorktreeAtCommit: { _ in },
            canRemoveWorktree: { _ in false },
            onRemoveWorktree: { _ in },
            onCheckoutCommit: { _ in }
        )
    }
}
