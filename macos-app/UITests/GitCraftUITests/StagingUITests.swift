import XCTest

/// End-to-end checks for staging files in the changes list, and for amending the last commit.
final class StagingUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    // MARK: Staging

    func testStagingAndUnstagingOneFileMovesOnlyThatFile() throws {
        try launchWithMixedChanges()
        // main.txt is the first row, so it's on screen above the commit box.
        let unstagedMain = element("unstaged-file:main.txt")
        XCTAssertTrue(unstagedMain.waitForExistence(timeout: 60))

        unstagedMain.checkBoxes.firstMatch.click()

        XCTAssertTrue(element("staged-file:main.txt").waitForExistence(timeout: 20), "main.txt moves to the staged list")
        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.fixture.stagedFiles()) == ["main.txt"] }, "only main.txt is staged")
        XCTAssertTrue(element("unstaged-file:README.md").exists, "the other edit stays unstaged")
        XCTAssertTrue(element("unstaged-file:\(FixtureRepository.untrackedFileName)").exists)

        element("staged-file:main.txt").checkBoxes.firstMatch.click()

        XCTAssertTrue(element("unstaged-file:main.txt").waitForExistence(timeout: 20), "main.txt moves back")
        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.fixture.stagedFiles()) == [] }, "nothing is staged")
        XCTAssertTrue(try fixture.isModified("main.txt"), "unstaging keeps the edit")
    }

    func testStageAllIncludesUntrackedFilesAndUnstageAllPutsThemBack() throws {
        try launchWithMixedChanges()
        XCTAssertTrue(element("unstaged-file:\(FixtureRepository.untrackedFileName)").waitForExistence(timeout: 60))

        let stageAll = element("stage-all")
        XCTAssertTrue(stageAll.waitForExistence(timeout: 10))
        stageAll.click()

        let everything = ["README.md", "main.txt", FixtureRepository.untrackedFileName]
        XCTAssertTrue(
            waitUntil(timeout: 20) { (try? self.fixture.stagedFiles().sorted()) == everything.sorted() },
            "the edits and the untracked file are all staged"
        )
        XCTAssertTrue(element("staged-file:\(FixtureRepository.untrackedFileName)").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Working tree clean"].waitForExistence(timeout: 20), "nothing is left unstaged")

        let unstageAll = element("unstage-all")
        XCTAssertTrue(unstageAll.waitForExistence(timeout: 10))
        unstageAll.click()

        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.fixture.stagedFiles()) == [] }, "nothing is staged")
        XCTAssertTrue(
            element("unstaged-file:\(FixtureRepository.untrackedFileName)").waitForExistence(timeout: 20),
            "the untracked file is listed as untracked again"
        )
        let untrackedStatus = try fixture.git(["status", "--porcelain", "--", FixtureRepository.untrackedFileName])
        XCTAssertTrue(untrackedStatus.hasPrefix("??"), "the untracked file is untracked again, got \(untrackedStatus)")
    }

    func testAFolderCheckboxStagesItsNestedChangesWithoutOpeningOrClosingTheFolder() throws {
        let fixture = try FixtureRepository.make()
        let inside = ["src/deep/two.txt", "src/one.txt"]
        func write(_ text: String, to path: String) throws {
            try text.write(toFile: fixture.mainPath + "/" + path, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(
            atPath: fixture.mainPath + "/src/deep", withIntermediateDirectories: true
        )
        for path in inside { try write("committed\n", to: path) }
        try fixture.git(["add", "src"])
        try fixture.git(["commit", "-m", "add src"])
        for path in inside + ["README.md"] { try write("changed\n", to: path) }
        try launch(fixture: fixture)

        let stageFolder = app.checkBoxes["unstaged-folder:src"]
        XCTAssertTrue(stageFolder.waitForExistence(timeout: 60))
        let unstagedFile = element("unstaged-file:src/one.txt")
        XCTAssertTrue(unstagedFile.waitForExistence(timeout: 10), "folders start open")
        // Just right of the checkbox is the folder's icon and name, which close it.
        stageFolder.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 24, dy: 0))
            .click()
        XCTAssertTrue(unstagedFile.waitForNonExistence(timeout: 10), "the folder closes")

        stageFolder.click()

        XCTAssertTrue(
            waitUntil(timeout: 20) { (try? self.fixture.stagedFiles().sorted()) == inside },
            "everything in src is staged, and nothing else"
        )
        XCTAssertTrue(try fixture.isModified("README.md"), "the file outside keeps its edit")
        let stagedFile = element("staged-file:src/one.txt")
        XCTAssertTrue(stagedFile.waitForExistence(timeout: 20), "the staged folder is open")

        app.checkBoxes["staged-folder:src"].click()

        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.fixture.stagedFiles()) == [] }, "nothing is staged")
        XCTAssertTrue(stageFolder.waitForExistence(timeout: 20), "src moves back")
        XCTAssertFalse(unstagedFile.exists, "and is still closed")

        stageFolder.click()

        XCTAssertTrue(stagedFile.waitForExistence(timeout: 20), "unchecking didn't close the staged folder")
    }

    // MARK: Amend

    func testAmendReplacesTheLastCommitInsteadOfAddingOne() throws {
        // main has one commit, "initial", and README.md has a staged edit.
        try launch(fixture: FixtureRepository.make(stagedChange: true))
        let initial = try fixture.commitID("HEAD")

        let amend = app.checkBoxes["Amend"].firstMatch
        XCTAssertTrue(amend.waitForExistence(timeout: 60))
        amend.click()

        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(
            wait(for: summary, toSatisfy: "value == 'initial'", timeout: 20),
            "turning on Amend fills in the last commit's message"
        )
        // Replace the message, so the test can tell the amended commit from the old one.
        summary.click()
        summary.typeKey("a", modifierFlags: .command)
        summary.typeText("Amended commit")

        let commit = app.buttons["commit-button"]
        XCTAssertTrue(wait(for: commit, toSatisfy: "isEnabled == true", timeout: 20))
        commit.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.commitID("HEAD")) != initial },
            "HEAD moves to the amended commit"
        )
        XCTAssertEqual(
            try fixture.git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "1",
            "the history still has one commit"
        )
        XCTAssertEqual(
            try fixture.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "Amended commit"
        )
        XCTAssertEqual(try fixture.git(["show", "HEAD:README.md"]), "hello, staged\n", "the staged edit is in the amended commit")
        XCTAssertTrue(app.staticTexts["Amended commit"].waitForExistence(timeout: 20), "the history shows the new message")
        XCTAssertFalse(app.staticTexts["initial"].exists, "the old commit is gone from the history")
    }

    // MARK: Helpers

    /// main has "initial" and "main work"; README.md and main.txt have unstaged edits, and
    /// notes.txt is untracked. Nothing is staged.
    private func launchWithMixedChanges() throws {
        try launch(fixture: FixtureRepository.make(
            twoBranches: true,
            unstagedFiles: ["README.md", "main.txt"],
            untrackedFile: true
        ))
    }

    private func launch(fixture: FixtureRepository) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
