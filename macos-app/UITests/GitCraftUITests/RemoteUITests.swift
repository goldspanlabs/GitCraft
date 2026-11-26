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

    func testOriginFolderCanBeCollapsedAndExpanded() throws {
        try launch(fixture: FixtureRepository.make(twoBranches: true, bareRemote: true))
        let remoteFeature = element("branch-row:origin/\(FixtureRepository.featureBranch)")
        XCTAssertTrue(remoteFeature.waitForExistence(timeout: 60), "the remote branch is listed")

        let originFolder = app.staticTexts["origin"].firstMatch
        XCTAssertTrue(originFolder.exists)
        originFolder.click()

        XCTAssertTrue(
            wait(for: remoteFeature, toSatisfy: "exists == false", timeout: 10),
            "clicking origin collapses its remote branches"
        )

        originFolder.click()
        XCTAssertTrue(remoteFeature.waitForExistence(timeout: 10), "clicking origin again expands it")
    }

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
        // The fixture pushed main already, so the remote matches it before anything happens.
        let mainBefore = try fixture.commitID("main")

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
                guard let local = try? self.fixture.commitID("main"), local != mainBefore else { return false }
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
            app.images["Unpushed commits"].firstMatch.exists,
            "with the upstream gone, nothing is marked unpushed"
        )
    }

    // MARK: No remote

    func testPushAndPullWithNoRemoteExplainWhy() throws {
        try launch(fixture: FixtureRepository.make())
        XCTAssertTrue(app.staticTexts["initial"].waitForExistence(timeout: 60))
        let headBefore = try fixture.commitID("HEAD")

        let push = app.buttons["Push"].firstMatch
        XCTAssertTrue(push.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(for: push, toSatisfy: "isEnabled == true", timeout: 20))
        push.click()

        let toast = element("error-toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 30), "the push failure is explained, not silent")
        // The toast's text isn't exposed as the label of its first static text, so match on
        // the text itself, in either its label or its value.
        func toastMentions(_ phrases: [String]) -> Bool {
            let clauses = phrases.flatMap { ["label CONTAINS[c] '\($0)'", "value CONTAINS[c] '\($0)'"] }
            let match = toast.descendants(matching: .any).matching(
                NSPredicate(format: clauses.joined(separator: " OR "))
            )
            return match.firstMatch.exists
        }
        XCTAssertTrue(
            waitUntil(timeout: 30) { toastMentions(["origin"]) },
            "the push failure names the missing remote: \(toast.debugDescription)"
        )
        XCTAssertEqual(try fixture.git(["remote"]), "", "no remote is added behind the user's back")

        let pull = app.buttons["Pull"].firstMatch
        XCTAssertTrue(pull.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(for: pull, toSatisfy: "isEnabled == true", timeout: 20))
        pull.click()

        // The pull failure replaces the push one (starting an action clears the old error), and
        // git explains it differently: there is no branch to pull from.
        XCTAssertTrue(
            waitUntil(timeout: 30) { toastMentions(["tracking information"]) },
            "the pull failure is explained too: \(toast.debugDescription)"
        )
        XCTAssertEqual(try fixture.commitID("HEAD"), headBefore)
    }

    // MARK: Remote modal & context menus

    func testRemotesHeaderMenuAddsRemoteAndTestsConnection() throws {
        let fixture = try FixtureRepository.make(bareRemote: true)
        let remotePath = fixture.remotePath
        try fixture.git(["remote", "remove", "origin"])
        try launch(fixture: fixture)

        XCTAssertTrue(app.staticTexts["LOCAL BRANCHES"].waitForExistence(timeout: 60))
        let remotesHeader = app.staticTexts["REMOTES"]
        XCTAssertTrue(remotesHeader.waitForExistence(timeout: 10))
        rightClick(remotesHeader)

        let addItem = app.menuItems["Add Remote"]
        XCTAssertTrue(addItem.waitForExistence(timeout: 10))
        XCTAssertFalse(app.menuItems["Manage Remotes…"].exists)
        addItem.click()

        XCTAssertTrue(app.staticTexts["Add new remote repository reference"].waitForExistence(timeout: 10))
        let urlField = app.textFields["Git Repository URL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10))
        urlField.click()
        urlField.typeText(remotePath)

        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["Connection succeeded"].waitForExistence(timeout: 20))

        app.buttons["Add New Remote"].click()
        XCTAssertTrue(
            waitUntil(timeout: 20) { (try? fixture.git(["remote"]))?.contains("origin") == true },
            "adding via the modal records the remote"
        )
    }

    func testRemoteRowContextMenuItemsAndEditDeleteFlow() throws {
        let fixture = try FixtureRepository.make(twoBranches: true, bareRemote: true)
        try launch(fixture: fixture)

        let originFolder = app.staticTexts["origin"].firstMatch
        XCTAssertTrue(originFolder.waitForExistence(timeout: 60))
        rightClick(originFolder)

        XCTAssertTrue(app.menuItems["Fetch origin"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.menuItems["Edit origin"].exists)
        XCTAssertTrue(app.menuItems["Delete origin"].exists)
        XCTAssertTrue(app.menuItems["Fetch Origin Automatically"].exists)
        XCTAssertTrue(app.menuItems["Add New Remote"].exists)

        app.menuItems["Edit origin"].click()
        XCTAssertTrue(app.staticTexts["Edit URL of the remote repository"].waitForExistence(timeout: 10))
        let editButton = app.buttons["Edit"]
        XCTAssertTrue(editButton.exists)
        XCTAssertFalse(editButton.isEnabled, "Edit stays disabled until a field changes")
        app.buttons["Cancel"].click()

        rightClick(originFolder)
        app.menuItems["Delete origin"].click()
        let confirmRemove = app.sheets.buttons["Remove"]
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 10))
        confirmRemove.click()

        XCTAssertTrue(
            waitUntil(timeout: 20) { (try? fixture.git(["remote"])) == "" },
            "confirming Delete origin removes the remote"
        )
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

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
