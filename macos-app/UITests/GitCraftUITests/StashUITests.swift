import XCTest

/// End-to-end checks for saving and dropping stashes from the sidebar's STASHES section.
final class StashUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The save test needs changes to stash; the drop test needs stashes to drop.
        fixture = name.contains("Save")
            ? try FixtureRepository.make(unstagedFiles: ["README.md"], untrackedFile: true)
            : try FixtureRepository.make(stashes: true)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = [
            "-UITestOpenRepository", fixture.mainPath,
            // STASHES starts collapsed; its expanded state is a persisted user preference.
            "-sidebar.stashesExpanded", "YES",
        ]
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
        XCTAssertEqual(includeUntracked.value as? Int, 1, "untracked files are included by default")
        let stash = app.sheets.buttons["Stash"]
        XCTAssertTrue(stash.waitForExistence(timeout: 10))
        stash.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.stashMessages().count) == 1 },
            "one stash is saved"
        )
        XCTAssertFalse(try fixture.isModified("README.md"), "the tracked edit is stashed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked), "the untracked file is stashed too")
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

    // MARK: Helpers

    /// Right-clicks the centre of `element` by coordinate. Rows and headers are containers that
    /// XCUITest can report as not hittable even when they are on screen.
    private func rightClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
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
