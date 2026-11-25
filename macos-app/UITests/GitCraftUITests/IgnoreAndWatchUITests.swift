import XCTest

/// End-to-end checks for hiding an untracked file from the changes list, and for edits made
/// outside the app showing up without a manual refresh.
final class IgnoreAndWatchUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // notes.txt is untracked; nothing else has changed.
        fixture = try FixtureRepository.make(untrackedFile: true)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testAddToGitignoreHidesTheFileAndWritesGitignore() throws {
        try ignoreNotes(using: "Add to .gitignore")

        let gitignore = (fixture.mainPath as NSString).appendingPathComponent(".gitignore")
        XCTAssertTrue(
            waitUntil(timeout: 20) {
                ((try? String(contentsOfFile: gitignore, encoding: .utf8)) ?? "")
                    .split(separator: "\n").contains(Substring(self.rule))
            },
            ".gitignore lists /notes.txt"
        )
        XCTAssertFalse(try exclude().contains(rule), "the local exclude file is left alone")
        XCTAssertTrue(
            element("unstaged-file:.gitignore").waitForExistence(timeout: 20),
            "the new .gitignore shows as a change to commit"
        )
    }

    func testAddToExcludeHidesTheFileWithoutTouchingGitignore() throws {
        try ignoreNotes(using: "Add to .git/info/exclude (local only)")

        XCTAssertTrue(
            waitUntil(timeout: 20) {
                ((try? self.exclude()) ?? "").split(separator: "\n").contains(Substring(self.rule))
            },
            ".git/info/exclude lists notes.txt"
        )
        let gitignore = (fixture.mainPath as NSString).appendingPathComponent(".gitignore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitignore), "no .gitignore is written")
        XCTAssertTrue(app.staticTexts["Working tree clean"].waitForExistence(timeout: 20), "nothing is left to commit")
    }

    func testAnEditMadeOutsideTheAppAppearsWithoutARefresh() throws {
        XCTAssertTrue(element("unstaged-file:\(FixtureRepository.untrackedFileName)").waitForExistence(timeout: 60))
        XCTAssertFalse(element("unstaged-file:README.md").exists)

        let readme = (fixture.mainPath as NSString).appendingPathComponent("README.md")
        try "changed outside the app\n".write(toFile: readme, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            element("unstaged-file:README.md").waitForExistence(timeout: 30),
            "the file watcher picks up the edit"
        )
    }

    // MARK: Helpers

    /// Right-clicks notes.txt in the changes list, picks `item`, and waits for the row to go.
    private func ignoreNotes(using item: String) throws {
        let row = element("unstaged-file:\(FixtureRepository.untrackedFileName)")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the untracked file is listed")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let menuItem = app.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 10))
        menuItem.click()

        XCTAssertTrue(wait(for: row, toSatisfy: "exists == false", timeout: 20), "the file leaves the changes list")
        let status = try fixture.git(["status", "--porcelain", "--", FixtureRepository.untrackedFileName])
        XCTAssertEqual(status, "", "git ignores the file")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: (fixture.mainPath as NSString).appendingPathComponent(FixtureRepository.untrackedFileName)),
            "the file itself is kept"
        )
    }

    /// The rule the app writes: anchored to the repository root, so only this file matches.
    private let rule = "/\(FixtureRepository.untrackedFileName)"

    /// The contents of .git/info/exclude, or "" if git hasn't written one.
    private func exclude() throws -> String {
        let path = (fixture.mainPath as NSString).appendingPathComponent(".git/info/exclude")
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
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
