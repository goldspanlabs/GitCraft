import XCTest

/// End-to-end checks for the main repository window. Each test opens a throwaway repository
/// through the `-UITestOpenRepository` launch argument and drives the built GitCraft.app.
final class RepositoryUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testSidebarShowsBranchesAndSections() throws {
        try launch(stagedChange: false)

        XCTAssertTrue(app.staticTexts["LOCAL BRANCHES"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["REMOTES"].exists)
        XCTAssertTrue(app.staticTexts["TAGS"].exists)
        XCTAssertTrue(app.staticTexts["STASHES"].exists)
        XCTAssertTrue(app.staticTexts["main"].exists, "the checked-out branch is listed")
    }

    func testCommitComposerCommitsStagedChange() throws {
        try launch(stagedChange: true)

        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60), "the commit composer appears with staged changes")
        summary.click()
        summary.typeText("Add UI test change")

        let commit = app.buttons["commit-button"]
        XCTAssertTrue(commit.waitForExistence(timeout: 20))
        XCTAssertTrue(
            wait(for: commit, toSatisfy: "isEnabled == true", timeout: 20),
            "Commit is enabled once there is a summary and a staged change"
        )
        commit.click()

        XCTAssertTrue(
            app.staticTexts["Add UI test change"].waitForExistence(timeout: 30),
            "the new commit appears in the history list"
        )
    }

    /// Creates the fixture and launches the app on it.
    private func launch(stagedChange: Bool) throws {
        fixture = try FixtureRepository.make(stagedChange: stagedChange)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launch()
    }

    private func wait(for element: XCUIElement, toSatisfy predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
