import Foundation
import XCTest
@testable import GitCraft

/// Moving through the Working Changes file lists with the keyboard.
final class WorkingSelectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-selection-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q", "-b", "main"]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    func testArrowsRunFromTheStagedListIntoTheUnstagedOneAndStopAtTheEnds() throws {
        let tab = try makeTab(staged: ["a"], unstaged: ["b", "c"])
        defer { tab.stopWatcher() }
        tab.selectWorkingFile(tab.stagedFiles[0])

        tab.moveWorkingFileSelection(by: -1)
        assertSelected(tab, "a", staged: true)
        tab.moveWorkingFileSelection(by: 1)
        assertSelected(tab, "b", staged: false)
        tab.moveWorkingFileSelection(by: 1)
        tab.moveWorkingFileSelection(by: 1)
        assertSelected(tab, "c", staged: false)
        tab.moveWorkingFileSelection(by: -1)
        tab.moveWorkingFileSelection(by: -1)
        assertSelected(tab, "a", staged: true)
    }

    @MainActor
    func testAPartlyStagedFileIsTwoSeparateRows() throws {
        let tab = try makeTab(staged: ["a"], unstaged: ["a"])
        defer { tab.stopWatcher() }
        tab.selectWorkingFile(tab.stagedFiles[0])
        tab.moveWorkingFileSelection(by: 1)
        assertSelected(tab, "a", staged: false)
    }

    @MainActor
    func testWithNothingSelectedDownPicksTheFirstRowAndUpTheLast() throws {
        let tab = try makeTab(staged: ["a"], unstaged: ["b"])
        defer { tab.stopWatcher() }
        tab.selectedFilePath = nil
        tab.moveWorkingFileSelection(by: 1)
        assertSelected(tab, "a", staged: true)
        tab.selectedFilePath = nil
        tab.moveWorkingFileSelection(by: -1)
        assertSelected(tab, "b", staged: false)
    }

    @MainActor
    func testSelectionFollowsAFileThatIsStagedOrUnstaged() throws {
        let tab = try makeTab(staged: [], unstaged: ["a", "b"])
        defer { tab.stopWatcher() }
        tab.selectWorkingFile(tab.unstagedFiles[1])

        tab.unstagedFiles = [change("a", staged: false)]
        tab.stagedFiles = [change("b", staged: true)]
        tab.loadWorkingDiffSelection()
        assertSelected(tab, "b", staged: true)

        tab.stagedFiles = []
        tab.unstagedFiles = [change("a", staged: false), change("b", staged: false)]
        tab.loadWorkingDiffSelection()
        assertSelected(tab, "b", staged: false)
    }

    @MainActor
    func testArrowsFollowTheTreeOrderOfEachList() throws {
        // As trees, folders come first: src/b before a.
        let tab = try makeTab(staged: ["a", "src/b"], unstaged: ["c", "src/d"])
        defer { tab.stopWatcher() }
        tab.selectedFilePath = nil

        for (path, staged) in [("src/b", true), ("a", true), ("src/d", false), ("c", false)] {
            tab.moveWorkingFileSelection(by: 1)
            assertSelected(tab, path, staged: staged)
        }
    }

    @MainActor
    func testArrowsSkipFilesInAFolderCollapsedInThatList() throws {
        let tab = try makeTab(staged: ["a", "src/b"], unstaged: ["c", "src/d"])
        defer { tab.stopWatcher() }
        tab.selectWorkingFile(tab.stagedFiles[0])

        // Collapsing src in the staged list leaves the unstaged src open.
        tab.moveWorkingFileSelection(by: -1, collapsedStagedFolders: ["src"])
        assertSelected(tab, "a", staged: true)
        tab.moveWorkingFileSelection(by: 1, collapsedStagedFolders: ["src"])
        assertSelected(tab, "src/d", staged: false)

        tab.selectWorkingFile(tab.unstagedFiles[0])
        tab.moveWorkingFileSelection(by: -1, collapsedUnstagedFolders: ["src"])
        assertSelected(tab, "a", staged: true)
    }

    @MainActor
    func testTheDefaultSelectionIsTheTopUnstagedRow() throws {
        let tab = try makeTab(staged: [], unstaged: ["a", "src/b"])
        defer { tab.stopWatcher() }
        tab.selectedFilePath = nil
        tab.loadWorkingDiffSelection()
        assertSelected(tab, "src/b", staged: false)
    }

    @MainActor
    private func makeTab(staged: [String], unstaged: [String]) throws -> RepoTab {
        let tab = try RepoTab(url: root)
        tab.stagedFiles = staged.map { change($0, staged: true) }
        tab.unstagedFiles = unstaged.map { change($0, staged: false) }
        return tab
    }

    private func change(_ path: String, staged: Bool) -> FileChange {
        FileChange(path: path, status: "M", staged: staged)
    }

    @MainActor
    private func assertSelected(
        _ tab: RepoTab, _ path: String, staged: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(tab.selectedFilePath, path, file: file, line: line)
        XCTAssertEqual(tab.selectedFileStaged, staged, file: file, line: line)
    }
}
