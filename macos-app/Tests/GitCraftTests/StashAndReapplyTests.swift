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
        try makeTestRepository(at: temporaryFolderURL("gitcraft-stash-test"))
    }
}
