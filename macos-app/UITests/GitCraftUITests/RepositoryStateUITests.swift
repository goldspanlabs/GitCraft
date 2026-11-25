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
        // README.md is the same at "initial" and main, so a plain checkout carries the edit over.
        try launch(fixture: FixtureRepository.make(twoBranches: true, unstagedFiles: ["README.md"]))
        XCTAssertTrue(element("unstaged-file:README.md").waitForExistence(timeout: 60))
        try checkOut("initial", choosing: "Don't change")
        XCTAssertTrue(try fixture.isModified("README.md"), "the edit comes along")
        XCTAssertEqual(try fixture.stashMessages().count, 0)
    }

    func testCheckoutCommitWithStashAndReapplyDetachesAndBringsTheEditBack() throws {
        // story.txt differs between "add story" and main, so a plain checkout would refuse to
        // overwrite the local edit. Stashing first lets it through, and the edit is far enough
        // from main's change that reapplying it merges cleanly.
        let fixture = try FixtureRepository.make()
        let lines = ["one", "two", "three", "four", "five", "six"]
        try fixture.commitFile("story.txt", contents: lines.joined(separator: "\n") + "\n", message: "add story")
        var mainLines = lines
        mainLines[5] = "six (main)"
        try fixture.commitFile("story.txt", contents: mainLines.joined(separator: "\n") + "\n", message: "edit story")
        var localLines = mainLines
        localLines[0] = "one (local)"
        let story = (fixture.mainPath as NSString).appendingPathComponent("story.txt")
        try (localLines.joined(separator: "\n") + "\n").write(toFile: story, atomically: true, encoding: .utf8)

        try launch(fixture: fixture)
        XCTAssertTrue(element("unstaged-file:story.txt").waitForExistence(timeout: 60))
        try checkOut("add story", choosing: "Stash and reapply")

        var expected = lines
        expected[0] = "one (local)"
        let reapplied = expected.joined(separator: "\n") + "\n"
        XCTAssertTrue(
            waitUntil(timeout: 20) { (try? String(contentsOfFile: story, encoding: .utf8)) == reapplied },
            "the edit is reapplied on top of the checked-out commit"
        )
        XCTAssertTrue(
            waitUntil(timeout: 20) { (try? self.fixture.stashMessages().count) == 0 },
            "the temporary stash is popped, not left behind"
        )
    }

    func testCheckoutCommitWithDiscardAsksAgainThenDropsAllLocalChanges() throws {
        // A staged edit to README.md, an unstaged one to main.txt, and untracked notes.txt.
        try launch(fixture: FixtureRepository.make(
            stagedChange: true,
            twoBranches: true,
            unstagedFiles: ["main.txt"],
            untrackedFile: true
        ))
        let untracked = (fixture.mainPath as NSString).appendingPathComponent(FixtureRepository.untrackedFileName)
        XCTAssertTrue(element("staged-file:README.md").waitForExistence(timeout: 60))
        try checkOut("initial", choosing: "Discard") {
            let confirm = self.app.sheets.buttons["Discard Changes and Checkout"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "discarding asks a second time")
            XCTAssertEqual(try self.fixture.stagedFiles(), ["README.md"], "the staged edit is kept while it asks")
            XCTAssertTrue(try self.fixture.isModified("main.txt"), "the unstaged edit is kept while it asks")
            XCTAssertTrue(FileManager.default.fileExists(atPath: untracked), "the untracked file is kept while it asks")
            confirm.click()
        }
        XCTAssertEqual(try fixture.stagedFiles(), [], "nothing is left staged")
        XCTAssertEqual(try fixture.git(["show", ":README.md"]), "hello\n", "the staged edit is discarded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked), "the untracked file is removed")
        XCTAssertEqual(
            try fixture.git(["status", "--porcelain"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "the working tree is clean"
        )
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
        let long = String(repeating: "long-name-", count: 8) + "end"
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

    /// Checks out the history row whose summary is `summary` from its menu, picking `option` for
    /// local changes. `confirm` handles any second prompt. Checks that HEAD ends up detached at
    /// that commit, and that main still points where it did.
    private func checkOut(
        _ summary: String,
        choosing option: String,
        confirm: (() throws -> Void)? = nil
    ) throws {
        let target = try fixture.git(["log", "-1", "--format=%H", "--fixed-strings", "--grep=\(summary)", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mainBefore = try fixture.commitID("refs/heads/main")

        let row = app.staticTexts[summary]
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
        XCTAssertEqual(try fixture.commitID("HEAD"), target, "at the chosen commit")
        XCTAssertEqual(try fixture.commitID("refs/heads/main"), mainBefore, "main is left where it was")
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

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
