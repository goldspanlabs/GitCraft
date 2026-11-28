import Foundation
import XCTest
@testable import GitCraft

final class CompareTests: XCTestCase {
    func testBranchMenuRequiresAttachedHeadAndCommonBaseForAnotherBranch() {
        XCTAssertTrue(RepoTab.canCompareBranch(isCheckedOut: false, isDetached: false, hasMergeBase: true))
        XCTAssertFalse(RepoTab.canCompareBranch(isCheckedOut: true, isDetached: false, hasMergeBase: true))
        XCTAssertFalse(RepoTab.canCompareBranch(isCheckedOut: false, isDetached: true, hasMergeBase: true))
        XCTAssertFalse(RepoTab.canCompareBranch(isCheckedOut: false, isDetached: false, hasMergeBase: false))
    }

    @MainActor
    func testCleanWorkingTreeMenuPutsDefaultFirstAndKeepsCurrentBranchEnabled() throws {
        let repo = try makeTestRepository(at: temporaryFolderURL("compare"))
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["branch", "alphabetically-first"], in: repo)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        tab.branches = try tab.session.listBranches()
        tab.compareDefaultBranch = tab.session.compareDefaultBranch()

        let menu = try XCTUnwrap(tab.workingTreeCompareMenu.first)
        guard case let .submenu(title, items) = menu else { return XCTFail("Expected a branch submenu") }
        XCTAssertEqual(title, "Compare Common Base with Working Tree")
        XCTAssertEqual(items.count, 2)
        guard case let .item(name, enabled, _, action) = try XCTUnwrap(items.first) else {
            return XCTFail("Expected a branch item")
        }
        XCTAssertEqual(name, "main")
        XCTAssertTrue(enabled)
        XCTAssertEqual(tab.totalChangesCount, 0)
        action()
        XCTAssertEqual(tab.compareState, .loading)
        XCTAssertEqual(tab.compareRequest, .workingTree("refs/heads/main"))
        tab.closeCompare()
    }

    @MainActor
    func testCompareLoadsAndClosingPreservesThePreviousFileSelection() async throws {
        let repo = try makeTestRepository(at: temporaryFolderURL("compare"))
        defer { try? FileManager.default.removeItem(at: repo) }
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        tab.selectedFilePath = "README.md"

        XCTAssertEqual(tab.compareState, .idle)
        tab.startCompare(.workingTree("refs/heads/main"))
        XCTAssertEqual(tab.compareState, .loading)
        try await waitUntil { tab.compareState.isLoaded }
        guard case let .loaded(summary) = tab.compareState else { return XCTFail("Expected comparison") }
        XCTAssertTrue(summary.files.isEmpty)
        tab.closeCompare()
        XCTAssertEqual(tab.compareState, .idle)
        XCTAssertEqual(tab.selectedFilePath, "README.md")
    }

    @MainActor
    func testCompareErrorsAndIgnoresSupersededAndClosedRequests() async throws {
        let repo = try makeTestRepository(at: temporaryFolderURL("compare"))
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["switch", "--orphan", "other"], in: repo)
        try git(["commit", "--allow-empty", "-m", "unrelated"], in: repo)
        try git(["switch", "main"], in: repo)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.startCompare(.workingTree("refs/heads/other"))
        try await waitUntil { tab.compareState == .error("No merge base (unrelated histories).") }
        XCTAssertEqual(tab.compareState, .error("No merge base (unrelated histories)."))

        tab.startCompare(.workingTree("refs/heads/other"))
        tab.startCompare(.workingTree("refs/heads/main"))
        try await waitUntil { tab.compareState.isLoaded }
        tab.startCompare(.workingTree("refs/heads/other"))
        tab.closeCompare()
        // Give the discarded background queries a chance to publish.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(tab.compareState, .idle)
    }

    @MainActor
    func testRefreshClosesComparisonWhenTargetDisappears() async throws {
        let repo = try makeTestRepository(at: temporaryFolderURL("compare"))
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["branch", "topic"], in: repo)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.startCompare(.branch("refs/heads/topic"))
        try await waitUntil { tab.compareState.isLoaded }
        try git(["branch", "-D", "topic"], in: repo)
        tab.refreshCompare()

        try await waitUntil { tab.compareState == .idle }
        XCTAssertEqual(tab.errorMessage, "Comparison closed because refs/heads/topic is no longer available.")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for compare state")
    }
}
