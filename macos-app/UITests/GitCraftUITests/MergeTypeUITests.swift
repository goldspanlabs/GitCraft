import XCTest

/// End-to-end checks for the Merge sheet's merge types, its conflict check, and merges git
/// refuses or has nothing to do for. Each test merges `feature` (or another branch) into `main`
/// from the sidebar and then checks the result with git.
final class MergeTypeUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    // MARK: Merge types on a branch that can fast-forward

    func testDefaultMergeFastForwardsWhenItCan() throws {
        try launch(fixture: FixtureRepository.make(featureAhead: true))
        let featureCommit = try fixture.commitID(FixtureRepository.featureBranch)

        openMergeSheet()
        confirmMerge()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.commitID("main")) == featureCommit },
            "main fast-forwards to the feature commit, with no merge commit"
        )
    }

    func testNoFastForwardAlwaysMakesAMergeCommit() throws {
        try launch(fixture: FixtureRepository.make(featureAhead: true))
        let mainBefore = try fixture.commitID("main")
        let featureCommit = try fixture.commitID(FixtureRepository.featureBranch)

        openMergeSheet()
        chooseMergeType("No fast-forward (always create a merge commit)")
        confirmMerge()

        XCTAssertTrue(
            waitUntil(timeout: 30) { self.fixture.isAncestor(featureCommit, of: "main") },
            "feature is merged into main"
        )
        XCTAssertEqual(
            try fixture.parents(of: "main"),
            [mainBefore, featureCommit],
            "main's tip is a merge commit of the old main and feature, not a fast-forward"
        )
    }

    func testFastForwardOnlyFastForwardsWhenItCan() throws {
        try launch(fixture: FixtureRepository.make(featureAhead: true))
        let featureCommit = try fixture.commitID(FixtureRepository.featureBranch)

        openMergeSheet()
        chooseMergeType("Fast-forward only")
        confirmMerge()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.commitID("main")) == featureCommit },
            "main fast-forwards to the feature commit"
        )
    }

    // MARK: Merge types on diverged branches

    func testFastForwardOnlyOnDivergedBranchesShowsAnErrorAndMergesNothing() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true))
        let mainBefore = try fixture.commitID("main")

        openMergeSheet()
        chooseMergeType("Fast-forward only")
        confirmMerge()

        XCTAssertTrue(
            text(containing: "fast-forward", outsideSheets: true).waitForExistence(timeout: 30),
            "git's refusal is shown, rather than a silent merge commit"
        )
        XCTAssertEqual(try fixture.commitID("main"), mainBefore, "main stays where it was")
        XCTAssertFalse(fixture.gitDirContains("MERGE_HEAD"), "no merge is left in progress")
    }

    func testSquashStagesTheChangesWithoutCommitting() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true))
        let mainBefore = try fixture.commitID("main")

        openMergeSheet()
        chooseMergeType("Squash (stage the changes, don't commit)")
        XCTAssertTrue(
            text(containing: "Commit them yourself").waitForExistence(timeout: 10),
            "the sheet says squash leaves the commit to you"
        )
        confirmMerge()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.stagedFiles()) == ["feature.txt"] },
            "feature's change is staged"
        )
        XCTAssertEqual(try fixture.commitID("main"), mainBefore, "no commit is made")
        XCTAssertFalse(fixture.gitDirContains("MERGE_HEAD"), "a squash isn't a merge in progress")
        XCTAssertTrue(
            element("staged-file:feature.txt").waitForExistence(timeout: 20),
            "the staged change is listed, ready to commit"
        )
    }

    // MARK: Conflict check and nothing to merge

    func testTheMergeSheetWarnsWhenTheMergeWillConflict() throws {
        // Both branches rewrite README.md's only line, and nothing has been merged yet.
        try launch(fixture: FixtureRepository.make(conflict: .notStarted))
        let mainBefore = try fixture.commitID("main")

        openMergeSheet()

        XCTAssertTrue(
            text(containing: "will have conflicts").waitForExistence(timeout: 30),
            "the conflict check finishes and warns"
        )
        XCTAssertFalse(text(containing: "Checking for conflicts").exists, "the check isn't still spinning")
        XCTAssertEqual(try fixture.commitID("main"), mainBefore, "the check doesn't touch the branch")
        XCTAssertFalse(fixture.gitDirContains("MERGE_HEAD"), "the check doesn't start a merge")
        XCTAssertFalse(try fixture.isModified("README.md"), "the check doesn't touch the working tree")
    }

    func testMergingABranchThatIsAlreadyMergedSaysSoAndMakesNoCommit() throws {
        // `old-work` points at "initial", which main already contains.
        try launch(fixture: FixtureRepository.make(twoBranches: true, mergedBranch: true))
        let mainBefore = try fixture.commitID("main")

        openMergeSheet(branch: FixtureRepository.mergedBranchName)
        chooseMergeType("No fast-forward (always create a merge commit)")
        confirmMerge()

        XCTAssertTrue(
            text(containing: "nothing to merge", outsideSheets: true).waitForExistence(timeout: 30),
            "the app explains why nothing happened"
        )
        XCTAssertEqual(try fixture.commitID("main"), mainBefore, "no empty merge commit is made")
    }

    // MARK: Helpers

    private func launch(fixture: FixtureRepository) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = [
            "-UITestOpenRepository", fixture.mainPath,
            // Branch rows only exist while LOCAL BRANCHES is open, a persisted user preference.
            "-sidebar.localBranchesExpanded", "YES",
        ]
        app.launch()
    }

    /// Right-clicks `branch` in the sidebar and picks Merge into 'main'….
    private func openMergeSheet(branch: String = FixtureRepository.featureBranch) {
        let row = element("branch-row:\(branch)")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "\(branch) is in the sidebar")
        rightClick(row)
        let item = app.menuItems["Merge into 'main'…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()
        XCTAssertTrue(app.sheets.buttons["Merge"].waitForExistence(timeout: 10), "the Merge sheet opens")
    }

    /// Picks `title` from the sheet's Merge Type menu.
    private func chooseMergeType(_ title: String) {
        let picker = app.sheets.popUpButtons["merge-type"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        let option = app.menuItems[title]
        XCTAssertTrue(option.waitForExistence(timeout: 10), "the Merge Type menu offers \(title)")
        option.click()
        XCTAssertTrue(
            wait(for: picker, toSatisfy: "value == %@", argument: title, timeout: 10),
            "\(title) is selected"
        )
    }

    /// Clicks the sheet's Merge button once it is enabled, and waits for the sheet to close.
    private func confirmMerge() {
        let merge = app.sheets.buttons["Merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: merge, toSatisfy: "isEnabled == true", timeout: 30))
        merge.click()
        XCTAssertTrue(wait(for: app.sheets.firstMatch, toSatisfy: "exists == false", timeout: 10))
    }

    /// Text whose value or label contains `fragment`, in the sheet or, with `outsideSheets`,
    /// anywhere in the app. Errors show as a toast over the history once the sheet has closed.
    private func text(containing fragment: String, outsideSheets: Bool = false) -> XCUIElement {
        let scope = outsideSheets ? app.staticTexts : app.sheets.staticTexts
        return scope
            .matching(NSPredicate(
                format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", fragment, fragment
            ))
            .firstMatch
    }

    /// Right-clicks the centre of `element` by coordinate. Rows are containers that XCUITest can
    /// report as not hittable even when they are on screen.
    private func rightClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    }

    private func wait(
        for element: XCUIElement,
        toSatisfy predicate: String,
        argument: String? = nil,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: argument.map { NSPredicate(format: predicate, $0) } ?? NSPredicate(format: predicate),
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
