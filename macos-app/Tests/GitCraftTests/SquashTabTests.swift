import SwiftUI
import XCTest
@testable import GitCraft

/// Selecting several commits and squashing them, against a real repository.
final class SquashTabTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        root = temporaryFolderURL("gitcraft-squash-test")
        repo = try makeTestRepository(at: root.appendingPathComponent("repo", isDirectory: true))
        for name in ["one", "two", "three"] {
            try "\(name)\n".write(to: repo.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            try git(["add", "-A"], in: repo)
            try git(["commit", "-q", "-m", name], in: repo)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func head() throws -> String {
        try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subjects() throws -> [String] {
        try git(["log", "--format=%s"], in: repo).split(separator: "\n").map(String.init)
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
    private func loadedTab() async throws -> RepoTab {
        let tab = try RepoTab(url: repo)
        tab.refresh()
        try await waitFor("the history") { tab.commits.count == 4 }
        return tab
    }

    @MainActor
    private func rows(_ tab: RepoTab, _ summaries: [String]) -> [CommitRow] {
        tab.commits.filter { summaries.contains($0.summary) }
    }

    @MainActor
    private func allowedPreview(_ tab: RepoTab, _ summaries: [String]) async throws -> SquashPreview {
        tab.selectCommitsFromTable(rows(tab, summaries))
        try await waitFor("the squash check") { tab.squashCheck != .checking }
        guard case let .allowed(preview) = tab.squashCheck else {
            XCTFail("unexpectedly refused: \(tab.squashCheck)")
            throw CancellationError()
        }
        return preview
    }

    @MainActor
    func testSelectingSeveralCommitsChecksTheSquash() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        tab.selectCommitFromTable(rows(tab, ["one"]).first)

        tab.selectCommitsFromTable(rows(tab, ["two", "three"]))

        XCTAssertEqual(tab.selectedCommits.map(\.summary), ["three", "two"])
        XCTAssertNil(tab.selectedCommit)
        XCTAssertNil(tab.commitDetail)
        try await waitFor("the squash check") { tab.squashCheck != .checking }
        guard case let .allowed(preview) = tab.squashCheck else {
            return XCTFail("refused: \(tab.squashCheck)")
        }
        XCTAssertEqual(preview.commits.map(\.summary), ["two", "three"])
    }

    @MainActor
    func testAGapIsRefusedWithItsReason() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }

        tab.selectCommitsFromTable(rows(tab, ["one", "three"]))

        try await waitFor("the refusal") { tab.squashCheck == .refused("Select consecutive commits") }
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testCommittingIsOffWithSeveralCommitsSelected() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        tab.commitSummary = "draft"
        tab.amendCommit = true
        XCTAssertTrue(tab.canAmend)

        tab.selectCommitsFromTable(rows(tab, ["two", "three"]))

        XCTAssertFalse(tab.canAmend)
        XCTAssertFalse(tab.canCommit(autoStage: true))
    }

    @MainActor
    func testSelectingOneRowEndsTheMultiSelection() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        tab.selectCommitsFromTable(rows(tab, ["two", "three"]))

        tab.selectCommitsFromTable(rows(tab, ["one"]))

        XCTAssertTrue(tab.selectedCommits.isEmpty)
        XCTAssertEqual(tab.selectedCommit?.summary, "one")

        tab.selectCommitsFromTable(rows(tab, ["two", "three"]))
        tab.selectCommitsFromTable([])

        XCTAssertTrue(tab.selectedCommits.isEmpty)
        XCTAssertNil(tab.selectedCommit)
    }

    @MainActor
    func testSquashSelectsTheNewCommitAndCanBeUndone() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let before = try head()
        tab.commitSummary = "draft"
        tab.commitBody = "body"
        let preview = try await allowedPreview(tab, ["two", "three"])

        tab.squash(preview, summary: "two and three", description: "Both.")
        try await waitFor("the squash to be selected") {
            !tab.isBusy && tab.selectedCommit?.summary == "two and three"
        }

        XCTAssertEqual(try subjects(), ["two and three", "one", "initial"])
        XCTAssertTrue(try git(["log", "-1", "--format=%B"], in: repo).hasPrefix("two and three\n\nBoth."))
        XCTAssertTrue(tab.selectedCommits.isEmpty)
        XCTAssertEqual(tab.selectedCommit?.oidHex, try head())
        XCTAssertEqual(tab.commitSummary, "draft")
        XCTAssertEqual(tab.commitBody, "body")
        XCTAssertEqual(tab.latestUndo?.actionName, "Squash")
        let toast = try XCTUnwrap(tab.toasts.last)
        XCTAssertEqual(toast.message, "Squashed 2 commits on \"main\".")
        XCTAssertEqual(toast.action?.title, "Undo")

        tab.undo()
        try await waitFor("the undo") { try self.head() == before && !tab.isBusy }
        XCTAssertNil(tab.errorMessage)
    }

    @MainActor
    func testReloadDropsCommitsThatVanished() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        _ = try await allowedPreview(tab, ["one", "two", "three"])

        try git(["commit", "-q", "--amend", "-m", "three again"], in: repo)
        tab.refresh()

        try await waitFor("the selection to shrink") {
            guard case let .allowed(preview) = tab.squashCheck else { return false }
            let head = try self.head()
            return tab.selectedCommits.map(\.summary) == ["two", "one"]
                && preview.commits.map(\.summary) == ["one", "two"]
                && preview.head.oid == head
        }
    }

    @MainActor
    func testConflictsAppearingAndClearingRecheckTheSelection() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        _ = try await allowedPreview(tab, ["two", "three"])
        // Only status reloads from here on, as when nothing in the history changed.
        tab.stopWatcher()
        let file = repo.appendingPathComponent("one.txt")
        try "stashed\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["stash", "-q"], in: repo)
        try "committed\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "four"], in: repo)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["stash", "pop", "-q"]
        process.currentDirectoryURL = repo
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        tab.refreshStatus()
        try await waitFor("the conflict to refuse the squash") {
            tab.squashCheck == .refused("Finish the current operation first")
        }

        try git(["add", "one.txt"], in: repo)
        tab.refreshStatus()
        try await waitFor("the squash to be allowed again") {
            if case .allowed = tab.squashCheck { return true }
            return false
        }
    }

    @MainActor
    func testTheMultiSelectionPanelOpensACollapsedPane() async throws {
        let defaults = UserDefaults.standard
        let keys = [BottomPanelDefaults.collapsedKey, BottomPanelDefaults.maximizedKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { zip(keys, saved).forEach { defaults.set($1, forKey: $0) } }
        keys.forEach { defaults.set(true, forKey: $0) }
        let tab = try RepoTab(url: repo)
        defer { tab.stopWatcher() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MultiCommitInspectorView(tab: tab))
        window.orderFrontRegardless()
        defer { window.close() }

        try await waitFor("the pane to reopen") { keys.allSatisfy { !defaults.bool(forKey: $0) } }
    }

    @MainActor
    func testUndoingASquashClearsTheSelectionOfTheCommitThatIsGone() async throws {
        let tab = try await loadedTab()
        defer { tab.stopWatcher() }
        let preview = try await allowedPreview(tab, ["two", "three"])
        tab.squash(preview, summary: "both", description: "")
        try await waitFor("the squash to be selected") {
            !tab.isBusy && tab.selectedCommit?.summary == "both"
        }
        XCTAssertFalse(tab.canAmend)

        tab.undo()

        try await waitFor("the selection to clear") { !tab.isBusy && tab.selectedCommit == nil }
        XCTAssertNil(tab.commitDetail)
        XCTAssertTrue(tab.canAmend)
    }

    @MainActor
    func testMenuTitleCarriesTheReason() {
        XCTAssertEqual(
            RepoTab.squashMenuTitle(check: .refused("Select consecutive commits")),
            "Squash Commits (select consecutive commits)"
        )
        XCTAssertEqual(RepoTab.squashMenuTitle(check: .checking), "Squash Commits…")
    }
}
