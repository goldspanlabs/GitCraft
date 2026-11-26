import XCTest

/// Smoke tests for the File menu items and their sheets.
final class FileMenuUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try FixtureRepository.create()
        app = XCUIApplication()
        app.launchArguments = ["-UITestOpenRepository", fixture.repoURL.path]
        app.launch()
        XCTAssertTrue(app.staticTexts["LOCAL BRANCHES"].waitForExistence(timeout: 60))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testFileMenuItemsExistAndOpenSheets() {
        let fileMenu = app.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists)
        fileMenu.click()

        XCTAssertTrue(fileMenu.menuItems["New Window"].exists)
        XCTAssertTrue(fileMenu.menuItems["New Tab"].exists)
        XCTAssertTrue(fileMenu.menuItems["Restore Closed Tab"].exists)
        XCTAssertFalse(fileMenu.menuItems["Restore Closed Tab"].isEnabled)
        XCTAssertTrue(fileMenu.menuItems["Create New Local Repository…"].exists)
        XCTAssertTrue(fileMenu.menuItems["Clone…"].exists)
        XCTAssertTrue(fileMenu.menuItems["Open…"].exists)
        XCTAssertTrue(fileMenu.menuItems["Open Recent"].exists)
        XCTAssertTrue(fileMenu.menuItems["Close Window"].exists)
        XCTAssertTrue(fileMenu.menuItems["Close Tab"].exists)

        fileMenu.menuItems["Create New Local Repository…"].click()
        XCTAssertTrue(app.staticTexts["Create New Local Repository"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].click()

        fileMenu.click()
        fileMenu.menuItems["Clone…"].click()
        XCTAssertTrue(app.staticTexts["Clone Repository"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].click()
    }
}
