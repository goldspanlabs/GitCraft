import Combine
import Foundation
import XCTest
@testable import GitCraft

final class FirstLoadTests: XCTestCase {
    @MainActor
    func testTheGraphIsShownWithoutWaitingForTheRestOfTheReload() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        var branchesWhenHistoryArrived: Int?
        let observer = tab.$commits.sink { commits in
            if !commits.isEmpty, branchesWhenHistoryArrived == nil {
                branchesWhenHistoryArrived = tab.branches.count
            }
        }
        defer { observer.cancel() }

        tab.refresh()
        try await waitForRefresh(of: tab)

        XCTAssertEqual(branchesWhenHistoryArrived, 0, "history is published before the sidebar lists")
        XCTAssertEqual(tab.branches.map(\.name), ["main"], "the rest of the reload still applies")
    }

    @MainActor
    func testChangedFilesDoNotDependOnTheSidebarLists() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        // A stash ref naming a missing object: listing stashes fails, status still works.
        try (String(repeating: "1", count: 40) + "\n")
            .write(to: repo.appendingPathComponent(".git/refs/stash"), atomically: true, encoding: .utf8)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.refresh()
        try await waitForRefresh(of: tab)

        XCTAssertNotNil(tab.errorMessage, "the stash list really did fail")
        XCTAssertEqual(tab.unstagedFiles.map(\.path), ["new.txt"])
    }

    @MainActor
    func testRereadingAnUnchangedStatusPublishesNothing() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        tab.refresh()
        try await waitForRefresh(of: tab)
        // The selected file's diff and the worktree counts load on their own tasks.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(tab.diffRows.isEmpty)

        var publishes = 0
        let observer = tab.objectWillChange.sink { publishes += 1 }
        defer { observer.cancel() }
        tab.refreshStatus()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(publishes, 0)
    }

    @MainActor
    func testHistoryCountsAsLoadingUntilTheFirstRowsArrive() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        XCTAssertEqual(tab.historyState, .loading)

        tab.refresh()
        try await waitForRefresh(of: tab)

        XCTAssertEqual(tab.historyState, .loaded)
    }

    @MainActor
    func testARepositoryWithNoCommitsIsLoadedRatherThanStillLoading() async throws {
        let repo = try makeRepo(commit: false)
        defer { try? FileManager.default.removeItem(at: repo) }
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.refresh()
        try await waitForRefresh(of: tab)

        XCTAssertEqual(tab.historyState, .loaded)
        XCTAssertTrue(tab.commits.isEmpty)
    }

    @MainActor
    func testAHistoryThatCannotBeReadIsNotReportedAsEmpty() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(
            at: repo.appendingPathComponent(".git/objects/\(head.prefix(2))/\(head.dropFirst(2))")
        )
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.refresh()
        try await waitForRefresh(of: tab)

        XCTAssertEqual(tab.historyState, .failed)
        XCTAssertNotNil(tab.errorMessage)
    }

    @MainActor
    private func waitForRefresh(of tab: RepoTab) async throws {
        for _ in 0 ..< 200 where tab.refreshInFlight || tab.refreshPending {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(tab.refreshInFlight)
    }

    private func makeRepo(commit: Bool = true) throws -> URL {
        try makeTestRepository(at: temporaryFolderURL("gitcraft-first-load-test"), commit: commit)
    }
}
