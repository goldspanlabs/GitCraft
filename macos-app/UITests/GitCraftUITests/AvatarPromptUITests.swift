import XCTest

/// End-to-end checks for the first-launch "Show author avatars?" alert. The alert is an NSAlert
/// run on the main queue after the first window is up, and it is skipped whenever a fixture
/// repository is opened, so these tests launch with no repository and no restored tabs.
///
/// The answer is stored in the app's own preferences domain, which outlives the test run. Each
/// test clears it before launching and puts the developer's own value back afterwards.
final class AvatarPromptUITests: XCTestCase {
    private var app: XCUIApplication!
    private var savedValue: String?

    private let bundleID = "com.goldspanlabs.gitcraft"
    private let key = "showAvatars"

    override func setUpWithError() throws {
        continueAfterFailure = false
        savedValue = try readStoredValue()
        try deleteStoredValue()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try deleteStoredValue()
        if let savedValue {
            try writeStoredValue(savedValue)
        }
    }

    // MARK: First launch

    func testFirstLaunchAsksAndShowAvatarsStoresYes() throws {
        try launchWithoutRepository()

        let alert = promptAlert
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "the first launch asks about avatars")
        XCTAssertTrue(alert.staticTexts["Show author avatars?"].exists, "the question is shown")
        alert.buttons["Show Avatars"].click()

        XCTAssertTrue(wait(for: alert, toSatisfy: "exists == false", timeout: 10), "the alert closes")
        XCTAssertEqual(try readStoredValue(), "1", "the answer is stored as on")
    }

    func testFirstLaunchDontShowStoresNo() throws {
        try launchWithoutRepository()

        let alert = promptAlert
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "the first launch asks about avatars")
        alert.buttons["Don't Show"].click()

        XCTAssertTrue(wait(for: alert, toSatisfy: "exists == false", timeout: 10), "the alert closes")
        XCTAssertEqual(try readStoredValue(), "0", "the answer is stored as off")
    }

    // MARK: Helpers

    private var promptAlert: XCUIElement {
        // NSAlert.runModal() shows as its own dialog, labelled "alert", not as a sheet. Its
        // question is a static text inside it, so match on that.
        app.dialogs.containing(NSPredicate(format: "value CONTAINS 'Show author avatars?'")).firstMatch
    }

    private func launchWithoutRepository() throws {
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        // No fixture repository and no restored tabs, so the first window is the welcome screen.
        app.launchArguments = ["-openRepositoryTabs", "()"]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    /// Runs `defaults` against the app's domain. Returns nil when it fails, which for `read`
    /// means the key isn't set.
    @discardableResult
    private func defaults(_ arguments: [String]) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stored answer as `defaults` prints it ("1" or "0"), or nil when the key is absent.
    private func readStoredValue() throws -> String? {
        try defaults(["read", bundleID, key])
    }

    private func deleteStoredValue() throws {
        try defaults(["delete", bundleID, key])
    }

    private func writeStoredValue(_ value: String) throws {
        try defaults(["write", bundleID, key, "-bool", value == "1" ? "YES" : "NO"])
    }
}
