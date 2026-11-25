import XCTest

/// End-to-end checks against a remote: a bare repository on disk stands in for the server, so
/// nothing needs the network. Also checks what Push and Pull do when there is no remote.
final class RemoteUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    // MARK: Remote branches

    func testDeletingARemoteBranchKeepsTheLocalOne() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true, bareRemote: true))
        let featureBefore = try fixture.commitID(FixtureRepository.featureBranch)
        XCTAssertNotNil(fixture.remoteCommitID("refs/heads/\(FixtureRepository.featureBranch)"))

        let remoteRow = element("branch-row:origin/\(FixtureRepository.featureBranch)")
        XCTAssertTrue(remoteRow.waitForExistence(timeout: 60), "the remote branch is listed")
        rightClick(remoteRow)
        let item = app.menuItems["Delete 'origin/\(FixtureRepository.featureBranch)'…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()

        let confirm = app.sheets.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "deleting a remote branch asks first")
        XCTAssertNotNil(
            fixture.remoteCommitID("refs/heads/\(FixtureRepository.featureBranch)"),
            "nothing is deleted while the dialog is open"
        )
        confirm.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) {
                self.fixture.remoteCommitID("refs/heads/\(FixtureRepository.featureBranch)") == nil
            },
            "the branch is deleted on the remote"
        )
        XCTAssertEqual(
            try fixture.commitID(FixtureRepository.featureBranch),
            featureBefore,
            "the local branch is kept where it was"
        )
        XCTAssertTrue(wait(for: remoteRow, toSatisfy: "exists == false", timeout: 20), "the remote row goes away")
        XCTAssertTrue(element("branch-row:\(FixtureRepository.featureBranch)").exists, "the local row stays")
    }

    // MARK: Commit and Push

    func testCommitAndPushPushesTheNewCommit() throws {
        try launch(fixture: FixtureRepository.make(stagedChange: true, bareRemote: true))

        let summary = app.textFields["commit-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        summary.click()
        summary.typeText("Pushed commit")

        let menu = element("commit-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(for: menu, toSatisfy: "isEnabled == true", timeout: 20))
        menu.click()
        let commitAndPush = app.menuItems["Commit and Push"]
        XCTAssertTrue(commitAndPush.waitForExistence(timeout: 10))
        commitAndPush.click()

        XCTAssertTrue(
            waitUntil(timeout: 30) {
                guard let local = try? self.fixture.commitID("main") else { return false }
                return self.fixture.remoteCommitID("refs/heads/main") == local
            },
            "the remote's main is the new local commit"
        )
        XCTAssertEqual(
            try fixture.git(["log", "-1", "--format=%s", "main"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "Pushed commit"
        )
    }

    // MARK: Unpushed marker

    func testCommitsAheadOfTheirUpstreamAreMarkedUnpushed() throws {
        // A control for the next test: the marker shows when main really is ahead.
        let fixture = try FixtureRepository.make(bareRemote: true)
        try fixture.commitFile("ahead.txt", contents: "ahead\n", message: "ahead of origin")
        try launch(fixture: fixture)

        XCTAssertTrue(app.staticTexts["ahead of origin"].waitForExistence(timeout: 60))
        XCTAssertTrue(
            app.images["Unpushed commits"].firstMatch.waitForExistence(timeout: 20),
            "main's chip shows the unpushed marker"
        )
    }

    func testCommitsAreNotMarkedUnpushedAfterTheUpstreamBranchIsDeleted() throws {
        // feature tracks origin/feature, gets a commit of its own, and then the remote branch
        // is deleted, as after a squash merge on the server.
        let fixture = try FixtureRepository.make(twoBranches: true, bareRemote: true)
        try fixture.git(["switch", FixtureRepository.featureBranch])
        try fixture.commitFile("later.txt", contents: "later\n", message: "later feature work")
        try fixture.git(["push", "origin", "--delete", FixtureRepository.featureBranch])
        try launch(fixture: fixture)

        XCTAssertTrue(app.staticTexts["later feature work"].waitForExistence(timeout: 60))
        // Give the graph's ref chips time to draw before checking what they don't show.
        XCTAssertTrue(app.staticTexts["feature work"].waitForExistence(timeout: 20))
        XCTAssertFalse(
            app.images["Unpushed commits"].firstMatch.waitForExistence(timeout: 5),
            "with the upstream gone, nothing is marked unpushed"
        )
    }

    // MARK: No remote

    func testPushWithNoRemoteExplainsWhy() throws {
        try launch(fixture: FixtureRepository.make())
        XCTAssertTrue(app.staticTexts["initial"].waitForExistence(timeout: 60))

        let push = app.buttons["Push"].firstMatch
        XCTAssertTrue(push.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(for: push, toSatisfy: "isEnabled == true", timeout: 20))
        push.click()

        XCTAssertTrue(element("error-toast").waitForExistence(timeout: 30), "the failure is explained, not silent")
        XCTAssertEqual(try fixture.git(["remote"]), "", "no remote is added behind the user's back")
    }

    func testPullWithNoRemoteExplainsWhy() throws {
        try launch(fixture: FixtureRepository.make())
        XCTAssertTrue(app.staticTexts["initial"].waitForExistence(timeout: 60))
        let headBefore = try fixture.commitID("HEAD")

        let pull = app.buttons["Pull"].firstMatch
        XCTAssertTrue(pull.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(for: pull, toSatisfy: "isEnabled == true", timeout: 20))
        pull.click()

        XCTAssertTrue(element("error-toast").waitForExistence(timeout: 30), "the failure is explained, not silent")
        XCTAssertEqual(try fixture.commitID("HEAD"), headBefore)
    }

    // MARK: Helpers

    private func launch(fixture: FixtureRepository) throws {
        self.fixture = fixture
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        app.launchArguments = [
            "-UITestOpenRepository", fixture.mainPath,
            "-sidebar.localBranchesExpanded", "YES",
            "-sidebar.remotesExpanded", "YES",
        ]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    /// Right-clicks the centre of `element` by coordinate. Rows are containers that XCUITest can
    /// report as not hittable even when they are on screen.
    private func rightClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
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
