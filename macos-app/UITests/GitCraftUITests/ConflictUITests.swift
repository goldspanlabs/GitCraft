import XCTest

/// End-to-end checks for a repository opened while git is stopped on a conflict: the banner
/// shows, and aborting asks first and puts the branch back.
final class ConflictUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!
    /// Where main pointed before git started the merge or rebase.
    private var mainBefore: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Both branches rewrite README.md's only line; git stops mid-merge or mid-rebase.
        fixture = try FixtureRepository.make(conflict: name.contains("Rebase") ? .rebase : .merge)
        // A stopped merge or rebase leaves refs/heads/main where it was.
        mainBefore = try fixture.commitID("refs/heads/main")
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testOpeningAStoppedMergeShowsTheConflictBanner() throws {
        XCTAssertTrue(
            text(containing: "Merge in progress with conflicts").waitForExistence(timeout: 60),
            "the banner says the merge stopped on conflicts"
        )
        XCTAssertTrue(app.buttons["Abort Merge…"].firstMatch.exists, "the banner offers a way out")
    }

    func testAbortMergeAsksFirstThenRestoresTheBranch() throws {
        let abort = app.buttons["Abort Merge…"].firstMatch
        XCTAssertTrue(abort.waitForExistence(timeout: 60))
        abort.click()

        let confirm = app.sheets.buttons["Abort Merge"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "aborting asks first")
        XCTAssertTrue(fixture.gitDirContains("MERGE_HEAD"), "the merge is still in progress while the dialog is open")
        confirm.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.fixture.gitDirContains("MERGE_HEAD") },
            "the merge is aborted"
        )
        XCTAssertEqual(try fixture.commitID("HEAD"), mainBefore, "HEAD is back where it was")
        XCTAssertFalse(try fixture.isModified("README.md"), "no half-merged changes are left")
        XCTAssertTrue(
            wait(for: text(containing: "Merge in progress"), toSatisfy: "exists == false", timeout: 20),
            "the banner goes away"
        )
    }

    func testAbortRebaseAsksFirstThenRestoresTheBranch() throws {
        XCTAssertTrue(
            text(containing: "Rebase stopped on conflicts").waitForExistence(timeout: 60),
            "the banner says the rebase stopped on conflicts"
        )
        let abort = app.buttons["Abort Rebase…"].firstMatch
        XCTAssertTrue(abort.exists)
        abort.click()

        let confirm = app.sheets.buttons["Abort Rebase"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "aborting asks first")
        XCTAssertTrue(fixture.gitDirContains("rebase-merge"), "the rebase is still in progress while the dialog is open")
        confirm.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.fixture.gitDirContains("rebase-merge") },
            "the rebase is aborted"
        )
        XCTAssertEqual(
            try fixture.git(["symbolic-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "refs/heads/main",
            "main is checked out again"
        )
        XCTAssertEqual(try fixture.commitID("HEAD"), mainBefore, "main is back where it was")
        XCTAssertFalse(try fixture.isModified("README.md"), "no conflicted changes are left in the index or working tree")
        XCTAssertEqual(
            try String(contentsOfFile: (fixture.mainPath as NSString).appendingPathComponent("README.md"), encoding: .utf8),
            "main\n",
            "README.md is main's version again"
        )
        XCTAssertTrue(
            wait(for: text(containing: "Rebase stopped"), toSatisfy: "exists == false", timeout: 20),
            "the banner goes away"
        )
    }

    // MARK: Helpers

    /// Text anywhere in the app whose value or label contains `fragment`.
    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", fragment, fragment))
            .firstMatch
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
