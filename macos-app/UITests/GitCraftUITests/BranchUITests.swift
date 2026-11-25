import XCTest

/// End-to-end checks for creating and checking out branches from the sidebar, and for how
/// branch names with slashes show there.
final class BranchUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    // MARK: New Branch

    func testNewBranchWithAnExistingNameIsRejectedAndLeavesThatBranchAlone() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true))
        let featureBefore = try fixture.commitID(FixtureRepository.featureBranch)

        createBranch(named: FixtureRepository.featureBranch)

        XCTAssertTrue(element("error-toast").waitForExistence(timeout: 30), "the clash is reported")
        XCTAssertEqual(
            try fixture.commitID(FixtureRepository.featureBranch),
            featureBefore,
            "the existing feature branch isn't moved to main"
        )
        XCTAssertEqual(
            try fixture.git(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "main"
        )
    }

    // MARK: Checkout

    func testCheckoutCarriesAnEditThatDoesNotClash() throws {
        // README.md is the same on both branches, so its edit can come along.
        try launch(fixture: FixtureRepository.make(twoBranches: true, unstagedFiles: ["README.md"]))
        XCTAssertTrue(element("unstaged-file:README.md").waitForExistence(timeout: 60))

        checkout(FixtureRepository.featureBranch)

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.currentBranch()) == FixtureRepository.featureBranch },
            "feature is checked out"
        )
        XCTAssertTrue(try fixture.isModified("README.md"), "the edit comes along")
        XCTAssertTrue(element("unstaged-file:README.md").waitForExistence(timeout: 20), "and is still listed")
    }

    func testCheckoutThatWouldOverwriteAnEditIsRefusedAndKeepsTheEdit() throws {
        // main.txt exists only on main, so checking out feature would delete its edit.
        try launch(fixture: FixtureRepository.make(twoBranches: true, unstagedFiles: ["main.txt"]))
        XCTAssertTrue(element("unstaged-file:main.txt").waitForExistence(timeout: 60))
        let mainTxt = (fixture.mainPath as NSString).appendingPathComponent("main.txt")
        let editBefore = try String(contentsOfFile: mainTxt, encoding: .utf8)

        checkout(FixtureRepository.featureBranch)

        XCTAssertTrue(element("error-toast").waitForExistence(timeout: 30), "the refusal is explained, not silent")
        XCTAssertEqual(try currentBranch(), "main", "main stays checked out")
        XCTAssertEqual(try String(contentsOfFile: mainTxt, encoding: .utf8), editBefore, "the edit is kept")
    }

    // MARK: Names with slashes

    func testBranchNamesWithSlashesNestUnderAFolder() throws {
        try launch(fixture: FixtureRepository.make(extraBranches: ["team/one", "team/two"]))

        let one = element("branch-row:team/one")
        XCTAssertTrue(one.waitForExistence(timeout: 60), "the nested branch is listed")
        XCTAssertTrue(element("branch-row:team/two").exists)
        XCTAssertTrue(one.staticTexts["one"].exists, "the row shows the name's last part")
        XCTAssertFalse(one.staticTexts["team/one"].exists, "not the full name")
        XCTAssertTrue(app.staticTexts["team"].firstMatch.exists, "a team folder holds them")
        XCTAssertTrue(element("branch-row:main").exists, "main stays at the top level")

        let teamFolder = app.staticTexts["team"].firstMatch
        teamFolder.click()
        XCTAssertTrue(wait(for: one, toSatisfy: "exists == false", timeout: 10), "clicking team collapses its branches")

        teamFolder.click()
        XCTAssertTrue(one.waitForExistence(timeout: 10), "clicking team again expands its branches")
    }

    // MARK: Helpers

    private func launch(fixture: FixtureRepository) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = [
            "-UITestOpenRepository", fixture.mainPath,
            "-sidebar.localBranchesExpanded", "YES",
        ]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    /// Opens New Branch… on main, types `name`, and confirms with checkout left as it is.
    private func createBranch(named name: String) {
        let main = element("branch-row:main")
        XCTAssertTrue(main.waitForExistence(timeout: 60))
        rightClick(main)
        let item = app.menuItems["New Branch…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()

        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the Create Branch sheet opens")
        field.click()
        field.typeText(name)

        let create = app.sheets.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Create'"))
            .firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: create, toSatisfy: "isEnabled == true", timeout: 10))
        create.click()
    }

    /// Right-clicks `branch` in the sidebar and picks Checkout.
    private func checkout(_ branch: String) {
        let row = element("branch-row:\(branch)")
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        rightClick(row)
        let item = app.menuItems["Checkout"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()
    }

    private func currentBranch() throws -> String {
        try fixture.git(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
