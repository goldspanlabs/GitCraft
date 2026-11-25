import XCTest
@testable import GitCraft

final class BranchTreeTests: XCTestCase {
    private func branch(_ name: String, remote: Bool = false, isDefault: Bool = false) -> BranchInfo {
        let prefix = remote ? "refs/remotes/" : "refs/heads/"
        return BranchInfo(
            name: name,
            fullRef: prefix + name,
            isRemote: remote,
            isHead: false,
            targetOidHex: String(repeating: "a", count: 40),
            ahead: 0,
            behind: 0,
            isMerged: false,
            isDefault: isDefault
        )
    }

    private func flatten(
        _ branches: [BranchInfo],
        scope: String = "local",
        collapsed: Set<String> = []
    ) -> [FlatBranchRow] {
        BranchTreeNode.buildFlattenedRows(
            from: branches,
            scope: scope,
            collapsedFolderIDs: collapsed
        )
    }

    /// Compact description of each row: depth plus either "folder:<name>" or "branch:<leaf>".
    private func describe(_ rows: [FlatBranchRow]) -> [String] {
        rows.map { row in
            let label: String
            switch row.kind {
            case let .folder(name, _, _): label = "folder:\(name)"
            case let .branch(_, leaf): label = "branch:\(leaf)"
            }
            return "\(row.depth) \(label)"
        }
    }

    func testFlatBranchesAreSortedAlphabetically() {
        let rows = flatten([branch("main"), branch("dev")])
        XCTAssertEqual(describe(rows), ["0 branch:dev", "0 branch:main"])
    }

    func testDefaultBranchFirstThenFoldersThenDirectBranches() {
        let rows = flatten([
            branch("alpha"),
            branch("feature/a"),
            branch("feature/b"),
            branch("main", isDefault: true),
            branch("zeta"),
        ])
        XCTAssertEqual(
            describe(rows),
            [
                "0 branch:main",
                "0 folder:feature",
                "1 branch:a",
                "1 branch:b",
                "0 branch:alpha",
                "0 branch:zeta",
            ]
        )
    }

    func testRemoteBranchesSortDefaultFirstThenFoldersThenDirectBranches() {
        let rows = flatten(
            [
                branch("origin/alpha", remote: true),
                branch("origin/feature/x", remote: true),
                branch("origin/main", remote: true, isDefault: true),
                branch("origin/beta", remote: true),
            ],
            scope: "remote"
        )
        XCTAssertEqual(
            describe(rows),
            [
                "0 folder:origin",
                "1 branch:main",
                "1 folder:feature",
                "2 branch:x",
                "1 branch:alpha",
                "1 branch:beta",
            ]
        )
    }

    func testSlashSeparatedNamesNestToTheirDepth() {
        let rows = flatten([branch("a/b/c")])
        XCTAssertEqual(describe(rows), ["0 folder:a", "1 folder:b", "2 branch:c"])
    }

    func testBranchesSharingAFolderMergeIntoOneFolder() {
        let rows = flatten([branch("team/one"), branch("team/two")])
        let folders = rows.filter {
            if case .folder = $0.kind { return true }
            return false
        }
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(rows.count, 3)
    }

    func testCollapsedFolderHidesItsChildren() {
        let rows = flatten(
            [branch("feature/a"), branch("feature/b"), branch("main", isDefault: true)],
            collapsed: ["folder:local:feature"]
        )
        XCTAssertEqual(describe(rows), ["0 branch:main", "0 folder:feature"])

        guard case let .folder(_, _, isExpanded) = rows[1].kind else {
            return XCTFail("expected a folder row")
        }
        XCTAssertFalse(isExpanded)
    }

    func testEmptyNameComponentsAreIgnored() {
        let rows = flatten([branch("//"), branch("feature//x")])
        XCTAssertEqual(describe(rows), ["0 folder:feature", "1 branch:x"])
    }

    func testEveryRowHasAUniqueID() {
        let rows = flatten([
            branch("feature/a"),
            branch("feature/nested/b"),
            branch("main"),
        ])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testLeafIDsUseFullRefSoLocalAndRemoteDoNotCollide() {
        let local = flatten([branch("main")], scope: "local")
        let remote = flatten([branch("main", remote: true)], scope: "remote")
        XCTAssertNotEqual(local.first?.id, remote.first?.id)
    }
}
