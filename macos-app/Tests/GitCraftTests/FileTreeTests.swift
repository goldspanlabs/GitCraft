import XCTest
@testable import GitCraft

final class FileTreeTests: XCTestCase {
    private func files(_ paths: [String]) -> [FileChange] {
        paths.map { FileChange(path: $0, status: "M", staged: false) }
    }

    /// Compact description of each row: depth plus either "folder:<name>" or "file:<name>".
    private func describe(_ paths: [String], collapsed: Set<String> = []) -> [String] {
        FileTree.rows(from: files(paths), collapsedFolderPaths: collapsed).map { row in
            switch row.kind {
            case let .folder(name, _, _): return "\(row.depth) folder:\(name)"
            case let .file(_, name): return "\(row.depth) file:\(name)"
            }
        }
    }

    private func next(
        _ paths: [String],
        from selected: String?,
        by delta: Int,
        collapsed: Set<String> = []
    ) -> String? {
        FileTree.file(
            movingBy: delta,
            through: [FileTree.List(changes: files(paths), collapsedFolderPaths: collapsed)],
            from: { $0.path == selected }
        )?.path
    }

    func testFoldersNestAndSortAboveFiles() {
        XCTAssertEqual(
            describe(["rust-core/Cargo.lock", "rust-core/Cargo.toml", "rust-core/src/git_cli.rs", "README.md"]),
            [
                "0 folder:rust-core",
                "1 folder:src",
                "2 file:git_cli.rs",
                "1 file:Cargo.lock",
                "1 file:Cargo.toml",
                "0 file:README.md",
            ]
        )
    }

    func testAnUntrackedFolderKeepsItsSlashSoItDoesNotReadAsAFile() {
        XCTAssertEqual(describe(["src/new/"]), ["0 folder:src", "1 file:new/"])
    }

    func testSingleChildFolderChainsShareOneRow() {
        XCTAssertEqual(
            describe(["a/b/c/one.txt", "a/b/c/two.txt"]),
            ["0 folder:a/b/c", "1 file:one.txt", "1 file:two.txt"]
        )
    }

    func testChainStopsAtAFolderThatHoldsAFile() {
        XCTAssertEqual(
            describe(["a/b/c/deep.txt", "a/b/here.txt"]),
            ["0 folder:a/b", "1 folder:c", "2 file:deep.txt", "1 file:here.txt"]
        )
    }

    func testCollapsedFolderHidesItsContents() {
        XCTAssertEqual(
            describe(["src/ops/sync.rs", "src/lib.rs", "z.txt"], collapsed: ["src"]),
            ["0 folder:src", "0 file:z.txt"]
        )
    }

    func testFileRowsAreIdentifiedByPathSoTheListCanScrollToThem() {
        let rows = FileTree.rows(from: files(["src/lib.rs"]), collapsedFolderPaths: [])
        XCTAssertEqual(rows.last?.id, "src/lib.rs")
        XCTAssertNotEqual(rows.first?.id, "src")
    }

    func testArrowsFollowTheOnScreenOrder() {
        let paths = ["a.txt", "src/lib.rs"]
        XCTAssertEqual(next(paths, from: nil, by: 1), "src/lib.rs")
        XCTAssertEqual(next(paths, from: nil, by: -1), "a.txt")
        XCTAssertEqual(next(paths, from: "src/lib.rs", by: 1), "a.txt")
        XCTAssertEqual(next(paths, from: "a.txt", by: -1), "src/lib.rs")
    }

    func testArrowsStopAtTheEnds() {
        let paths = ["a.txt", "b.txt"]
        XCTAssertNil(next(paths, from: "a.txt", by: -1))
        XCTAssertNil(next(paths, from: "b.txt", by: 1))
    }

    func testArrowsSkipFilesInCollapsedFolders() {
        let paths = ["a/one.txt", "b/two.txt", "c/three.txt"]
        XCTAssertEqual(next(paths, from: "a/one.txt", by: 1, collapsed: ["b"]), "c/three.txt")
        XCTAssertEqual(next(paths, from: nil, by: 1, collapsed: ["a"]), "b/two.txt")
    }

    func testArrowsLeaveASelectionHiddenByCollapsingItsFolder() {
        let paths = ["a/one.txt", "b/two.txt", "c/three.txt"]
        XCTAssertEqual(next(paths, from: "b/two.txt", by: 1, collapsed: ["b"]), "c/three.txt")
        XCTAssertEqual(next(paths, from: "b/two.txt", by: -1, collapsed: ["b"]), "a/one.txt")
    }

    func testNothingToSelectWhenEveryFileIsHidden() {
        XCTAssertNil(next(["a/one.txt"], from: nil, by: 1, collapsed: ["a"]))
        XCTAssertNil(next([], from: nil, by: 1))
    }
}
