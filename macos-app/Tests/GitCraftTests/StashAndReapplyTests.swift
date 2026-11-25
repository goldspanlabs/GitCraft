import Foundation
import XCTest
@testable import GitCraft

final class StashAndReapplyTests: XCTestCase {
    func testStashAndReapplyLeavesAnOlderStashAloneWhenThereWasNothingToStash() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // An older stash the person kept.
        try "precious\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["stash", "push", "-m", "keep me"], in: repo)

        // The tab believes there are changes, but the tree is clean.
        let session = try RepoSession(path: repo.path)
        var ran = false
        try RepoTab.withLocalChanges(
            .stashAndReapply,
            hasChanges: true,
            stashMessage: "Auto-stash",
            session: session
        ) {
            ran = true
        }

        XCTAssertTrue(ran)
        XCTAssertEqual(try session.listStashes().count, 1)
        let readme = try String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(readme, "hello\n")
    }

    func testStashAndReapplyRestoresChangesAfterTheOperation() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "work in progress\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let session = try RepoSession(path: repo.path)
        var seenDuringOperation = ""
        try RepoTab.withLocalChanges(
            .stashAndReapply,
            hasChanges: true,
            stashMessage: "Auto-stash",
            session: session
        ) {
            seenDuringOperation = (try? String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        }

        XCTAssertEqual(seenDuringOperation, "hello\n")
        XCTAssertEqual(try session.listStashes().count, 0)
        let readme = try String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(readme, "work in progress\n")
    }

    private func makeRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-stash-test-\(UUID().uuidString)", isDirectory: true)
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
