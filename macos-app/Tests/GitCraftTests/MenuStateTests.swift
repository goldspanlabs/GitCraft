import Foundation
import XCTest
@testable import GitCraft

/// The rules behind the menu bar's enabled states and actions.
final class MenuStateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-menu-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    func testHeadCommitOidIsNilWithoutCommits() throws {
        let tab = try RepoTab(url: makeEmptyRepo())
        defer { tab.stopWatcher() }
        XCTAssertNil(tab.headCommitOid)
    }

    @MainActor
    func testHeadCommitOidFollowsDetachedHead() throws {
        let repo = try makeRepo()
        try git(["commit", "--allow-empty", "-m", "second"], in: repo)
        try git(["switch", "--detach", "HEAD~1"], in: repo)

        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(tab.headCommitOid, head)
    }

    @MainActor
    func testStageAndStashEnablement() throws {
        let tab = try RepoTab(url: makeRepo())
        defer { tab.stopWatcher() }
        tab.stagedFiles = []
        tab.unstagedFiles = []
        tab.stashes = []
        tab.isBusy = false
        XCTAssertFalse(tab.canStageAll)
        XCTAssertFalse(tab.canUnstageAll)
        XCTAssertFalse(tab.canUseLatestStash)

        tab.unstagedFiles = [FileChange(path: "a", status: "M", staged: false)]
        tab.stagedFiles = [FileChange(path: "b", status: "M", staged: true)]
        tab.stashes = [StashInfo(index: 0, name: "stash@{0}", message: "m")]
        XCTAssertTrue(tab.canStageAll)
        XCTAssertTrue(tab.canUnstageAll)
        XCTAssertTrue(tab.canUseLatestStash)

        tab.isBusy = true
        XCTAssertFalse(tab.canStageAll)
        XCTAssertFalse(tab.canUnstageAll)
        XCTAssertFalse(tab.canUseLatestStash)
    }

    @MainActor
    func testPruneIsOfferedOnlyForAStaleWorktreeWhileIdle() throws {
        let repo = try makeRepo()
        let gone = root.appendingPathComponent("gone", isDirectory: true)
        try git(["worktree", "add", "-b", "gone", gone.path], in: repo)

        let healthy = try RepoTab(url: repo)
        defer { healthy.stopWatcher() }
        XCTAssertFalse(healthy.canPruneWorktrees)

        try FileManager.default.removeItem(at: gone)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        XCTAssertTrue(tab.canPruneWorktrees)
        tab.isBusy = true
        XCTAssertFalse(tab.canPruneWorktrees)
    }

    @MainActor
    func testCanCommitUsesTheComposerAndAutoStageSetting() throws {
        let tab = try RepoTab(url: makeRepo())
        defer { tab.stopWatcher() }
        tab.stagedFiles = []
        tab.unstagedFiles = [FileChange(path: "a", status: "M", staged: false)]
        tab.commitSummary = "message"
        XCTAssertTrue(tab.canCommit(autoStage: true))
        XCTAssertFalse(tab.canCommit(autoStage: false))
        tab.amendCommit = true
        XCTAssertTrue(tab.canCommit(autoStage: false))
    }

    /// A selected commit hides the commit fields, so nothing may commit what's left in them.
    @MainActor
    func testCommitAndAmendAreBlockedWhileACommitIsSelected() throws {
        let tab = try RepoTab(url: makeRepo())
        defer { tab.stopWatcher() }
        tab.stagedFiles = [FileChange(path: "a", status: "M", staged: true)]
        tab.commitSummary = "leftover"
        XCTAssertTrue(tab.canCommit(autoStage: true))
        XCTAssertTrue(tab.canAmend)

        tab.selectedCommit = CommitRow(
            oidHex: "abc", shortOid: "abc", summary: "s", authorName: "a", authorEmail: "a@b", timestamp: 0,
            lane: 0, colorIdx: 0, maxLanes: 1, edges: [], refs: [], isRemoteOnly: false, isUnpushed: false
        )
        XCTAssertFalse(tab.canCommit(autoStage: true))
        XCTAssertFalse(tab.canAmend)

        tab.selectedCommit = nil
        XCTAssertTrue(tab.canCommit(autoStage: true))
        XCTAssertTrue(tab.canAmend)
    }

    private func makeEmptyRepo() throws -> URL {
        let url = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: url)
        try git(["config", "user.name", "GitCraft Tests"], in: url)
        try git(["config", "user.email", "tests@gitcraft.local"], in: url)
        return url
    }

    private func makeRepo() throws -> URL {
        let url = try makeEmptyRepo()
        try "hello\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "README.md"], in: url)
        try git(["commit", "-m", "initial"], in: url)
        return url
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed: \(output)")
        return output
    }
}
