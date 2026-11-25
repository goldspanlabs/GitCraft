import XCTest

/// End-to-end checks for rebasing from the history and merging from the sidebar. Both now ask
/// before they change anything (#16): Rebase to Here goes through a confirmation, and the
/// sidebar's Merge item opens the Merge sheet instead of merging straight away.
final class MergeRebaseUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // `main` and `feature` each have one commit on top of "initial", in different files.
        fixture = try FixtureRepository.make(twoBranches: true)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    // MARK: Rebase to Here

    func testRebaseToHereAsksFirstAndCancelLeavesTheBranchAlone() throws {
        let mainBefore = try fixture.commitID("main")
        let featureCommit = try fixture.commitID(FixtureRepository.featureBranch)

        openRebaseConfirmation()

        // The dialog names the branch and the commit it will rebase onto.
        let title = sheetText(containing: "onto \(featureCommit.prefix(7))")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the confirmation names the target commit")
        XCTAssertFalse(
            waitUntil(timeout: 3) { (try? self.fixture.commitID("main")) != mainBefore },
            "nothing is rebased while the confirmation is open"
        )

        let cancel = app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()

        XCTAssertTrue(wait(for: title, toSatisfy: "exists == false", timeout: 10))
        XCTAssertFalse(
            waitUntil(timeout: 3) { (try? self.fixture.commitID("main")) != mainBefore },
            "Cancel leaves main where it was"
        )
        XCTAssertFalse(fixture.isAncestor(featureCommit, of: "main"))
    }

    func testRebaseToHereRebasesOnceConfirmed() throws {
        let featureCommit = try fixture.commitID(FixtureRepository.featureBranch)

        openRebaseConfirmation()

        let rebase = app.sheets.buttons["Rebase"]
        XCTAssertTrue(rebase.waitForExistence(timeout: 10))
        rebase.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { self.fixture.isAncestor(featureCommit, of: "main") },
            "main is rebased on top of the feature commit"
        )
        XCTAssertTrue(
            app.staticTexts["main work"].waitForExistence(timeout: 20),
            "the rebased commit is still in the history"
        )
    }

    // MARK: Merge from the sidebar

    func testSidebarMergeOpensTheMergeSheetAndCancelMergesNothing() throws {
        let mainBefore = try fixture.commitID("main")

        openSidebarMergeSheet()

        XCTAssertTrue(
            sheetText(containing: "without conflicts").waitForExistence(timeout: 30),
            "the sheet runs its conflict check before anything is merged"
        )
        XCTAssertEqual(try fixture.commitID("main"), mainBefore, "opening the sheet merges nothing")

        let cancel = app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()

        XCTAssertTrue(wait(for: app.sheets.firstMatch, toSatisfy: "exists == false", timeout: 10))
        XCTAssertFalse(
            waitUntil(timeout: 3) { (try? self.fixture.commitID("main")) != mainBefore },
            "Cancel leaves main where it was"
        )
    }

    func testSidebarMergeMergesTheBranchOnceConfirmed() throws {
        let featureCommit = try fixture.commitID(FixtureRepository.featureBranch)

        openSidebarMergeSheet()

        let merge = app.sheets.buttons["Merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: merge, toSatisfy: "isEnabled == true", timeout: 30))
        merge.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { self.fixture.isAncestor(featureCommit, of: "main") },
            "feature is merged into main"
        )
        // The branches diverged, so the default merge type makes a merge commit with two parents.
        let parents = try fixture.git(["rev-list", "--parents", "-n", "1", "main"])
            .split(separator: " ")
        XCTAssertEqual(parents.count, 3, "main's tip is a merge commit")
    }

    // MARK: Helpers

    /// Right-clicks the feature commit in the history and picks Rebase 'main' to Here….
    private func openRebaseConfirmation() {
        let row = app.staticTexts["feature work"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the feature commit is in the history")
        rightClick(row)
        let item = app.menuItems["Rebase 'main' to Here…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()
    }

    /// Right-clicks the feature branch in the sidebar and picks Merge into 'main'….
    private func openSidebarMergeSheet() {
        let row = element("branch-row:\(FixtureRepository.featureBranch)")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the feature branch is in the sidebar")
        rightClick(row)
        let item = app.menuItems["Merge into 'main'…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "the Merge sheet opens")
        XCTAssertTrue(app.sheets.buttons["Merge"].waitForExistence(timeout: 10))
    }

    /// Text in the frontmost sheet whose value or label contains `fragment`.
    private func sheetText(containing fragment: String) -> XCUIElement {
        app.sheets.staticTexts
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
