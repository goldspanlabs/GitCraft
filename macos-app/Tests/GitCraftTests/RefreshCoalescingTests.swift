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
        XCTAssertEqual(tab.commits.map(\.summary), ["initial"])
    }

    private func makeRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-refresh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: url)
        try git(["config", "user.name", "GitCraft Tests"], in: url)
        try git(["config", "user.email", "tests@gitcraft.local"], in: url)
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
