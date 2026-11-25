import XCTest

/// End-to-end checks for repositories in states that assume less than usual: no commits yet,
/// or no branch checked out.
final class RepositoryStateUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testARepositoryWithNoCommitsOpensAndMakesTheFirstCommit() throws {
        // An unborn main with an untracked README.md; auto-staging (the default) stages it.
        try launch(
            fixture: FixtureRepository.make(noCommits: true),
            // Auto-staging is a persisted preference; force it on so the untracked file counts.
            extraArguments: ["-autoStageOnCommit", "YES"]
        )

        XCTAssertTrue(
            text(containing: "No commits yet").waitForExistence(timeout: 60),
            "the empty history explains how to start"
        )
        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        summary.click()
        summary.typeText("First commit")

        let commit = app.buttons["commit-button"]
        XCTAssertTrue(wait(for: commit, toSatisfy: "isEnabled == true", timeout: 20))
        commit.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) { (try? self.fixture.commitID("refs/heads/main")) != nil },
            "main is born"
        )
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "main"]).trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertTrue(
            try fixture.git(["ls-tree", "--name-only", "main"]).contains("README.md"),
            "the first commit holds the file"
        )
        XCTAssertTrue(app.staticTexts["First commit"].waitForExistence(timeout: 20), "the commit shows in the history")
    }

    func testDetachedHeadShowsTheHeadRowAndNoBranchActions() throws {
        // HEAD is detached at "initial", one commit behind main.
        try launch(
            fixture: FixtureRepository.make(twoBranches: true, detachedHead: true),
            extraArguments: ["-sidebar.localBranchesExpanded", "YES"]
        )

        XCTAssertTrue(app.staticTexts["DETACHED"].waitForExistence(timeout: 60), "the sidebar shows the detached HEAD")
        XCTAssertTrue(element("branch-row:main").exists, "main is still listed as a branch")

        // With no branch checked out, there is nothing to merge into, rebase or reset.
        let row = app.staticTexts["initial"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        rightClick(row)
        XCTAssertTrue(app.menuItems["Cherry Pick Commit"].waitForExistence(timeout: 10), "the commit menu is open")
        let branchActions = app.menuItems.matching(
            // Menu items expose their text as title, and on some OS versions as label too.
            NSPredicate(
                format: "title CONTAINS %@ OR title BEGINSWITH %@ OR label CONTAINS %@ OR label BEGINSWITH %@",
                "to Here", "Merge into", "to Here", "Merge into"
            )
        )
        XCTAssertEqual(branchActions.count, 0, "no merge, rebase or reset items while detached")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: Helpers

    private func launch(fixture: FixtureRepository, extraArguments: [String] = []) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath] + extraArguments
        app.launch()
    }

    /// Text anywhere in the app whose value or label contains `fragment`.
    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", fragment, fragment))
            .firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
