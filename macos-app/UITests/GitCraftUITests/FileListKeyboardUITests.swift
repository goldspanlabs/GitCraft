import XCTest

/// Arrow keys in the file lists, after clicking a file.
final class FileListKeyboardUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testArrowKeysMoveThroughWorkingFilesAfterClickingOne() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true, unstagedFiles: ["README.md", "main.txt"]))
        let readme = app.element("unstaged-file:README.md")
        XCTAssertTrue(readme.waitForExistence(timeout: 60))
        // Start with the commit list focused, as after browsing history.
        app.staticTexts["main work"].firstMatch.click()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(readme.waitForExistence(timeout: 20))

        readme.staticTexts["README.md"].click()
        app.typeKey(.downArrow, modifierFlags: [])

        assertDiffHeader("main.txt")
        XCTAssertTrue(app.element("unstaged-file:main.txt").exists, "the working changes stay on screen")
        app.typeKey(.upArrow, modifierFlags: [])
        assertDiffHeader("README.md")

        // Staging the selected file keeps it selected, and the arrows keep working.
        app.element("unstaged-file:README.md").checkBoxes.firstMatch.click()
        XCTAssertTrue(app.element("staged-file:README.md").waitForExistence(timeout: 20))
        app.element("staged-file:README.md").staticTexts["README.md"].click()
        app.typeKey(.downArrow, modifierFlags: [])
        assertDiffHeader("main.txt")
    }

    func testArrowKeysMoveThroughACommitsFilesAfterClickingOne() throws {
        let fixture = try FixtureRepository.make()
        try "one\n".write(toFile: fixture.mainPath + "/one.txt", atomically: true, encoding: .utf8)
        try "two\n".write(toFile: fixture.mainPath + "/two.txt", atomically: true, encoding: .utf8)
        try fixture.git(["add", "one.txt", "two.txt"])
        try fixture.git(["commit", "-m", "two files"])
        try launch(fixture: fixture)
        app.staticTexts["two files"].firstMatch.click()
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "one.txt")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))

        first.click()
        app.typeKey(.downArrow, modifierFlags: [])

        assertDiffHeader("two.txt")
        XCTAssertTrue(first.exists, "the commit stays selected")
    }

    /// The diff header names the selected file.
    private func assertDiffHeader(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.element("diff-path").waitForExistence(timeout: 10)
                && wait(for: app.element("diff-path"), toSatisfy: "value == %@", argument: path, timeout: 10),
            "the diff shows \(path)",
            file: file, line: line
        )
    }

    private func launch(fixture: FixtureRepository) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }
}
