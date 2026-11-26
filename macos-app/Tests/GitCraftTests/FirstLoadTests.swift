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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-first-load-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: url)
        try git(["config", "user.name", "GitCraft Tests"], in: url)
        try git(["config", "user.email", "tests@gitcraft.local"], in: url)
        try "hello\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        if commit {
            try git(["add", "README.md"], in: url)
            try git(["commit", "-m", "initial"], in: url)
        }
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
