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
        let unstagedReadme = element("unstaged-file:README.md")
        XCTAssertTrue(unstagedReadme.waitForExistence(timeout: 60))

        unstagedReadme.checkBoxes.firstMatch.click()

        XCTAssertTrue(element("staged-file:README.md").waitForExistence(timeout: 20), "README.md moves to the staged list")
        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.fixture.stagedFiles()) == ["README.md"] }, "only README.md is staged")
        XCTAssertTrue(element("unstaged-file:main.txt").exists, "the other edit stays unstaged")
        XCTAssertTrue(element("unstaged-file:\(FixtureRepository.untrackedFileName)").exists)

        element("staged-file:README.md").checkBoxes.firstMatch.click()

        XCTAssertTrue(element("unstaged-file:README.md").waitForExistence(timeout: 20), "README.md moves back")
        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.fixture.stagedFiles()) == [] }, "nothing is staged")
        XCTAssertTrue(try fixture.isModified("README.md"), "unstaging keeps the edit")
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
