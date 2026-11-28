import XCTest

/// Uses actual mouse drags across AppKit history and SwiftUI sidebar, then checks Git on disk.
/// These require a macOS runner; resolver/core tests cover refusal rules independently.
final class DragDropUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    private func launch(branches: Bool = false, commits: [String] = [], dirty: Bool = false) throws {
        fixture = try FixtureRepository.make(twoBranches: branches, untrackedFile: dirty, extraCommits: commits)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath,
                               "-sidebar.localBranchesExpanded", "YES", "-sidebar.tagsExpanded", "YES",
                               "-createBranchCheckout", "NO"]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
        XCTAssertTrue(branch("main").waitForExistence(timeout: 60))
        XCTAssertTrue(row(branches ? "main work" : commits.last ?? "initial").waitForExistence(timeout: 60))
    }

    private func row(_ summary: String) -> XCUIElement { app.tables.staticTexts[summary].firstMatch }
    private func branch(_ name: String) -> XCUIElement { app.element("branch-row:\(name)") }
    private var workingCopy: XCUIElement {
        app.tables.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Working Changes", "Working Changes")).firstMatch
    }

    private func drag(_ source: XCUIElement, to destination: XCUIElement, option: Bool = false) {
        XCTAssertTrue(source.waitForExistence(timeout: 30))
        XCTAssertTrue(destination.waitForExistence(timeout: 30))
        // macOS mouse API: press(forDuration:) is for touch/Touch Bar interactions.
        XCUIElement.perform(withKeyModifiers: option ? .option : []) {
            source.click(forDuration: 0.5, thenDragTo: destination)
        }
    }

    private func confirm(_ label: String) {
        let button = app.sheets.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "\(label) confirmation opens")
        button.click()
    }

    private func undo(to oid: String) {
        let button = app.buttons["Undo"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        XCTAssertTrue(wait(for: button, toSatisfy: "isEnabled == true", timeout: 15))
        button.click()
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.commitID("HEAD")) == oid })
    }

    func testBranchMergeCancelConfirmAndUndo() throws {
        try launch(branches: true)
        let before = try fixture.commitID("main")
        let feature = try fixture.commitID("feature")
        drag(branch("feature"), to: branch("main"))
        XCTAssertTrue(app.sheets.staticTexts["Merge feature into main"].waitForExistence(timeout: 15))
        XCTAssertEqual(try fixture.commitID("main"), before)
        confirm("Cancel")
        XCTAssertEqual(try fixture.commitID("main"), before)
        drag(branch("feature"), to: branch("main"))
        confirm("Merge")
        XCTAssertTrue(waitUntil(timeout: 30) { self.fixture.isAncestor(feature, of: "main") })
        XCTAssertEqual(try fixture.commitID("feature"), feature)
        undo(to: before)
    }

    func testOptionBranchDropRebasesCurrentBranchOntoSource() throws {
        try launch(branches: true)
        let feature = try fixture.commitID("feature")
        drag(branch("feature"), to: branch("main"), option: true)
        XCTAssertTrue(app.sheets.staticTexts["Rebase main onto feature"].waitForExistence(timeout: 15))
        confirm("Rebase")
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.commitID("main^")) == feature })
        XCTAssertEqual(try fixture.commitID("feature"), feature)
        XCTAssertEqual(try fixture.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines), "main work")
    }

    func testRebaseIsDiscoverableWithoutModifier() throws {
        try launch(branches: true)
        let feature = try fixture.commitID("feature")
        drag(branch("feature"), to: branch("main"))
        let picker = app.sheets.popUpButtons["git-drop-operation"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.click()
        app.menuItems["Rebase"].click()
        confirm("Rebase")
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.commitID("main^")) == feature })
    }

    func testCommitToWorkingChangesCherryPicksAndCanUndo() throws {
        try launch(branches: true)
        let before = try fixture.commitID("main")
        drag(row("feature work"), to: workingCopy)
        XCTAssertTrue(app.sheets.buttons["Cherry-pick"].waitForExistence(timeout: 15))
        XCTAssertEqual(try fixture.commitID("main"), before)
        confirm("Cherry-pick")
        XCTAssertTrue(waitUntil(timeout: 30) {
            (try? self.fixture.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "feature work"
        })
        XCTAssertEqual(try fixture.commitID("main^"), before)
        undo(to: before)
    }

    func testCommitToHeadBranchCherryPickCancel() throws {
        try launch(branches: true)
        let before = try fixture.commitID("main")
        drag(row("feature work"), to: branch("main"))
        confirm("Cancel")
        XCTAssertEqual(try fixture.commitID("main"), before)
    }

    func testConsecutiveSquashAndUndo() throws {
        try launch(commits: ["one", "two"])
        let before = try fixture.commitID("HEAD")
        drag(row("two"), to: row("one"))
        let summary = app.sheets.textFields["squash-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        XCTAssertEqual(summary.value as? String, "one")
        XCTAssertEqual(try fixture.commitID("HEAD"), before)
        confirm("Squash")
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "2" })
        let message = try fixture.git(["log", "-1", "--format=%B"])
        XCTAssertTrue(message.contains("two"))
        undo(to: before)
    }

    func testOptionFixupKeepsTargetMessage() throws {
        try launch(commits: ["one", "two"])
        drag(row("two"), to: row("one"), option: true)
        let summary = app.sheets.textFields["squash-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        XCTAssertEqual(summary.value as? String, "one")
        confirm("Fixup")
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "2" })
        XCTAssertEqual(try fixture.git(["log", "-1", "--format=%B"]).trimmingCharacters(in: .whitespacesAndNewlines), "one")
    }

    func testMultiSelectionSquashUsesAllDraggedCommits() throws {
        try launch(commits: ["one", "two", "three"])
        row("three").click()
        XCUIElement.perform(withKeyModifiers: .shift) { row("two").click() }
        drag(row("three"), to: row("one"))
        confirm("Squash")
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "2" })
        let message = try fixture.git(["log", "-1", "--format=%B"])
        XCTAssertTrue(message.contains("two"))
        XCTAssertTrue(message.contains("three"))
    }

    func testGapDropExplainsRefusalAndLeavesHistoryAlone() throws {
        try launch(commits: ["one", "two", "three"])
        let before = try fixture.commitID("HEAD")
        drag(row("three"), to: row("one"))
        XCTAssertTrue(app.staticTexts["Select consecutive commits"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertEqual(try fixture.commitID("HEAD"), before)
    }

    func testCommitToBranchesCreatesAtDraggedCommit() throws {
        try launch(commits: ["one", "two"])
        let target = try fixture.commitID("HEAD~1")
        drag(row("one"), to: app.staticTexts["LOCAL BRANCHES"].firstMatch)
        let name = app.sheets.textFields["Enter Branch Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.click()
        name.typeText("from-drop")
        confirm("Create")
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.commitID("from-drop")) == target })
    }

    func testBranchToTagsCreatesAtDraggedBranch() throws {
        try launch(branches: true)
        let target = try fixture.commitID("feature")
        drag(branch("feature"), to: app.staticTexts["TAGS"].firstMatch)
        let name = app.sheets.textFields["v1.0.0"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.click()
        name.typeText("drop-tag")
        confirm("Create Tag")
        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.fixture.commitID("refs/tags/drop-tag")) == target })
    }

    func testDirtyIntegrationPreservesLocalChanges() throws {
        try launch(branches: true, dirty: true)
        let before = try fixture.commitID("main")
        let status = try fixture.git(["status", "--porcelain"])
        drag(branch("feature"), to: branch("main"))
        confirm("Merge")
        XCTAssertTrue(app.staticTexts["Commit or stash your changes first"].waitForExistence(timeout: 15))
        XCTAssertEqual(try fixture.commitID("main"), before)
        XCTAssertEqual(try fixture.git(["status", "--porcelain"]), status)
    }

    func testMovingHeadWhileConfirmationIsOpenRefusesTheDrop() throws {
        try launch(branches: true)
        drag(branch("feature"), to: branch("main"))
        XCTAssertTrue(app.sheets.buttons["Merge"].waitForExistence(timeout: 15))
        try fixture.git(["commit", "--allow-empty", "-m", "external change"])
        let moved = try fixture.commitID("HEAD")
        confirm("Merge")
        XCTAssertTrue(app.staticTexts["The branch changed. Start the drag again."].waitForExistence(timeout: 15))
        XCTAssertEqual(try fixture.commitID("HEAD"), moved)
    }
}
