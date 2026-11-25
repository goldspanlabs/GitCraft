import XCTest

/// End-to-end checks that the Commit button stays disabled when committing would make an empty
/// message or an empty commit.
final class CommitGatingUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testCommitIsDisabledWithAWhitespaceOnlySummary() throws {
        try launch(fixture: FixtureRepository.make(stagedChange: true))
        let headBefore = try fixture.commitID("HEAD")

        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        summary.click()
        summary.typeText("   ")

        let commit = app.buttons["commit-button"]
        XCTAssertTrue(commit.waitForExistence(timeout: 20))
        XCTAssertFalse(
            wait(for: commit, toSatisfy: "isEnabled == true", timeout: 3),
            "a summary of only spaces doesn't count"
        )

        // Command-Return is the button's shortcut; it must be inert too.
        summary.typeKey(.return, modifierFlags: .command)
        XCTAssertFalse(
            waitUntil(timeout: 3) { (try? self.fixture.commitID("HEAD")) != headBefore },
            "nothing is committed"
        )

        // A real summary enables it, which shows the check above isn't just a slow load.
        summary.typeText("Real summary")
        XCTAssertTrue(wait(for: commit, toSatisfy: "isEnabled == true", timeout: 20))
    }

    func testCommitIsDisabledWhenNothingIsStagedAndAutoStageIsOff() throws {
        // README.md has an unstaged edit, and nothing is staged.
        try launch(
            fixture: FixtureRepository.make(unstagedFiles: ["README.md"]),
            extraArguments: ["-autoStageOnCommit", "NO"]
        )
        let headBefore = try fixture.commitID("HEAD")

        XCTAssertTrue(element("unstaged-file:README.md").waitForExistence(timeout: 60))
        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        summary.click()
        summary.typeText("Nothing staged")

        let commit = app.buttons["commit-button"]
        XCTAssertTrue(commit.waitForExistence(timeout: 20))
        XCTAssertFalse(
            wait(for: commit, toSatisfy: "isEnabled == true", timeout: 3),
            "with auto-staging off, an unstaged edit isn't something to commit"
        )
        summary.typeKey(.return, modifierFlags: .command)
        XCTAssertFalse(
            waitUntil(timeout: 3) { (try? self.fixture.commitID("HEAD")) != headBefore },
            "nothing is committed"
        )
    }

    // MARK: Helpers

    private func launch(fixture: FixtureRepository, extraArguments: [String] = []) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath] + extraArguments
        app.launch()
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
