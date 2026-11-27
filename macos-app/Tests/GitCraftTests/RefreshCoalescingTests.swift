import Foundation
import XCTest
@testable import GitCraft

final class RefreshCoalescingTests: XCTestCase {
    @MainActor
    func testRefreshRequestsMadeWhileOneRunsQueueASinglePass() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        let runsBefore = tab.refreshRun
        tab.refresh()
        XCTAssertTrue(tab.refreshInFlight)
        XCTAssertFalse(tab.refreshPending)

        // A mutation's refresh and the watcher's refresh of the same change arrive together:
        // they don't start a second reload next to the running one, they queue one more.
        tab.refresh()
        tab.refresh()
        XCTAssertTrue(tab.refreshInFlight)
        XCTAssertTrue(tab.refreshPending)

        for _ in 0 ..< 200 where tab.refreshInFlight || tab.refreshPending {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(tab.refreshInFlight)
        XCTAssertFalse(tab.refreshPending)
        // The three requests ran as exactly two reloads: the first, and one queued pass.
        XCTAssertEqual(tab.refreshRun - runsBefore, 2)
        XCTAssertEqual(tab.commits.map(\.summary), ["initial"])
    }

    private func makeRepo() throws -> URL {
        try makeTestRepository(at: temporaryFolderURL("gitcraft-refresh-test"))
    }
}
