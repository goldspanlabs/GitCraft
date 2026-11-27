import XCTest
@testable import GitCraft

/// The undo stack against a real repository: what gets recorded, what Undo puts back, and when
/// steps are dropped.
final class UndoStackTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        root = temporaryFolderURL("gitcraft-undo-test")
        repo = try makeTestRepository(at: root.appendingPathComponent("repo", isDirectory: true))
        try git(["checkout", "-q", "-b", "other"], in: repo)
        try "picked\n".write(to: repo.appendingPathComponent("picked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "picked.txt"], in: repo)
        try git(["commit", "-q", "-m", "pick me"], in: repo)
        try git(["checkout", "-q", "main"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func rev(_ name: String) throws -> String {
        try git(["rev-parse", name], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    @MainActor
    private func cherryPickOther(_ tab: RepoTab) async throws {
        tab.cherryPick(try rev("other"))
        try await waitFor("the cherry-pick to be recorded") { tab.latestUndo != nil && !tab.isBusy }
    }

    @MainActor
    func testCherryPickRecordsAStepAndShowsAnUndoButton() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        try await cherryPickOther(tab)

        XCTAssertEqual(tab.undoStack.map(\.actionName), ["Cherry Pick"])
        let toast = try XCTUnwrap(tab.toasts.last)
        XCTAssertEqual(toast.action?.title, "Undo")
        XCTAssertEqual(toast.action?.undoEntryID, tab.latestUndo?.id)
        XCTAssertTrue(tab.toastActionEnabled(toast))
    }

    @MainActor
    func testUndoPutsTheBranchBackAndClearsTheStep() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let before = try rev("main")

        try await cherryPickOther(tab)
        XCTAssertNotEqual(try rev("main"), before)

        tab.undo()
        try await waitFor("the undo") { try self.rev("main") == before && !tab.isBusy }

        XCTAssertTrue(tab.undoStack.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("picked.txt").path))
        XCTAssertFalse(tab.toasts.contains { $0.action != nil }, "the Undo note goes with its step")
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testStepsUndoNewestFirst() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let start = try rev("main")

        try await cherryPickOther(tab)
        let afterPick = try rev("main")
        let first = try XCTUnwrap(tab.latestUndo)
        tab.revertCommit(afterPick)
        try await waitFor("the revert") { tab.undoStack.count == 2 && !tab.isBusy }

        // The older step's button waits for the newer one.
        let olderToast = try XCTUnwrap(tab.toasts.first { $0.action?.undoEntryID == first.id })
        XCTAssertFalse(tab.toastActionEnabled(olderToast))
        tab.undo(first.id)
        XCTAssertEqual(tab.undoStack.count, 2, "undoing an older step directly does nothing")

        tab.undo()
        try await waitFor("the revert to be undone") { try self.rev("main") == afterPick && !tab.isBusy }
        XCTAssertEqual(tab.latestUndo?.id, first.id)
        XCTAssertTrue(tab.toastActionEnabled(olderToast))

        tab.undo()
        try await waitFor("the cherry-pick to be undone") { try self.rev("main") == start && !tab.isBusy }
        XCTAssertTrue(tab.undoStack.isEmpty)
    }

    @MainActor
    func testAChangeMadeElsewhereClearsTheStack() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        try await cherryPickOther(tab)
        try "more\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "made in a terminal"], in: repo)
        tab.refresh()

        try await waitFor("the stale step to be dropped") { tab.undoStack.isEmpty }
        XCTAssertFalse(tab.toasts.contains { $0.action != nil })
    }

    @MainActor
    func testResettingToTheCurrentCommitRecordsNothing() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.resetTo(try rev("main"), mode: .soft)
        try await waitFor("the reset's note") { !tab.toasts.isEmpty && !tab.isBusy }

        XCTAssertTrue(tab.undoStack.isEmpty)
        XCTAssertNil(tab.toasts.last?.action, "nothing moved, so no Undo button")
    }

    @MainActor
    func testTheStackForgetsTheOldestPastItsLimit() throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let position = HeadPosition(oid: try rev("main"), branch: "refs/heads/main")
        let step = UndoStep.moveHead(HeadMove(before: position, after: position), mode: .keep)

        for index in 1 ... RepoTab.maxUndoSteps + 2 {
            tab.recordUndo(actionName: "Step \(index)", step: step, message: "Note \(index)")
        }

        XCTAssertEqual(tab.undoStack.count, RepoTab.maxUndoSteps)
        XCTAssertEqual(tab.undoStack.first?.actionName, "Step 3")
        XCTAssertEqual(tab.latestUndo?.actionName, "Step \(RepoTab.maxUndoSteps + 2)")
    }
}
