import XCTest

/// End-to-end checks for repositories in states that assume less than usual: no commits yet,
/// no branch checked out, a folder that isn't a repository, no repository at all, a long
/// history, and branch names that aren't plain ASCII.
final class RepositoryStateUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testARepositoryWithNoCommitsOpensAndMakesTheFirstCommit() throws {
        // An unborn main with an untracked README.md; auto-staging (the default) stages it.
        try launch(
            fixture: FixtureRepository.make(noCommits: true),
            // Auto-staging is a persisted preference; force it on so the untracked file counts.
            extraArguments: ["-autoStageOnCommit", "YES"]
        )

        XCTAssertTrue(
            text(containing: "No commits yet").waitForExistence(timeout: 60),
            "the empty history explains how to start"
        )
        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        summary.click()
        summary.typeText("First commit")

        let commit = app.buttons["commit-button"]
        XCTAssertTrue(wait(for: commit, toSatisfy: "isEnabled == true", timeout: 20))
        commit.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.commitID("refs/heads/main")) != nil },
            "main is born"
        )
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "main"]).trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertTrue(
            try fixture.git(["ls-tree", "--name-only", "main"]).contains("README.md"),
            "the first commit holds the file"
        )
        XCTAssertTrue(app.staticTexts["First commit"].waitForExistence(timeout: 20), "the commit shows in the history")
    }

    func testDetachedHeadShowsTheHeadRowAndNoBranchActions() throws {
        // HEAD is detached at "initial", one commit behind main.
        try launch(
            fixture: FixtureRepository.make(twoBranches: true, detachedHead: true),
            extraArguments: ["-sidebar.localBranchesExpanded", "YES"]
        )

        XCTAssertTrue(app.staticTexts["DETACHED"].waitForExistence(timeout: 60), "the sidebar shows the detached HEAD")
        XCTAssertTrue(element("branch-row:main").exists, "main is still listed as a branch")

        // With no branch checked out, there is nothing to merge into, rebase or reset.
        let row = app.staticTexts["initial"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        rightClick(row)
        XCTAssertTrue(app.menuItems["Cherry Pick Commit"].waitForExistence(timeout: 10), "the commit menu is open")
        let branchActions = app.menuItems.matching(
            // Menu items expose their text as title, and on some OS versions as label too.
            NSPredicate(
                format: "title CONTAINS %@ OR title BEGINSWITH %@ OR label CONTAINS %@ OR label BEGINSWITH %@",
                "to Here", "Merge into", "to Here", "Merge into"
            )
        )
        XCTAssertEqual(branchActions.count, 0, "no merge, rebase or reset items while detached")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: Checkout Commit

    func testCheckoutCommitWithDontChangeDetachesAndKeepsTheEdit() throws {
        try checkOutInitial(choosing: "Don't change")
        XCTAssertTrue(try fixture.isModified("README.md"), "the edit comes along")
        XCTAssertEqual(try fixture.stashMessages().count, 0)
    }

    func testCheckoutCommitWithStashAndReapplyDetachesAndBringsTheEditBack() throws {
        try checkOutInitial(choosing: "Stash and reapply")
        XCTAssertTrue(
            waitUntil(timeout: 20) { (try? self.fixture.isModified("README.md")) == true },
            "the edit is reapplied"
        )
        XCTAssertEqual(try fixture.stashMessages().count, 0, "the temporary stash is popped, not left behind")
    }

    func testCheckoutCommitWithDiscardAsksAgainThenDropsTheEdit() throws {
        try checkOutInitial(choosing: "Discard") {
            let confirm = self.app.buttons["Discard Changes and Checkout"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "discarding asks a second time")
            XCTAssertTrue(try self.fixture.isModified("README.md"), "nothing is discarded while it asks")
            confirm.click()
        }
        XCTAssertFalse(try fixture.isModified("README.md"), "the edit is discarded")
    }

    // MARK: No repository

    func testAFolderThatIsNotARepositoryShowsAnError() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-ui-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", folder.path, "-openRepositoryTabs", "()"]
        app.launch()

        XCTAssertTrue(
            text(containing: "Unable to open \(folder.lastPathComponent)").waitForExistence(timeout: 60),
            "the app says why it couldn't open the folder"
        )
        XCTAssertFalse(app.textFields["commit-summary"].exists, "no empty repository window opens")
    }

    func testTheWelcomeScreenShowsWhenNoTabsAreRestored() throws {
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        // No repository to open, and no saved tabs to restore.
        app.launchArguments = ["-openRepositoryTabs", "()"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to GitCraft"].waitForExistence(timeout: 60), "the first window isn't blank")
    }

    // MARK: Long history

    func testALongHistoryShowsAndScrolls() throws {
        try launch(fixture: FixtureRepository.make(extraCommits: 2000))

        XCTAssertTrue(app.staticTexts["Commit 2000"].waitForExistence(timeout: 60), "the newest commit shows")
        let table = app.tables.firstMatch
        XCTAssertTrue(table.exists)
        // Scroll down until a commit far below the first screen appears; the graph loads more
        // rows as it goes.
        let deep = app.staticTexts["Commit 1500"]
        for _ in 0..<40 where !deep.exists {
            table.scroll(byDeltaX: 0, deltaY: -1500)
        }
        XCTAssertTrue(deep.waitForExistence(timeout: 20), "older commits load while scrolling")
    }

    // MARK: Unusual branch names

    func testNonASCIIAndLongBranchNamesShowAndCanBeCheckedOut() throws {
        let long = String(repeating: "long-name-", 8) + "end"
        try launch(
            fixture: FixtureRepository.make(extraBranches: ["日本語", "ветка", long]),
            extraArguments: ["-sidebar.localBranchesExpanded", "YES"]
        )

        XCTAssertTrue(element("branch-row:日本語").waitForExistence(timeout: 60))
        XCTAssertTrue(element("branch-row:ветка").exists)
        XCTAssertTrue(element("branch-row:\(long)").exists, "a long name is listed")

        let row = element("branch-row:ветка")
        rightClick(row)
        let checkout = app.menuItems["Checkout"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        checkout.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) {
                (try? self.fixture.git(["symbolic-ref", "--short", "HEAD"]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "ветка"
            },
            "the Cyrillic branch is checked out"
        )
    }

    // MARK: Helpers

    /// Opens a repo where main has "initial" and "main work", and README.md has an unstaged
    /// edit, then checks out "initial" from its menu with `option` for local changes. `confirm`
    /// handles any second prompt. Checks that HEAD ends up detached at "initial".
    private func checkOutInitial(choosing option: String, confirm: (() throws -> Void)? = nil) throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true, unstagedFiles: ["README.md"]))
        let initial = try fixture.commitID("main~1")
        XCTAssertTrue(element("unstaged-file:README.md").waitForExistence(timeout: 60))

        let row = app.staticTexts["initial"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        rightClick(row)
        let item = app.menuItems["Checkout Commit…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()

        let choice = app.sheets.radioButtons[option]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the sheet offers \(option)")
        choice.click()
        let checkout = app.sheets.buttons["Checkout"]
        XCTAssertTrue(checkout.exists)
        checkout.click()
        try confirm?()

        XCTAssertTrue(
            waitUntil(timeout: 30) {
                (try? self.fixture.git(["rev-parse", "--abbrev-ref", "HEAD"]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "HEAD"
            },
            "HEAD is detached"
        )
        XCTAssertEqual(try fixture.commitID("HEAD"), initial, "at the chosen commit")
        XCTAssertNotNil(try? fixture.commitID("refs/heads/main"), "main is left where it was")
    }

    private func launch(fixture: FixtureRepository, extraArguments: [String] = []) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath] + extraArguments
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    /// Text anywhere in the app whose value or label contains `fragment`.
    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", fragment, fragment))
            .firstMatch
    }

    /// Right-clicks the centre of `element` by coordinate. Rows are containers that XCUITest can
    /// report as not hittable even when they are on screen.
    private func rightClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    }

    private func wait(for element: XCUIElement, toSatisfy predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Polls `condition` until it holds or `timeout` passes. Used for checks on the repository
    /// on disk, which the UI changes asynchronously.
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
