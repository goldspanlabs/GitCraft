import AppKit
import XCTest
@testable import GitCraft

/// Real-repository checks of the drag entry points, sheets, validation and undo routing.
final class GitDropTabTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = try makeTestRepository(at: temporaryFolderURL("gitcraft-drop-test"))
        for name in ["one", "two", "three"] {
            try "\(name)\n".write(to: repo.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            try git(["add", "-A"], in: repo)
            try git(["commit", "-m", name], in: repo)
        }
        try git(["branch", "feature", "HEAD~1"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for the drop flow")
    }

    @MainActor
    private func loadedTab() async throws -> RepoTab {
        let tab = try RepoTab(url: repo)
        tab.refresh()
        try await waitFor { tab.dragHeadOID != nil && tab.commits.count >= 4 }
        return tab
    }

    @MainActor
    private func oid(_ tab: RepoTab, _ summary: String) throws -> String {
        try XCTUnwrap(tab.commits.first { $0.summary == summary }?.oidHex)
    }

    @MainActor
    func testHistoryDragWritesOnePayloadAndIncludesVirtualizedRows() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let rows = tab.commits
        let coordinator = CommitTableView.Coordinator(
            rows: Array(rows.prefix(1)), totalCommitCount: rows.count, isSearchActive: false,
            workingChangesCount: 0, onLoadMore: {}, onFetchWindow: { _, _ in [] },
            onSelectCommits: { _ in }, onCopyOid: { _ in }, onCreateBranchAtCommit: { _ in },
            onCreateTagAtCommit: { _ in }, onCreateWorktreeAtCommit: { _ in },
            canRemoveWorktree: { _ in false }, onRemoveWorktree: { _ in }, onCheckoutCommit: { _ in })
        coordinator.onMakeGitDrag = { tab.makeGitDrag(oids: $0, label: "selected") }
        coordinator.windowCache[1] = rows[1]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let table = NSTableView()
        XCTAssertTrue(coordinator.tableView(table, writeRowsWith: IndexSet([1, 2]), to: board))
        let payload = try XCTUnwrap(GitDragPayload.read(from: board))
        XCTAssertEqual(payload.oids, Array(rows.prefix(2)).map(\.oidHex))
        XCTAssertEqual(board.pasteboardItems?.count, 1, "multi-selection travels as a single operation")
        XCTAssertFalse(coordinator.tableView(table, writeRowsWith: IndexSet([0, 1]), to: board))
        XCTAssertFalse(coordinator.tableView(table, writeRowsWith: IndexSet([3]), to: board), "uncached row must not become a partial drag")
        coordinator.isBusy = true
        XCTAssertFalse(coordinator.tableView(table, writeRowsWith: IndexSet([1]), to: board))
    }

    @MainActor
    func testCreationSheetsUsePinnedCommitAndDoNotMutate() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let target = try oid(tab, "one")
        let payload = try XCTUnwrap(tab.makeGitDrag(oids: [target], label: "one"))
        let before = try git(["show-ref"], in: repo)
        tab.receiveGitDrop(payload, target: .branches, option: false)
        guard case let .newBranch(startPoint) = tab.activeSheet else { return XCTFail("branch sheet") }
        XCTAssertEqual(startPoint, target)
        tab.activeSheet = nil
        tab.receiveGitDrop(payload, target: .tags, option: false)
        guard case let .newTag(tagTarget) = tab.activeSheet else { return XCTFail("tag sheet") }
        XCTAssertEqual(tagTarget, target)
        XCTAssertEqual(try git(["show-ref"], in: repo), before)
    }

    @MainActor
    func testBranchAndCommitDropsOnlyArmConfirmation() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let source = try oid(tab, "two")
        for (ref, option, action) in [("refs/heads/feature", false, GitDropAction.merge),
                                       ("refs/heads/feature", true, .rebase),
                                       (nil, false, .cherryPick)] as [(String?, Bool, GitDropAction)] {
            tab.activeSheet = nil
            let payload = try XCTUnwrap(tab.makeGitDrag(oids: [source], sourceRef: ref, label: "feature"))
            tab.receiveGitDrop(payload, target: .head, option: option)
            guard case let .gitDrop(plan) = tab.activeSheet else { return XCTFail("confirmation") }
            XCTAssertEqual(plan.action, action)
            XCTAssertEqual(tab.undoStack.count, 0)
            XCTAssertEqual(tab.dragHeadOID, payload.headOID)
        }
    }

    @MainActor
    func testConsecutiveSquashAndFixupRequireOldestTarget() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let one = try oid(tab, "one"), two = try oid(tab, "two"), three = try oid(tab, "three")
        for fixup in [false, true] {
            tab.activeSheet = nil
            let payload = try XCTUnwrap(tab.makeGitDrag(oids: [three, two], label: "2 commits"))
            tab.receiveGitDrop(payload, target: .commit(one), option: fixup)
            try await waitFor { tab.activeSheet != nil && !tab.isPreparingGitDrop }
            guard case let .dropSquash(preview, checkout, isFixup) = tab.activeSheet else { return XCTFail("squash sheet") }
            XCTAssertEqual(preview.commits.map(\.summary), ["one", "two", "three"])
            XCTAssertEqual(checkout, tab.activeCheckoutPath)
            XCTAssertEqual(isFixup, fixup)
        }
        tab.activeSheet = nil
        let payload = try XCTUnwrap(tab.makeGitDrag(oids: [one], label: "one"))
        tab.receiveGitDrop(payload, target: .commit(two), option: false)
        try await waitFor { !tab.isPreparingGitDrop }
        XCTAssertNil(tab.activeSheet)
        XCTAssertEqual(tab.toasts.last?.message, "Drop onto the oldest commit in the consecutive range")
    }

    @MainActor
    func testGapRefusalDoesNotSilentlySquashInterveningCommits() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let payload = try XCTUnwrap(tab.makeGitDrag(oids: [oid(tab, "three")], label: "three"))
        tab.receiveGitDrop(payload, target: .commit(try oid(tab, "one")), option: false)
        try await waitFor { !tab.isPreparingGitDrop }
        XCTAssertNil(tab.activeSheet)
        XCTAssertEqual(tab.toasts.last?.message, "Select consecutive commits")
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testStaleDropAndBusyDropNeverOpenSheets() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let source = try oid(tab, "two")
        let payload = try XCTUnwrap(tab.makeGitDrag(oids: [source], label: "two"))
        tab.isBusy = true
        tab.receiveGitDrop(payload, target: .branches, option: false)
        XCTAssertNil(tab.activeSheet)
        XCTAssertNil(tab.makeGitDrag(oids: [source], label: "two"))
        tab.isBusy = false
        tab.currentBranch = "other"
        tab.receiveGitDrop(payload, target: .tags, option: false)
        XCTAssertNil(tab.activeSheet)
    }

    @MainActor
    func testConfirmedIntegrationRecordsUndoAndRestoresHead() async throws {
        try git(["checkout", "feature"], in: repo)
        try "feature".write(to: repo.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "feature work"], in: repo)
        try git(["checkout", "main"], in: repo)
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let before = try git(["rev-parse", "HEAD"], in: repo)
        let branch = try XCTUnwrap(tab.branches.first { $0.name == "feature" })
        let payload = try XCTUnwrap(tab.makeGitDrag(oids: [branch.targetOidHex], sourceRef: branch.fullRef, label: "feature"))
        tab.receiveGitDrop(payload, target: .head, option: false)
        guard case let .gitDrop(plan) = tab.activeSheet else { return XCTFail("merge sheet") }
        tab.activeSheet = nil
        tab.executeGitDrop(plan, action: .merge)
        try await waitFor { !tab.isBusy && !tab.undoStack.isEmpty }
        XCTAssertEqual(tab.latestUndo?.actionName, "Merge")
        tab.undo()
        try await waitFor { !tab.isBusy && tab.undoStack.isEmpty }
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: repo), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path))
    }
    @MainActor
    func testUnchangedMergeAndRebaseDropsPreserveRedoHistory() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let headBefore = try XCTUnwrap(tab.session.headPosition())
        let target = try oid(tab, "two")
        // Record and undo an actual reset to establish a usable redo entry.
        tab.resetTo(target, mode: .soft)
        try await waitFor { !tab.isBusy && !tab.undoStack.isEmpty }
        tab.undo()
        try await waitFor { !tab.isBusy && !tab.redoStack.isEmpty }
        let redoID = try XCTUnwrap(tab.latestRedo?.id)
        let payload = GitDragPayload(checkout: tab.activeCheckoutPath, headOID: headBefore.oid,
                                     branch: "main", oids: [target], sourceRef: "refs/heads/feature", label: "feature")
        for (action, warning) in [(GitDropAction.merge, "nothing to merge"), (.rebase, "nothing to rebase")] {
            let plan = GitDropPlan(payload: payload, target: .head, action: action, message: "Integrate feature into main")
            tab.executeGitDrop(plan, action: action)
            try await waitFor { !tab.isBusy && tab.toasts.contains { $0.message.contains(warning) } }
            XCTAssertEqual(tab.latestRedo?.id, redoID)
            XCTAssertTrue(tab.undoStack.isEmpty)
            XCTAssertEqual(tab.session.headPosition(), headBefore)
        }
    }

    @MainActor
    func testFixupUsesRawTargetMessageInsteadOfEditorMetadata() async throws {
        let message = "  target\ncontinuation\n\n    indented  \n\n\n"
        let messageURL = repo.appendingPathComponent(".git/fixup-message")
        try message.write(to: messageURL, atomically: true, encoding: .utf8)
        let changedFile = repo.appendingPathComponent("fixup-change.txt")
        try "a real change\n".write(to: changedFile, atomically: true, encoding: .utf8)
        try git(["add", "fixup-change.txt"], in: repo)
        try git(["commit", "--cleanup=verbatim", "-F", messageURL.path], in: repo)
        let target = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["commit", "--allow-empty", "-m", "newer"], in: repo)
        let newer = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let before = try XCTUnwrap(tab.session.headPosition())
        let treeBefore = try git(["rev-parse", "HEAD^{tree}"], in: repo)
        let preview = try tab.session.squashPreview(oids: [newer, target])
        tab.squash(preview, summary: "", description: "edited display text must be ignored", fixup: true)
        try await waitFor { !tab.isBusy && !tab.undoStack.isEmpty }
        let result = try git(["cat-file", "commit", "HEAD"], in: repo)
        XCTAssertEqual(String(result[result.range(of: "\n\n")!.upperBound...]), message)
        XCTAssertEqual(tab.latestUndo?.actionName, "Fixup")
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"], in: repo), treeBefore)
        XCTAssertEqual(try String(contentsOf: changedFile, encoding: .utf8), "a real change\n")
        tab.undo()
        try await waitFor { !tab.isBusy && tab.undoStack.isEmpty }
        XCTAssertEqual(tab.session.headPosition(), before)
    }

}
