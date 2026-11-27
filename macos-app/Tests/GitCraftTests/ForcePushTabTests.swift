import XCTest
@testable import GitCraft

/// How Push behaves once commits that are already on the remote have been rewritten.
final class ForcePushTabTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var remote: URL!

    override func setUpWithError() throws {
        root = temporaryFolderURL("gitcraft-force-push-test")
        repo = try makeTestRepository(at: root.appendingPathComponent("repo", isDirectory: true))
        remote = root.appendingPathComponent("origin.git", isDirectory: true)
        try git(["init", "-q", "--bare", "-b", "main", remote.path], in: root)
        try git(["remote", "add", "origin", remote.path], in: repo)
        try git(["push", "-q", "-u", "origin", "main"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func rev(_ name: String, in directory: URL) throws -> String {
        try git(["rev-parse", name], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func amend() throws {
        try git(["commit", "-q", "--amend", "-m", "rewritten"], in: repo)
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
    private func plan(_ tab: RepoTab) -> ForcePushPlan? {
        guard case let .forcePush(plan) = tab.activeSheet else { return nil }
        return plan
    }

    @MainActor
    func testPushAfterARewriteAsksFirst() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let published = try rev("main", in: remote)
        try amend()

        tab.runRemote(.push)
        try await waitFor("the force push sheet") { self.plan(tab) != nil && !tab.isBusy }

        XCTAssertEqual(plan(tab)?.destination, "origin/main")
        XCTAssertEqual(try rev("main", in: remote), published, "nothing is pushed yet")
        XCTAssertTrue(tab.toasts.isEmpty)
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testConfirmingUpdatesTheRemoteAndCannotBeUndone() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        try amend()
        tab.runRemote(.push)
        try await waitFor("the force push sheet") { self.plan(tab) != nil && !tab.isBusy }

        tab.forcePush(try XCTUnwrap(plan(tab)))
        try await waitFor("the push") { !tab.toasts.isEmpty && !tab.isBusy }

        XCTAssertEqual(try rev("main", in: remote), try rev("main", in: repo))
        XCTAssertEqual(tab.toasts.last?.message, "Force-pushed \"main\" to origin/main.")
        XCTAssertNil(tab.toasts.last?.action)
        XCTAssertTrue(tab.undoStack.isEmpty)
    }

    @MainActor
    func testOthersCommitsAreNeverOfferedForOverwriting() async throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try git(["clone", "-q", remote.path, other.path], in: root)
        try git(["config", "user.name", "Other"], in: other)
        try git(["config", "user.email", "other@gitcraft.local"], in: other)
        try git(["commit", "-q", "--allow-empty", "-m", "theirs"], in: other)
        try git(["push", "-q", "origin", "main"], in: other)
        try git(["fetch", "-q"], in: repo)
        let theirs = try rev("main", in: remote)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.runRemote(.push)
        try await waitFor("the refusal") { tab.errorMessage != nil && !tab.isBusy }

        XCTAssertEqual(tab.errorMessage, "origin/main has commits your branch doesn't. Pull first.")
        XCTAssertNil(tab.activeSheet)
        XCTAssertEqual(try rev("main", in: remote), theirs)
    }

    @MainActor
    func testAnOrdinaryPushGoesStraightThrough() async throws {
        try git(["commit", "-q", "--allow-empty", "-m", "ahead"], in: repo)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.runRemote(.push)
        try await waitFor("the push") { !tab.toasts.isEmpty && !tab.isBusy }

        XCTAssertNil(tab.activeSheet)
        XCTAssertEqual(try rev("main", in: remote), try rev("main", in: repo))
    }

    @MainActor
    func testCommitAndPushAfterAmendingAPushedCommitAsksFirst() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let published = try rev("main", in: remote)
        tab.commitSummary = "amended in the app"
        tab.amendCommit = true

        tab.commitChanges(pushAfter: true)
        try await waitFor("the force push sheet") { self.plan(tab) != nil && !tab.isBusy }

        XCTAssertFalse(tab.toasts.contains { $0.message.contains("--force-with-lease") })
        XCTAssertEqual(try rev("main", in: remote), published)
    }
}
