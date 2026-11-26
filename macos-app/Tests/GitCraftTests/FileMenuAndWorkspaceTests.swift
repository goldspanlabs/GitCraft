import AppKit
import Foundation
import XCTest
@testable import GitCraft

final class FileMenuAndWorkspaceTests: XCTestCase {
    func testSuggestedFolderNameExtractsRepoName() {
        XCTAssertEqual(
            CloneRepositorySheet.suggestedFolderName(from: "https://github.com/user/GitCraft.git"),
            "GitCraft"
        )
        XCTAssertEqual(
            CloneRepositorySheet.suggestedFolderName(from: "https://github.com/user/GitCraft/"),
            "GitCraft"
        )
        XCTAssertEqual(
            CloneRepositorySheet.suggestedFolderName(from: "git@github.com:user/my-repo.git"),
            "my-repo"
        )
        XCTAssertEqual(
            CloneRepositorySheet.suggestedFolderName(from: "   "),
            ""
        )
    }

    func testSwiftBindingsInitAndCloneRepository() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try initRepository(path: source.path, initialBranch: "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path))

        try "hello\n".write(
            to: source.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try git(["config", "user.name", "Tester"], in: source)
        try git(["config", "user.email", "tester@example.com"], in: source)
        try git(["add", "README.md"], in: source)
        try git(["commit", "-m", "Initial commit"], in: source)

        let dest = root.appendingPathComponent("cloned", isDirectory: true)
        try cloneRepository(url: source.path, destination: dest.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("README.md").path))
    }

    @MainActor
    func testClearRecentRepositoriesEmptiesList() {
        let workspace = WorkspaceState()
        workspace.recentPaths = ["/tmp/repo-a", "/tmp/repo-b"]
        workspace.clearRecentRepositories()
        XCTAssertTrue(workspace.recentPaths.isEmpty)
    }

    @MainActor
    func testClosedTabHistoryRecordsSkipsMissingAndRestores() throws {
        _ = NSApplication.shared
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoA = try makeRepo(at: root.appendingPathComponent("repo-a", isDirectory: true))
        let repoB = try makeRepo(at: root.appendingPathComponent("repo-b", isDirectory: true))

        let workspace = WorkspaceState()
        XCTAssertTrue(workspace.closedTabPaths.isEmpty)

        XCTAssertTrue(workspace.openRepository(at: repoA))
        XCTAssertTrue(workspace.openRepository(at: repoB))

        // Close repoB via its window so windowClosed records it.
        NSApp.windows.first { ($0.windowController as? RepoWindowController)?.tab.repoPath == repoB.path }?.close()
        XCTAssertEqual(workspace.closedTabPaths, [repoB.path])

        // Close repoA as well; stack is LIFO.
        NSApp.windows.first { ($0.windowController as? RepoWindowController)?.tab.repoPath == repoA.path }?.close()
        XCTAssertEqual(workspace.closedTabPaths, [repoB.path, repoA.path])

        // Delete repoA on disk; restoreClosedTab should skip it and reopen repoB.
        try FileManager.default.removeItem(at: repoA)
        workspace.restoreClosedTab()
        XCTAssertTrue(workspace.closedTabPaths.isEmpty)
        XCTAssertTrue(
            NSApp.windows.contains { ($0.windowController as? RepoWindowController)?.tab.repoPath == repoB.path }
        )

        // Clean up open window.
        NSApp.windows.first { ($0.windowController as? RepoWindowController)?.tab.repoPath == repoB.path }?.close()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-filemenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: RepoTab.canonicalPath(for: dir.path), isDirectory: true)
    }

    private func makeRepo(at url: URL) throws -> URL {
        try initRepository(path: url.path, initialBranch: "main")
        try "hello\n".write(
            to: url.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try git(["config", "user.name", "Tester"], in: url)
        try git(["config", "user.email", "tester@example.com"], in: url)
        try git(["add", "README.md"], in: url)
        try git(["commit", "-m", "Initial commit"], in: url)
        return url
    }

    private func git(_ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(process.terminationStatus))
        }
    }
}
