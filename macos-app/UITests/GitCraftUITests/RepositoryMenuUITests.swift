import XCTest

/// Smoke tests for the Repository menu items, sheets, and git actions.
final class RepositoryMenuUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testRepositoryMenuItemsExistAndOpenSheets() throws {
        try launch(stagedChange: false)

        let repoMenu = app.menuBarItems["Repository"]
        XCTAssertTrue(repoMenu.exists)
        repoMenu.click()

        XCTAssertTrue(repoMenu.menuItems["Commit"].exists)
        XCTAssertFalse(repoMenu.menuItems["Commit"].isEnabled)
        XCTAssertTrue(repoMenu.menuItems["Fetch"].exists)
        XCTAssertTrue(repoMenu.menuItems["Pull"].exists)
        XCTAssertTrue(repoMenu.menuItems["Push"].exists)
        XCTAssertTrue(repoMenu.menuItems["Save Stash…"].exists)
        XCTAssertFalse(repoMenu.menuItems["Save Stash…"].isEnabled)
        XCTAssertTrue(repoMenu.menuItems["Checkout Branch"].exists)
        XCTAssertTrue(repoMenu.menuItems["New Branch…"].exists)
        XCTAssertTrue(repoMenu.menuItems["New Tag…"].exists)
        XCTAssertTrue(repoMenu.menuItems["New Worktree…"].exists)

        repoMenu.menuItems["New Branch…"].click()
        XCTAssertTrue(app.staticTexts["Create Branch"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].click()

        repoMenu.click()
        repoMenu.menuItems["New Tag…"].click()
        XCTAssertTrue(app.staticTexts["Create Tag"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].click()

        repoMenu.click()
        repoMenu.menuItems["New Worktree…"].click()
        XCTAssertTrue(app.staticTexts["Create Worktree"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].click()
    }

    func testCreateTagFromRepositoryMenu() throws {
        try launch(stagedChange: false)

        let repoMenu = app.menuBarItems["Repository"]
        repoMenu.click()
        repoMenu.menuItems["New Tag…"].click()

        XCTAssertTrue(app.staticTexts["Create Tag"].waitForExistence(timeout: 10))
        let tagField = app.textFields["v1.0.0"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 10))
        tagField.click()
        tagField.typeText("v1.0.0")

        app.buttons["Create Tag"].click()
        XCTAssertTrue(
            app.staticTexts["v1.0.0"].waitForExistence(timeout: 20),
            "created tag appears in the sidebar"
        )
    }

    func testSaveStashAndCommitFromRepositoryMenu() throws {
        try launch(stagedChange: true)

        let repoMenu = app.menuBarItems["Repository"]
        repoMenu.click()
        let stashItem = repoMenu.menuItems["Save Stash…"]
        XCTAssertTrue(stashItem.isEnabled)
        stashItem.click()
        XCTAssertTrue(app.staticTexts["Stash Changes"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].click()

        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        summary.click()
        summary.typeText("Menu commit test")

        repoMenu.click()
        let commitItem = repoMenu.menuItems["Commit"]
        XCTAssertTrue(commitItem.isEnabled)
        commitItem.click()

        XCTAssertTrue(
            app.staticTexts["Menu commit test"].waitForExistence(timeout: 30),
            "committing via Repository -> Commit records the commit in the history"
        )
    }

    func testCheckoutBranchFromRepositoryMenu() throws {
        try launch(stagedChange: false, twoBranches: true)

        let repoMenu = app.menuBarItems["Repository"]
        repoMenu.click()
        let checkoutMenu = repoMenu.menuItems["Checkout Branch"]
        checkoutMenu.hover()

        let currentMain = checkoutMenu.menuItems["✓ main"]
        XCTAssertTrue(currentMain.waitForExistence(timeout: 10))
        XCTAssertFalse(currentMain.isEnabled)

        let featureItem = checkoutMenu.menuItems[FixtureRepository.featureBranch]
        XCTAssertTrue(featureItem.exists)
        XCTAssertTrue(featureItem.isEnabled)
        featureItem.click()

        XCTAssertTrue(
            app.staticTexts[FixtureRepository.featureBranch].waitForExistence(timeout: 20)
        )

        repoMenu.click()
        checkoutMenu.hover()
        let currentFeature = checkoutMenu.menuItems["✓ \(FixtureRepository.featureBranch)"]
        XCTAssertTrue(currentFeature.waitForExistence(timeout: 10))
        XCTAssertFalse(currentFeature.isEnabled)
    }

    private func launch(stagedChange: Bool, twoBranches: Bool = false) throws {
        fixture = try FixtureRepository.make(stagedChange: stagedChange, twoBranches: twoBranches)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launch()
        XCTAssertTrue(app.staticTexts["LOCAL BRANCHES"].waitForExistence(timeout: 60))
    }
}
