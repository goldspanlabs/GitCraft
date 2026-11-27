import XCTest
@testable import GitCraft

/// The undo stack against a real repository: what gets recorded, what Undo puts back, and when
/// steps are dropped.
final class UndoStackTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        root = temporaryFolderURL("gitcraft-undo-test")
        repo = try makeTestRepository(at: root.appendingPathComponent("repo", isDirectory: true))
        try git(["checkout", "-q", "-b", "other"], in: repo)
        try "picked\n".write(to: repo.appendingPathComponent("picked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "picked.txt"], in: repo)
        try git(["commit", "-q", "-m", "pick me"], in: repo)
        try git(["checkout", "-q", "main"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func rev(_ name: String) throws -> String {
        try git(["rev-parse", name], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    @MainActor
    private func cherryPickOther(_ tab: RepoTab) async throws {
        tab.cherryPick(try rev("other"))
        try await waitFor("the cherry-pick to be recorded") { tab.latestUndo != nil && !tab.isBusy }
    }

    @MainActor
    func testCherryPickRecordsAStepAndShowsAnUndoButton() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        try await cherryPickOther(tab)

        XCTAssertEqual(tab.undoStack.map(\.actionName), ["Cherry Pick"])
        let toast = try XCTUnwrap(tab.toasts.last)
        XCTAssertEqual(toast.action?.title, "Undo")
        XCTAssertEqual(toast.action?.undoEntryID, tab.latestUndo?.id)
        XCTAssertTrue(tab.toastActionEnabled(toast))
    }

    @MainActor
    func testUndoPutsTheBranchBackAndClearsTheStep() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let before = try rev("main")

        try await cherryPickOther(tab)
        XCTAssertNotEqual(try rev("main"), before)

        tab.undo()
        try await waitFor("the undo") { try self.rev("main") == before && !tab.isBusy }

        XCTAssertTrue(tab.undoStack.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("picked.txt").path))
        XCTAssertFalse(tab.toasts.contains { $0.action != nil }, "the Undo note goes with its step")
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testStepsUndoNewestFirst() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let start = try rev("main")

        try await cherryPickOther(tab)
        let afterPick = try rev("main")
        let first = try XCTUnwrap(tab.latestUndo)
        tab.revertCommit(afterPick)
        try await waitFor("the revert") { tab.undoStack.count == 2 && !tab.isBusy }

        // The older step's button waits for the newer one.
        let olderToast = try XCTUnwrap(tab.toasts.first { $0.action?.undoEntryID == first.id })
        XCTAssertFalse(tab.toastActionEnabled(olderToast))
        tab.undo(first.id)
        XCTAssertEqual(tab.undoStack.count, 2, "undoing an older step directly does nothing")

        tab.undo()
        try await waitFor("the revert to be undone") { try self.rev("main") == afterPick && !tab.isBusy }
        XCTAssertEqual(tab.latestUndo?.id, first.id)
        XCTAssertTrue(tab.toastActionEnabled(olderToast))

        tab.undo()
        try await waitFor("the cherry-pick to be undone") { try self.rev("main") == start && !tab.isBusy }
        XCTAssertTrue(tab.undoStack.isEmpty)
    }

    @MainActor
    func testAChangeMadeElsewhereClearsTheStack() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        try await cherryPickOther(tab)
        try "more\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "made in a terminal"], in: repo)
        tab.refresh()

        try await waitFor("the stale step to be dropped") { tab.undoStack.isEmpty }
        XCTAssertFalse(tab.toasts.contains { $0.action != nil })
    }

    @MainActor
    func testResettingToTheCurrentCommitRecordsNothing() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.resetTo(try rev("main"), mode: .soft)
        try await waitFor("the reset's note") { !tab.toasts.isEmpty && !tab.isBusy }

        XCTAssertTrue(tab.undoStack.isEmpty)
        XCTAssertNil(tab.toasts.last?.action, "nothing moved, so no Undo button")
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    /// `git status --porcelain`, which tells staged, unstaged and untracked apart.
    private func porcelain() throws -> [String] {
        try git(["status", "--porcelain"], in: repo).split(separator: "\n").map(String.init)
    }

    /// A second commit on main, then a staged and an unstaged edit on top: the state a reset
    /// back to the first commit changes, and its undo must put back.
    private func commitAndEditOnMain() throws -> (first: String, second: String) {
        let first = try rev("main")
        try write("README.md", "second\n")
        try git(["commit", "-q", "-am", "second"], in: repo)
        try write("staged.txt", "staged\n")
        try git(["add", "staged.txt"], in: repo)
        try write("README.md", "unstaged edit\n")
        return (first, try rev("main"))
    }

    // MARK: Each undoable action

    @MainActor
    func testUndoingASoftResetRestoresTheBranchAndItsStagedChanges() async throws {
        let (first, second) = try commitAndEditOnMain()
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let statusBefore = try porcelain()

        tab.resetTo(first, mode: .soft)
        try await waitFor("the soft reset") { try self.rev("main") == first && tab.latestUndo != nil && !tab.isBusy }
        XCTAssertEqual(tab.undoMenuTitle, "Undo Reset")

        tab.undo()
        try await waitFor("the undo") { try self.rev("main") == second && tab.undoStack.isEmpty && !tab.isBusy }
        XCTAssertEqual(try porcelain(), statusBefore, "staged and unstaged changes are as they were")
        XCTAssertEqual(try read("README.md"), "unstaged edit\n")
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testUndoingAMixedResetRestoresTheBranchAndKeepsTheFiles() async throws {
        let (first, second) = try commitAndEditOnMain()
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.resetTo(first, mode: .mixed)
        try await waitFor("the mixed reset") { try self.rev("main") == first && tab.latestUndo != nil && !tab.isBusy }

        tab.undo()
        try await waitFor("the undo") { try self.rev("main") == second && tab.undoStack.isEmpty && !tab.isBusy }
        // Git doesn't keep the earlier staging, so the staged file comes back unstaged.
        XCTAssertEqual(try porcelain(), [" M README.md", "?? staged.txt"])
        XCTAssertEqual(try read("README.md"), "unstaged edit\n")
        XCTAssertEqual(try read("staged.txt"), "staged\n")
    }

    @MainActor
    func testUndoingARevertBringsTheChangeBack() async throws {
        try write("README.md", "changed\n")
        try git(["commit", "-q", "-am", "change readme"], in: repo)
        let change = try rev("main")
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.revertCommit(change)
        try await waitFor("the revert") { tab.latestUndo != nil && !tab.isBusy }
        XCTAssertEqual(try read("README.md"), "hello\n")
        XCTAssertEqual(tab.undoMenuTitle, "Undo Revert")

        tab.undo()
        try await waitFor("the undo") { try self.rev("main") == change && tab.undoStack.isEmpty && !tab.isBusy }
        XCTAssertEqual(try read("README.md"), "changed\n")
        XCTAssertEqual(try porcelain(), [])
    }

    @MainActor
    func testUndoingACherryPickKeepsUnrelatedLocalEdits() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let before = try rev("main")
        try write("README.md", "local edit\n")

        try await cherryPickOther(tab)
        tab.undo()
        try await waitFor("the undo") { try self.rev("main") == before && tab.undoStack.isEmpty && !tab.isBusy }

        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("picked.txt").path))
        XCTAssertEqual(try read("README.md"), "local edit\n", "an edit to another file survives the undo")
        XCTAssertEqual(try porcelain(), [" M README.md"])
    }

    // MARK: What isn't undoable

    @MainActor
    func testAHardResetRecordsNoUndo() async throws {
        let (first, _) = try commitAndEditOnMain()
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.resetTo(first, mode: .hard)
        let confirmation = try XCTUnwrap(tab.pendingConfirmation, "a hard reset asks first")
        tab.executeConfirmed(confirmation)
        try await waitFor("the hard reset") { try self.rev("main") == first && !tab.isBusy }

        XCTAssertTrue(tab.undoStack.isEmpty, "the discarded changes can't be brought back")
        XCTAssertFalse(tab.canUndo)
    }

    @MainActor
    func testAConflictingCherryPickRecordsNoUndo() async throws {
        try git(["checkout", "-q", "other"], in: repo)
        try write("README.md", "other side\n")
        try git(["commit", "-q", "-am", "other readme"], in: repo)
        try git(["checkout", "-q", "main"], in: repo)
        try write("README.md", "main side\n")
        try git(["commit", "-q", "-am", "main readme"], in: repo)
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.cherryPick(try rev("other"))
        try await waitFor("the conflict to be reported") { tab.errorMessage != nil && !tab.isBusy }

        XCTAssertTrue(tab.undoStack.isEmpty, "the banner's Abort covers a stopped cherry-pick")
        XCTAssertFalse(tab.toasts.contains { $0.action != nil })
        try git(["cherry-pick", "--abort"], in: repo)
    }

    // MARK: Refusal and labels

    @MainActor
    func testAStaleUndoIsRefusedAndChangesNothing() async throws {
        let tab = try RepoTab(url: repo)
        // Let the first load finish (it prunes the stack once), and stop the watcher, so
        // nothing prunes the stale step before the undo runs.
        try await waitFor("the first load") { !tab.branches.isEmpty }
        tab.stopWatcher()
        let main = try rev("main")

        // A step whose "after" isn't where HEAD is: what's left once the branch moved on.
        let stale = HeadMove(
            before: HeadPosition(oid: main, branch: "refs/heads/main"),
            after: HeadPosition(oid: try rev("other"), branch: "refs/heads/main")
        )
        tab.recordUndo(actionName: "Cherry Pick", step: .moveHead(stale, mode: .keep), message: "Cherry-picked.")
        tab.undo()
        try await waitFor("the refusal") { tab.errorMessage != nil && !tab.isBusy }

        XCTAssertEqual(try rev("main"), main, "the refused undo leaves the branch alone")
        XCTAssertTrue(tab.undoStack.isEmpty, "a step that can't be undone leaves the stack")
        XCTAssertFalse(tab.toasts.contains { $0.action != nil }, "and its note goes too")
        XCTAssertTrue(tab.errorMessage?.contains("nothing to undo") == true, tab.errorMessage ?? "")
    }

    @MainActor
    func testTheMenuTitleNamesTheLatestStep() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        XCTAssertEqual(tab.undoMenuTitle, RepoTab.genericUndoTitle)
        XCTAssertFalse(tab.canUndo)

        try await cherryPickOther(tab)

        XCTAssertEqual(tab.undoMenuTitle, "Undo Cherry Pick")
        XCTAssertTrue(tab.canUndo)
    }

    @MainActor
    func testTheDoneNoteSaysWhereTheBranchIsNow() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let before = try rev("main")

        try await cherryPickOther(tab)
        tab.undo()
        try await waitFor("the undo") { tab.undoStack.isEmpty && !tab.isBusy }

        XCTAssertEqual(
            tab.toasts.last?.message,
            "Undid Cherry Pick. \"main\" is back at \(before.shortOid)."
        )
    }

    // MARK: Redo

    @MainActor
    func testRedoDoesACherryPickAgainAndOffersUndo() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let before = try rev("main")
        try write("README.md", "local edit\n")

        try await cherryPickOther(tab)
        let picked = try rev("main")
        tab.undo()
        try await waitFor("the undo") { try self.rev("main") == before && tab.latestRedo != nil && !tab.isBusy }
        XCTAssertEqual(tab.redoMenuTitle, "Redo Cherry Pick")
        XCTAssertTrue(tab.canRedo)

        tab.redo()
        try await waitFor("the redo") { try self.rev("main") == picked && tab.latestUndo != nil && !tab.isBusy }

        XCTAssertTrue(tab.redoStack.isEmpty)
        XCTAssertEqual(tab.undoMenuTitle, "Undo Cherry Pick")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("picked.txt").path))
        XCTAssertEqual(try read("README.md"), "local edit\n", "redo keeps local edits too")
        let note = try XCTUnwrap(tab.toasts.last)
        XCTAssertTrue(note.message.hasPrefix("Redid Cherry Pick."), note.message)
        XCTAssertEqual(note.action?.undoEntryID, tab.latestUndo?.id, "the redo can be undone again")
    }

    @MainActor
    func testRedoingASoftResetMovesTheBranchBackDown() async throws {
        let (first, second) = try commitAndEditOnMain()
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        tab.resetTo(first, mode: .soft)
        try await waitFor("the reset") { try self.rev("main") == first && tab.latestUndo != nil && !tab.isBusy }
        let statusAfterReset = try porcelain()
        tab.undo()
        try await waitFor("the undo") { try self.rev("main") == second && tab.latestRedo != nil && !tab.isBusy }

        tab.redo()
        try await waitFor("the redo") { try self.rev("main") == first && !tab.isBusy }
        XCTAssertEqual(try porcelain(), statusAfterReset, "the reset's changes are staged again")
    }

    @MainActor
    func testANewActionClearsRedo() async throws {
        try write("README.md", "changed\n")
        try git(["commit", "-q", "-am", "change readme"], in: repo)
        let change = try rev("main")
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        try await cherryPickOther(tab)
        tab.undo()
        try await waitFor("the undo") { tab.latestRedo != nil && !tab.isBusy }

        tab.revertCommit(change)
        try await waitFor("the revert") { tab.latestUndo?.actionName == "Revert" && !tab.isBusy }
        XCTAssertTrue(tab.redoStack.isEmpty)
        XCTAssertFalse(tab.canRedo)
        XCTAssertEqual(tab.redoMenuTitle, RepoTab.genericRedoTitle)
    }

    @MainActor
    func testAStaleRedoIsRefusedAndDropped() async throws {
        let tab = try RepoTab(url: repo)
        try await waitFor("the first load") { !tab.branches.isEmpty }
        tab.stopWatcher()
        let main = try rev("main")

        // Redo would move main from `other` to here, but main isn't at `other`.
        let stale = HeadMove(
            before: HeadPosition(oid: main, branch: "refs/heads/main"),
            after: HeadPosition(oid: try rev("other"), branch: "refs/heads/main")
        )
        tab.redoStack.append(RepoTab.UndoEntry(actionName: "Cherry Pick", step: .moveHead(stale, mode: .keep)))
        tab.redo()
        try await waitFor("the refusal") { tab.errorMessage != nil && !tab.isBusy }

        XCTAssertEqual(try rev("main"), main)
        XCTAssertTrue(tab.redoStack.isEmpty)
    }

    func testAnInverseRunsTheSameMoveBackwards() {
        let a = HeadPosition(oid: String(repeating: "a", count: 40), branch: "refs/heads/main")
        let b = HeadPosition(oid: String(repeating: "b", count: 40), branch: "refs/heads/main")
        guard case let .moveHead(move, mode) = UndoStep.moveHead(HeadMove(before: a, after: b), mode: .soft).inverse else {
            return XCTFail("a head move's inverse is a head move")
        }
        XCTAssertEqual(move, HeadMove(before: b, after: a))
        XCTAssertEqual(mode, .soft, "redo uses the same mode as the undo")
    }

    // MARK: Keys and menu titles

    func testTextFocusKeepsTheUndoKeys() {
        XCTAssertEqual(
            UndoKeyRouting.route(firstResponderIsText: false, keyWindowIsRepository: true, hasRepositoryStep: true),
            .repository
        )
        XCTAssertEqual(
            UndoKeyRouting.route(firstResponderIsText: true, keyWindowIsRepository: true, hasRepositoryStep: true),
            .text,
            "typing in the commit message undoes typing"
        )
        XCTAssertEqual(
            UndoKeyRouting.route(firstResponderIsText: false, keyWindowIsRepository: false, hasRepositoryStep: true),
            .text,
            "a sheet or Settings window keeps standard undo"
        )
        XCTAssertEqual(
            UndoKeyRouting.route(firstResponderIsText: false, keyWindowIsRepository: true, hasRepositoryStep: false),
            .text,
            "with nothing to undo in the repository, the key does what it normally does"
        )
    }

    @MainActor
    func testTitlesStopNamingTheStepWhileEditingText() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        try await cherryPickOther(tab)
        XCTAssertEqual(tab.undoMenuTitle, "Undo Cherry Pick")

        tab.isEditingText = true
        XCTAssertEqual(tab.undoMenuTitle, RepoTab.genericUndoTitle)

        tab.isEditingText = false
        XCTAssertEqual(tab.undoMenuTitle, "Undo Cherry Pick")
    }

    @MainActor
    func testTheUndoButtonShowsItsShortcut() async throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        try await cherryPickOther(tab)
        XCTAssertEqual(tab.toasts.last?.action?.help, "Undo Cherry Pick (⌘Z)")
    }

    @MainActor
    func testTheStackForgetsTheOldestPastItsLimit() throws {
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }
        let position = HeadPosition(oid: try rev("main"), branch: "refs/heads/main")
        let step = UndoStep.moveHead(HeadMove(before: position, after: position), mode: .keep)

        for index in 1 ... RepoTab.maxUndoSteps + 2 {
            tab.recordUndo(actionName: "Step \(index)", step: step, message: "Note \(index)")
        }

        XCTAssertEqual(tab.undoStack.count, RepoTab.maxUndoSteps)
        XCTAssertEqual(tab.undoStack.first?.actionName, "Step 3")
        XCTAssertEqual(tab.latestUndo?.actionName, "Step \(RepoTab.maxUndoSteps + 2)")
    }
}
