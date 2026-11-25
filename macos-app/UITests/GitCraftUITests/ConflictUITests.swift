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
        // Both branches rewrite README.md's only line; git stops partway on the conflict.
        let conflict: FixtureRepository.Conflict
        if name.contains("CherryPick") {
            conflict = .cherryPick
        } else if name.contains("Revert") {
            conflict = .revert
        } else if name.contains("Rebase") {
            conflict = .rebase
        } else {
            conflict = .merge
        }
        fixture = try FixtureRepository.make(conflict: conflict)
        // A stopped merge, rebase, cherry-pick or revert leaves refs/heads/main where it was.
        mainBefore = try fixture.commitID("refs/heads/main")
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
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

    func testAStoppedCherryPickShowsItsOwnBannerAndAbortRestoresTheBranch() throws {
        XCTAssertTrue(
            text(containing: "Cherry-pick stopped on conflicts").waitForExistence(timeout: 60),
            "the banner names the cherry-pick, not a merge"
        )
        XCTAssertFalse(app.buttons["Abort Merge…"].exists, "it doesn't offer a merge abort that would fail")
        let abort = app.buttons["Abort Cherry Pick…"].firstMatch
        XCTAssertTrue(abort.exists)
        abort.click()

        let confirm = app.sheets.buttons["Abort Cherry Pick"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "aborting asks first")
        XCTAssertTrue(fixture.gitDirContains("CHERRY_PICK_HEAD"), "nothing is aborted while the dialog is open")
        confirm.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.fixture.gitDirContains("CHERRY_PICK_HEAD") },
            "the cherry-pick is aborted"
        )
        XCTAssertEqual(try fixture.commitID("HEAD"), mainBefore, "main is back where it was")
        XCTAssertFalse(try fixture.isModified("README.md"), "no conflicted changes are left")
        XCTAssertTrue(
            wait(for: text(containing: "Cherry-pick stopped"), toSatisfy: "exists == false", timeout: 20),
            "the banner goes away"
        )
    }

    func testAStoppedRevertShowsItsOwnBannerAndAbortRestoresTheBranch() throws {
        XCTAssertTrue(
            text(containing: "Revert stopped on conflicts").waitForExistence(timeout: 60),
            "the banner names the revert, not a merge"
        )
        XCTAssertFalse(app.buttons["Abort Merge…"].exists)
        let abort = app.buttons["Abort Revert…"].firstMatch
        XCTAssertTrue(abort.exists)
        abort.click()

        let confirm = app.sheets.buttons["Abort Revert"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "aborting asks first")
        XCTAssertTrue(fixture.gitDirContains("REVERT_HEAD"), "nothing is aborted while the dialog is open")
        confirm.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.fixture.gitDirContains("REVERT_HEAD") },
            "the revert is aborted"
        )
        XCTAssertEqual(try fixture.commitID("HEAD"), mainBefore, "main is back where it was")
        XCTAssertFalse(try fixture.isModified("README.md"), "no conflicted changes are left")
        XCTAssertTrue(
            wait(for: text(containing: "Revert stopped"), toSatisfy: "exists == false", timeout: 20),
            "the banner goes away"
        )
    }

    func testAConflictedFileIsListedAndMarkedAsConflicted() throws {
        let row = element("unstaged-file:README.md")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the conflicted file is listed")
        XCTAssertTrue(row.staticTexts["U"].exists, "its badge marks it unmerged, not as an ordinary edit")
        XCTAssertTrue(text(containing: "with conflicts").exists, "the banner says there are conflicts")
    }

    func testResolvingStagingAndContinuingFinishesTheRebase() throws {
        let featureCommit = try fixture.commitID(FixtureRepository.featureBranch)
        XCTAssertTrue(text(containing: "Rebase stopped on conflicts").waitForExistence(timeout: 60))
        let continueButton = app.buttons["Continue Rebase"].firstMatch
        XCTAssertTrue(continueButton.exists)
        XCTAssertFalse(continueButton.isEnabled, "Continue is disabled while conflicts remain")

        // Resolve README.md by hand, then stage it from the changes list.
        let readme = (fixture.mainPath as NSString).appendingPathComponent("README.md")
        try "resolved\n".write(toFile: readme, atomically: true, encoding: .utf8)
        let row = element("unstaged-file:README.md")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.checkBoxes.firstMatch.click()

        XCTAssertTrue(
            wait(for: continueButton, toSatisfy: "isEnabled == true", timeout: 30),
            "Continue enables once the resolution is staged"
        )
        continueButton.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.fixture.gitDirContains("rebase-merge") },
            "the rebase finishes"
        )
        XCTAssertEqual(
            try fixture.git(["symbolic-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "refs/heads/main"
        )
        XCTAssertEqual(try fixture.parents(of: "main"), [featureCommit], "main's commit is replayed onto feature")
        XCTAssertEqual(try fixture.git(["show", "main:README.md"]), "resolved\n", "the resolution is committed")
        XCTAssertTrue(
            wait(for: continueButton, toSatisfy: "exists == false", timeout: 20),
            "the banner goes away (its text changes once the conflict is staged, so check its button)"
        )
    }

    // MARK: Helpers

    /// Text anywhere in the app whose value or label contains `fragment`.
    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", fragment, fragment))
            .firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
