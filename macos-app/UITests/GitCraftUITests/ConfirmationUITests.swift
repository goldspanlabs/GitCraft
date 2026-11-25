import XCTest

/// End-to-end checks for the destructive confirmation dialog, through hard reset and discarding
/// a file. The dialog must change nothing when dismissed, and do exactly one thing when confirmed.
final class ConfirmationUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // main has "initial" and "main work"; README.md and main.txt both have unstaged edits.
        fixture = try FixtureRepository.make(twoBranches: true, unstagedFiles: ["README.md", "main.txt"])
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    // MARK: Hard reset

    func testHardResetCancelKeepsTheBranchAndTheChanges() throws {
        let mainBefore = try fixture.commitID("main")
        openHardResetConfirmation()

        let cancel = app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()

        XCTAssertTrue(wait(for: app.sheets.firstMatch, toSatisfy: "exists == false", timeout: 10))
        assertNothingChanged(since: mainBefore)
    }

    func testHardResetEscapeActsLikeCancel() throws {
        let mainBefore = try fixture.commitID("main")
        openHardResetConfirmation()

        XCTAssertTrue(app.sheets.buttons["Reset"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(wait(for: app.sheets.firstMatch, toSatisfy: "exists == false", timeout: 10))
        assertNothingChanged(since: mainBefore)
    }

    func testHardResetConfirmedOnceResetsOnceAndDoesNotAskAgain() throws {
        let initial = try fixture.commitID("main~1")
        openHardResetConfirmation()

        let reset = app.sheets.buttons["Reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
        reset.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.commitID("main")) == initial },
            "main is reset to the clicked commit"
        )
        XCTAssertFalse(try fixture.isModified("README.md"), "the hard reset discards uncommitted changes")
        // #12: confirming used to re-open the same dialog instead of finishing.
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3), "the dialog doesn't come back")
    }

    // MARK: Discard file changes

    func testDiscardChangesAsksFirstThenRevertsOnlyThatFile() throws {
        let file = app.staticTexts["README.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 60), "the edited file is listed")
        rightClick(file)
        let discard = app.menuItems["Discard Changes…"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.click()

        let confirm = app.sheets.buttons["Discard"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "discarding asks first")
        XCTAssertTrue(try fixture.isModified("README.md"), "nothing is discarded while the dialog is open")
        confirm.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.isModified("README.md")) == false },
            "README.md is reverted"
        )
        XCTAssertTrue(try fixture.isModified("main.txt"), "the other edited file is left alone")
    }

    // MARK: Helpers

    /// Right-clicks "initial" in the history and picks Reset 'main' to Here… → Hard.
    private func openHardResetConfirmation() {
        let row = app.staticTexts["initial"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the first commit is in the history")
        rightClick(row)
        let submenu = app.menuItems["Reset 'main' to Here…"]
        XCTAssertTrue(submenu.waitForExistence(timeout: 10))
        submenu.click()
        let hard = app.menuItems["Hard — discard uncommitted changes…"]
        XCTAssertTrue(hard.waitForExistence(timeout: 10))
        hard.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "hard reset asks first")
    }

    private func assertNothingChanged(since mainBefore: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            waitUntil(timeout: 3) { (try? self.fixture.commitID("main")) != mainBefore },
            "main stays where it was",
            file: file, line: line
        )
        XCTAssertEqual(try fixture.isModified("README.md"), true, "uncommitted changes are kept", file: file, line: line)
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
}
