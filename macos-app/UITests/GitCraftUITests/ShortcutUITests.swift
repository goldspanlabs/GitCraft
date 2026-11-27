import XCTest

/// The menu bar's items and keyboard shortcuts.
final class ShortcutUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    // MARK: Menu items

    func testNewMenuItemsExist() throws {
        try launch(fixture: FixtureRepository.make())

        let repository = app.menuBarItems["Repository"]
        repository.click()
        for title in [
            "Amend Last Commit", "Skip Hooks", "Commit and Push", "Stage All Changes", "Unstage All Changes",
            "Apply Latest Stash", "Pop Latest Stash", "Add Remote…", "Prune Stale Worktrees",
        ] {
            XCTAssertTrue(repository.menuItems[title].exists, "Repository ▸ \(title)")
        }
        XCTAssertFalse(repository.menuItems["Apply Latest Stash"].isEnabled)
        XCTAssertFalse(repository.menuItems["Pop Latest Stash"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let view = app.menuBarItems["View"]
        view.click()
        for title in ["Show Current Branch Only", "Go to HEAD", "Go to Working Changes"] {
            XCTAssertTrue(view.menuItems[title].exists, "View ▸ \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])

        let edit = app.menuBarItems["Edit"]
        edit.click()
        XCTAssertTrue(edit.menuItems["Filter Commits"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: Shortcuts

    func testCommandFFocusesTheCommitFilter() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true))

        app.typeKey("f", modifierFlags: .command)
        app.typeText("feature")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(wait(for: search, toSatisfy: "value == 'feature'", timeout: 10))
    }

    func testStageAndUnstageAllShortcuts() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true, unstagedFiles: ["README.md"]))
        XCTAssertTrue(app.element("unstaged-file:README.md").waitForExistence(timeout: 60))

        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.fixture.stagedFiles()) == ["README.md"] }, "⇧⌘E stages")
        XCTAssertTrue(app.element("staged-file:README.md").waitForExistence(timeout: 20))

        app.typeKey("e", modifierFlags: [.command, .shift, .option])
        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.fixture.stagedFiles()) == [] }, "⌥⇧⌘E unstages")
    }

    func testControlCommandSTogglesTheSidebarAndShiftCommandSStashes() throws {
        try launch(fixture: FixtureRepository.make(unstagedFiles: ["README.md"]))
        XCTAssertTrue(app.element("unstaged-file:README.md").waitForExistence(timeout: 60))
        let header = app.staticTexts["LOCAL BRANCHES"]
        XCTAssertTrue(header.isHittable)

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil(timeout: 10) { !header.exists || !header.isHittable }, "⌃⌘S hides the sidebar")
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil(timeout: 10) { header.exists && header.isHittable }, "⌃⌘S shows it again")

        app.typeKey("s", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Stash Changes"].waitForExistence(timeout: 10), "⇧⌘S stashes")
    }

    func testGoToHeadAndWorkingChanges() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true))
        XCTAssertTrue(app.staticTexts["main work"].waitForExistence(timeout: 60))

        app.typeKey("0", modifierFlags: .command)
        let changedFiles = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'CHANGED FILES'")).firstMatch
        XCTAssertTrue(changedFiles.waitForExistence(timeout: 20), "⌘0 shows HEAD's commit")

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["UNSTAGED CHANGES (0)"].waitForExistence(timeout: 20), "⌘1 goes back")
    }

    func testCommitItemsAreBlockedWhileACommitIsSelected() throws {
        try launch(fixture: FixtureRepository.make(stagedChange: true, bareRemote: true))
        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        summary.click()
        summary.typeText("leftover")
        let before = try fixture.commitID("main")

        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(summary.waitForNonExistence(timeout: 10), "the commit fields are hidden")
        let repository = app.menuBarItems["Repository"]
        repository.click()
        for title in ["Commit", "Commit and Push", "Amend Last Commit"] {
            XCTAssertFalse(repository.menuItems[title].isEnabled, "\(title) is blocked")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.return, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [.command, .shift])
        XCTAssertFalse(
            waitUntil(timeout: 3) { (try? self.fixture.commitID("main")) != before },
            "nothing is committed"
        )

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.commitID("main")) != before },
            "committing works again"
        )
    }

    func testPushShortcutIsInertWhileASheetIsOpen() throws {
        let fixture = try FixtureRepository.make(bareRemote: true)
        try fixture.commitFile("ahead.txt", contents: "ahead\n", message: "ahead of origin")
        try launch(fixture: fixture)
        XCTAssertTrue(app.staticTexts["ahead of origin"].waitForExistence(timeout: 60))
        let local = try fixture.commitID("main")
        let remoteBefore = fixture.remoteCommitID("refs/heads/main")
        XCTAssertNotEqual(remoteBefore, local)

        app.typeKey("b", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Create Branch"].waitForExistence(timeout: 10))
        app.typeKey("u", modifierFlags: [.command, .shift])
        XCTAssertFalse(
            waitUntil(timeout: 3) { fixture.remoteCommitID("refs/heads/main") != remoteBefore },
            "nothing is pushed while a sheet is open"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Create Branch"].waitForNonExistence(timeout: 10))
        app.typeKey("u", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitUntil(timeout: 30) { fixture.remoteCommitID("refs/heads/main") == local },
            "⇧⌘U pushes"
        )
    }

    /// macOS's own Edit ▸ Find items also claim ⌘F and ⇧⌘G, and they act on text views.
    func testNewTagAndFilterShortcutsWorkWhileEditingTheDescription() throws {
        try launch(fixture: FixtureRepository.make(stagedChange: true))
        let description = app.windows.firstMatch.textViews.firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 60))
        description.click()
        description.typeText("body text")

        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Create Tag"].waitForExistence(timeout: 10), "⇧⌘G opens New Tag")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Create Tag"].waitForNonExistence(timeout: 10))

        description.click()
        app.typeKey("f", modifierFlags: .command)
        app.typeText("needle")
        XCTAssertTrue(wait(for: app.searchFields.firstMatch, toSatisfy: "value == 'needle'", timeout: 10), "⌘F filters")
        XCTAssertEqual(description.value as? String, "body text")

        app.menuBarItems["Edit"].click()
        print("EDIT-MENU", app.menuBarItems["Edit"].menuItems.allElementsBoundByIndex.map { "\($0.title)|\($0.isEnabled)" })
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: Closing windows and sheets

    func testCommandWClosesSettingsWithNoRepositoryWindow() throws {
        try launch(fixture: FixtureRepository.make())

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["LOCAL BRANCHES"].waitForNonExistence(timeout: 10))

        app.typeKey(",", modifierFlags: .command)
        let appearance = app.staticTexts["Appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 10), "Settings is open")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(appearance.waitForNonExistence(timeout: 10), "⌘W closes Settings")
    }

    func testEscapeClosesTheExpandedDescription() throws {
        try launch(fixture: FixtureRepository.make(stagedChange: true))
        let expand = app.element("expand-description")
        XCTAssertTrue(expand.waitForExistence(timeout: 60))
        expand.click()
        let title = app.staticTexts["Extended description"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // Escape has to work while typing, which is where the cursor is.
        let editor = app.sheets.firstMatch.textViews.firstMatch
        editor.click()
        editor.typeText("body")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "Escape closes the sheet")
    }

    func testEscapeClosesErrorDetails() throws {
        let fixture = try FixtureRepository.make(stagedChange: true)
        let hook = URL(fileURLWithPath: fixture.mainPath).appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho first line\necho second line\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try launch(fixture: fixture)
        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        summary.click()
        summary.typeText("blocked")
        app.typeKey(.return, modifierFlags: .command)

        let showDetails = app.buttons["Show Details…"].firstMatch
        XCTAssertTrue(showDetails.waitForExistence(timeout: 20))
        showDetails.click()
        let title = app.sheets.firstMatch.staticTexts["Details"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "Escape closes the details")
    }

    // MARK: Undo in text

    func testCommandZUndoesTypingInTheCommitDescription() throws {
        try launch(fixture: FixtureRepository.make(stagedChange: true))
        let description = app.textViews["commit-description"]
        XCTAssertTrue(description.waitForExistence(timeout: 20))
        description.click()
        description.typeText("Some details")
        XCTAssertTrue(wait(for: description, toSatisfy: "value == 'Some details'", timeout: 10))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            wait(for: description, toSatisfy: "value == ''", timeout: 10),
            "⌘Z undoes the typing: \(String(describing: description.value))"
        )

        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            wait(for: description, toSatisfy: "value == 'Some details'", timeout: 10),
            "⇧⌘Z redoes it"
        )
    }

    func testCommandZUndoesTypingInTheCommitSummary() throws {
        try launch(fixture: FixtureRepository.make(stagedChange: true))
        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        summary.click()
        summary.typeText("Fix it")
        XCTAssertTrue(wait(for: summary, toSatisfy: "value == 'Fix it'", timeout: 10))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            wait(for: summary, toSatisfy: "value != 'Fix it'", timeout: 10),
            "⌘Z undoes the typing: \(String(describing: summary.value))"
        )
    }

    // MARK: Helpers

    private func launch(fixture: FixtureRepository) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
        XCTAssertTrue(app.staticTexts["LOCAL BRANCHES"].waitForExistence(timeout: 60))
    }
}
