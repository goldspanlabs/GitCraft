import XCTest

/// End-to-end checks for the missing-Git, old-Git and Command Line Tools prompts on the Welcome screen.
final class GitAvailabilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testMissingGitShowsInstallAndDownloadActions() throws {
        try launch(availability: "missing")

        XCTAssertTrue(app.staticTexts["Git Is Required to Use GitCraft"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Install Command Line Tools…"].exists)
        XCTAssertTrue(app.buttons["Download Git…"].exists)
        XCTAssertTrue(app.buttons["Check Again"].exists)
        XCTAssertFalse(app.buttons["Open Repository…"].exists)
    }

    func testNeedsCommandLineToolsShowsCLTCardWithoutDownloadButton() throws {
        try launch(availability: "needsCommandLineTools")

        XCTAssertTrue(app.staticTexts["Xcode Command Line Tools Required"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Install Command Line Tools…"].exists)
        XCTAssertTrue(app.buttons["Check Again"].exists)
        XCTAssertFalse(app.buttons["Download Git…"].exists)
        XCTAssertFalse(app.buttons["Open Repository…"].exists)
    }

    func testOutdatedGitAsksForAnUpdateAndBlocksOpening() throws {
        try launch(availability: "outdated")

        XCTAssertTrue(app.staticTexts["Git Needs an Update"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Check Again"].exists)
        XCTAssertFalse(app.buttons["Install Command Line Tools…"].exists)
        XCTAssertFalse(app.buttons["Download Git…"].exists)
        XCTAssertFalse(app.buttons["Open Repository…"].exists)
    }

    private func launch(availability: String) throws {
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestGitAvailability", availability]
        app.launch()
    }
}
