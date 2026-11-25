import XCTest

/// End-to-end checks for deleting local branches from the sidebar.
final class BranchDeleteUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // `feature` has a commit main doesn't; `old-work` points at "initial", already in main.
        fixture = try FixtureRepository.make(twoBranches: true, mergedBranch: true)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = [
            "-UITestOpenRepository", fixture.mainPath,
            // Branch rows only exist while LOCAL BRANCHES is open, a persisted user preference.
            "-sidebar.localBranchesExpanded", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testDeletingAMergedBranchAsksOnceAndRemovesIt() throws {
        let name = FixtureRepository.mergedBranchName
        let row = element("branch-row:\(name)")
        openDeleteConfirmation(for: row)

        let delete = app.sheets.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "deleting asks first")
        XCTAssertTrue(try fixture.hasBranch(name), "nothing is deleted while the dialog is open")
        delete.click()

        XCTAssertTrue(wait(for: row, toSatisfy: "exists == false", timeout: 30), "the row disappears")
        XCTAssertFalse(try fixture.hasBranch(name))
        XCTAssertFalse(app.sheets.firstMatch.exists, "a merged branch needs no second warning")
    }

    func testDeletingAnUnmergedBranchWarnsAndCancelKeepsIt() throws {
        let name = FixtureRepository.featureBranch
        let row = element("branch-row:\(name)")
        openDeleteConfirmation(for: row)

        let delete = app.sheets.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.click()

        // git refuses the safe delete, so the app warns that commits would be lost.
        let forceDelete = app.sheets.buttons["Force Delete"]
        XCTAssertTrue(forceDelete.waitForExistence(timeout: 30), "an unmerged branch gets a second, stronger warning")
        XCTAssertTrue(try fixture.hasBranch(name), "nothing is deleted before the warning is answered")

        let cancel = app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()

        XCTAssertTrue(wait(for: forceDelete, toSatisfy: "exists == false", timeout: 10))
        XCTAssertTrue(row.exists, "the branch stays in the sidebar")
        XCTAssertTrue(try fixture.hasBranch(name), "the branch and its commit are kept")
    }

    func testTheCheckedOutBranchHasNoDeleteItem() throws {
        let row = element("branch-row:main")
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        rightClick(row)

        // Wait for the menu to be up before checking what is missing from it.
        XCTAssertTrue(app.menuItems["New Branch…"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.menuItems["Delete…"].exists, "the checked-out branch can't be deleted")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: Helpers

    private func openDeleteConfirmation(for row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the branch is in the sidebar")
        rightClick(row)
        let delete = app.menuItems["Delete…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.click()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
