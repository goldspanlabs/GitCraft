import Combine
import Foundation
import XCTest
@testable import GitCraft

final class CommitTypingTests: XCTestCase {
    /// Everything watching the tab redraws when it publishes, so typing a message must only
    /// publish when it changes whether there is a summary to commit.
    @MainActor
    func testTypingRedrawsTheTabOnlyWhenTheSummaryBecomesOrStopsBeingBlank() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-typing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", repo.path]
        try git.run()
        git.waitUntilExit()
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        var publishes = 0
        let observer = tab.objectWillChange.sink { publishes += 1 }
        defer { observer.cancel() }

        tab.commitSummary = " "
        XCTAssertEqual(publishes, 0, "still blank")
        tab.commitSummary = "F"
        XCTAssertEqual(publishes, 1)
        tab.commitSummary = "Fix"
        tab.commitBody = "Details"
        XCTAssertEqual(publishes, 1, "more typing changes nothing else on screen")
        XCTAssertEqual(tab.commitSummary, "Fix")
        XCTAssertEqual(tab.commitBody, "Details")
        tab.commitSummary = ""
        XCTAssertEqual(publishes, 2)
    }
}
