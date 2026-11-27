import XCTest

/// End-to-end checks for selecting several commits and squashing them. Which selections are
/// allowed, and what the squash does in git, is covered by the Rust core's `squash` tests.
final class SquashUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    private let names = ["squash-one", "squash-two", "squash-three"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testShiftClickSquashAndUndo() throws {
        try launch()
        let headBefore = try fixture.commitID("HEAD")

        row("squash-three").click()
        XCUIElement.perform(withKeyModifiers: .shift) { row("squash-one").click() }
        XCTAssertTrue(app.staticTexts["3 commits selected"].waitForExistence(timeout: 10))

        XCTAssertFalse(app.buttons["Squash…"].exists, "squash is offered only in the context menu")
        openSquashSheet(from: "squash-two")

        let summary = app.sheets.textFields["squash-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "the Squash sheet opens")
        XCTAssertEqual(summary.value as? String, "squash-one", "the oldest summary is offered")

        // Return in the description starts a new line instead of squashing.
        let description = app.sheets.textViews["squash-description"]
        description.click()
        description.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(summary.exists, "the sheet stays open")
        XCTAssertEqual(try fixture.commitID("HEAD"), headBefore)

        app.sheets.buttons["Squash"].click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.commitCount()) == 2 },
            "three commits became one on top of initial"
        )
        XCTAssertTrue(app.staticTexts["Squashed 3 commits on \"main\"."].waitForExistence(timeout: 10))
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(wait(for: undo, toSatisfy: "isEnabled == true", timeout: 20))
        undo.click()
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.commitID("HEAD")) == headBefore })
    }

    func testRefusedSelectionShowsTheReason() throws {
        try launch()

        row("squash-three").click()
        XCUIElement.perform(withKeyModifiers: .command) { row("squash-one").click() }

        XCTAssertTrue(app.staticTexts["Select consecutive commits"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Squash…"].exists)

        rightClick(row("squash-one"))
        let item = app.menuItems["Squash Commits (select consecutive commits)"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(app.menuItems["Copy 2 Commit SHAs"].exists)
    }

    // MARK: Helpers

    private func launch() throws {
        fixture = try FixtureRepository.make(extraCommits: names)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    /// Right-clicks `summary` inside the selection and picks Squash Commits…. The menu is
    /// built as it opens, so it is reopened until the squash check has answered.
    private func openSquashSheet(from summary: String) {
        let item = app.menuItems["Squash Commits…"]
        let offered = waitUntil(timeout: 30) {
            rightClick(row(summary))
            if item.waitForExistence(timeout: 2), item.isEnabled { return true }
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        XCTAssertTrue(offered, "Squash Commits… is offered")
        item.click()
    }

    /// The commit list's row text for `summary`.
    private func row(_ summary: String) -> XCUIElement {
        let text = app.tables.staticTexts[summary].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "\(summary) is listed")
        return text
    }

    private func commitCount() throws -> Int {
        let output = try fixture.git(["rev-list", "--count", "HEAD"])
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
