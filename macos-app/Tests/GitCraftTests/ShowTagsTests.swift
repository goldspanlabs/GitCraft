import Foundation
import XCTest
@testable import GitCraft

final class ShowTagsTests: XCTestCase {
    func testVisibleRefsFiltersTagsWhenHiddenAndKeepsUpToFourOtherRefs() {
        let refs: [RefBadge] = [
            RefBadge(name: "v1.0.0", kind: .tag, isCurrent: false),
            RefBadge(name: "main", kind: .localBranch, isCurrent: true),
            RefBadge(name: "v1.0.1", kind: .tag, isCurrent: false),
            RefBadge(name: "origin/main", kind: .remoteBranch, isCurrent: false),
            RefBadge(name: "feature/a", kind: .localBranch, isCurrent: false),
            RefBadge(name: "feature/b", kind: .localBranch, isCurrent: false),
            RefBadge(name: "feature/c", kind: .localBranch, isCurrent: false),
        ]

        let shown = CommitRowCellView.visibleRefs(from: refs, showTags: true)
        XCTAssertEqual(shown.map(\.name), ["v1.0.0", "main", "v1.0.1", "origin/main"])

        let hidden = CommitRowCellView.visibleRefs(from: refs, showTags: false)
        XCTAssertEqual(hidden.map(\.name), ["main", "origin/main", "feature/a", "feature/b"])
    }

    func testVisibleRefsReturnsEmptyWhenOnlyTagsExistAndHidden() {
        let refs = [RefBadge(name: "v2.0.0", kind: .tag, isCurrent: false)]
        XCTAssertTrue(CommitRowCellView.visibleRefs(from: refs, showTags: false).isEmpty)
    }

    @MainActor
    func testShowTagsIsScopedPerRepoTab() throws {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let repoA = root.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = root.appendingPathComponent("repo-b", isDirectory: true)
        for repo in [repoA, repoB] {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["init", "-q"]
            proc.currentDirectoryURL = repo
            try proc.run()
            proc.waitUntilExit()
            XCTAssertEqual(proc.terminationStatus, 0)
        }

        let tabA = try RepoTab(url: repoA)
        let tabB = try RepoTab(url: repoB)
        defer {
            tabA.stopWatcher()
            tabB.stopWatcher()
        }

        XCTAssertTrue(tabA.showTags)
        XCTAssertTrue(tabB.showTags)

        tabA.showTags = false
        XCTAssertFalse(tabA.showTags)
        XCTAssertTrue(tabB.showTags)
    }
}
