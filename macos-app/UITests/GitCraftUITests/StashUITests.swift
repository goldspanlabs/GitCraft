import XCTest

/// End-to-end checks for saving and dropping stashes from the sidebar's STASHES section.
final class StashUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The save test needs changes to stash, the no-changes test needs none, and the
        // conflicting pop needs stashes plus a local edit to the file they change.
        if name.contains("Save") {
            fixture = try FixtureRepository.make(unstagedFiles: ["README.md"], untrackedFile: true)
        } else if name.contains("NoChanges") {
            fixture = try FixtureRepository.make()
        } else if name.contains("Conflicts") {
            fixture = try FixtureRepository.make(unstagedFiles: ["README.md"], stashes: true)
        } else {
            fixture = try FixtureRepository.make(stashes: true)
        }
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = [
            "-UITestOpenRepository", fixture.mainPath,
            // STASHES starts collapsed; its expanded state is a persisted user preference.
            "-sidebar.stashesExpanded", "YES",
        ]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testSaveStashIncludesUntrackedFilesByDefault() throws {
        let untracked = (fixture.mainPath as NSString).appendingPathComponent(FixtureRepository.untrackedFileName)
        let header = app.staticTexts["STASHES"]
        XCTAssertTrue(header.waitForExistence(timeout: 60))
        // The menu item is enabled only once the app has loaded the changes.
        XCTAssertTrue(element("unstaged-file:README.md").waitForExistence(timeout: 60))
        rightClick(header)
        let item = app.menuItems["Stash Changes…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()

        let includeUntracked = app.sheets.checkBoxes["Include untracked files"]
        XCTAssertTrue(includeUntracked.waitForExistence(timeout: 10), "the Stash sheet opens")
        // XCUITest reports a checkbox's value as 1 or "1" depending on the OS; compare its text.
        XCTAssertEqual("\(includeUntracked.value ?? "")", "1", "untracked files are included by default")
        let stash = app.sheets.buttons["Stash"]
        XCTAssertTrue(stash.waitForExistence(timeout: 10))
        stash.click()

        // git records the stash before it finishes cleaning the working tree, so wait for both.
        XCTAssertTrue(
            waitUntil(timeout: 30) {
                (try? self.fixture.stashMessages().count) == 1
                    && (try? self.fixture.isModified("README.md")) == false
                    && !FileManager.default.fileExists(atPath: untracked)
            },
            "one stash is saved, holding the tracked edit and the untracked file"
        )
        let trackedDiff = try fixture.git(["diff", "stash@{0}^1", "stash@{0}", "--", "README.md"])
        XCTAssertTrue(trackedDiff.contains("+edited"), "the stash holds the tracked edit")
        let stashed = try fixture.git(["show", "--name-only", "--format=", "stash@{0}^3"])
        XCTAssertTrue(stashed.contains(FixtureRepository.untrackedFileName), "the stash holds the untracked file")
        XCTAssertTrue(element("stash-row:0").waitForExistence(timeout: 20), "the stash is listed in the sidebar")
    }

    func testDropStashAsksFirstThenRemovesOnlyThatStash() throws {
        // Drop the older stash, stash@{1}, so the test also catches an off-by-one index.
        let row = element("stash-row:1")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "both stashes are listed")
        rightClick(row)
        let item = app.menuItems["Drop stash@{1}…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()

        let drop = app.sheets.buttons["Drop"]
        XCTAssertTrue(drop.waitForExistence(timeout: 10), "dropping asks first")
        XCTAssertEqual(try fixture.stashMessages().count, 2, "nothing is dropped while the dialog is open")
        drop.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.stashMessages().count) == 1 },
            "one stash is left"
        )
        let left = try fixture.stashMessages()
        XCTAssertEqual(left.count, 1)
        XCTAssertTrue(left.first?.hasSuffix("second stash") == true, "the newer stash is the one kept, got \(left)")
    }

    func testPopRemovesTheStashAndRestoresItsChanges() throws {
        let row = element("stash-row:0")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the stashes are listed")
        rightClick(row)
        let pop = app.menuItems["Pop stash@{0}"]
        XCTAssertTrue(pop.waitForExistence(timeout: 10))
        pop.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.stashMessages().count) == 1 },
            "popping removes the stash"
        )
        XCTAssertTrue(try fixture.stashMessages().first?.hasSuffix("first stash") == true, "the older stash is kept")
        XCTAssertEqual(try readme(), "second stash\n", "the newest stash's change is back in the working tree")
    }

    func testApplyRestoresTheChangesAndKeepsTheStash() throws {
        let row = element("stash-row:0")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the stashes are listed")
        rightClick(row)
        let apply = app.menuItems["Apply stash@{0}"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.readme()) == "second stash\n" },
            "the newest stash's change is back in the working tree"
        )
        XCTAssertEqual(try fixture.stashMessages().count, 2, "applying keeps both stashes")
        XCTAssertTrue(element("stash-row:0").exists, "the applied stash is still listed")
    }

    func testStashChangesIsDisabledWithNoChanges() throws {
        let header = app.staticTexts["STASHES"]
        XCTAssertTrue(header.waitForExistence(timeout: 60))
        // Wait for the app to load the (clean) working tree before reading the menu.
        XCTAssertTrue(app.staticTexts["Working tree clean"].waitForExistence(timeout: 60))
        rightClick(header)
        let item = app.menuItems["Stash Changes…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertFalse(item.isEnabled, "there is nothing to stash")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["Stash…"].firstMatch.isEnabled, "the composer's Stash button is disabled too")
    }

    func testPopThatConflictsWithLocalEditsKeepsTheStashAndTheEdits() throws {
        // README.md has an unstaged edit, and stash@{0} changes README.md too.
        let editedBefore = try readme()
        let row = element("stash-row:0")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the stashes are listed")
        XCTAssertTrue(element("unstaged-file:README.md").waitForExistence(timeout: 60))
        rightClick(row)
        let pop = app.menuItems["Pop stash@{0}"]
        XCTAssertTrue(pop.waitForExistence(timeout: 10))
        pop.click()

        XCTAssertTrue(element("error-toast").waitForExistence(timeout: 30), "the failed pop is reported")
        XCTAssertEqual(try fixture.stashMessages().count, 2, "a failed pop keeps the stash")
        XCTAssertEqual(try readme(), editedBefore, "the local edit is left alone")
        XCTAssertFalse(fixture.gitDirContains("MERGE_HEAD"))
    }

    // MARK: Helpers

    /// README.md in the main checkout.
    private func readme() throws -> String {
        try String(contentsOfFile: (fixture.mainPath as NSString).appendingPathComponent("README.md"), encoding: .utf8)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
