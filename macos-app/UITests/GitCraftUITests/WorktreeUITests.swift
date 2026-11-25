import XCTest

/// End-to-end checks for the WORKTREES sidebar. Each test creates a throwaway repository with
/// a linked worktree, launches the built GitCraft.app on it, and drives the sidebar.
final class WorktreeUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The dirty-removal tests need uncommitted work in the linked checkout, the locked test
        // a locked one, and the from-branch test a local branch that no worktree has checked out.
        // That last test skips the linked worktree: git can't hold both `feature` and
        // `feature/ui` as branch names.
        let fromBranch = name.contains("FromABranchChecksOutThatBranch")
        let noLinkedWorktrees = fromBranch || name.contains("WithoutLinked")
        fixture = try FixtureRepository.make(
            linkedWorktree: !noLinkedWorktrees,
            dirtyLinkedWorktree: name.contains("Dirty"),
            lockedLinkedWorktree: name.contains("Locked"),
            detachedLinkedWorktree: name.contains("DetachedWorktreeRow"),
            twoBranches: fromBranch
        )
        if name.contains("SwitchingToADirtyWorktree") {
            // A commit only the linked checkout's branch has, so its history differs from main's.
            _ = try fixture.git(["-C", fixture.linkedPath, "commit", "--allow-empty", "-m", "Linked work"])
        }
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        // Force the WORKTREES section open: its expanded state is a persisted user preference.
        app.launchArguments = [
            "-UITestOpenRepository", fixture.mainPath,
            "-sidebar.worktreesExpanded", "YES",
            "-sidebar.localBranchesExpanded", "YES",
            // Make the sheet's confirm button always read "Create and Switch".
            "-createWorktreeSwitch", "YES",
        ]
        app.launchEnvironment = GitCraftApp.isolatedGitEnvironment
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
    }

    func testSidebarHidesMainCheckoutWithoutLinkedWorktrees() {
        XCTAssertTrue(app.staticTexts["No worktrees"].waitForExistence(timeout: 60))
        XCTAssertFalse(element("worktree-row:main").exists, "the sole primary checkout is not listed as a worktree")
    }

    func testSidebarListsMainAndLinkedWorktrees() {
        XCTAssertTrue(element("worktree-row:main").waitForExistence(timeout: 60))
        XCTAssertTrue(element("worktree-row:\(FixtureRepository.linkedBranch)").exists)
        XCTAssertTrue(element("worktree-current:main").exists, "the main checkout starts as current")
    }

    func testDoubleTapSwitchesToLinkedWorktree() {
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))

        // The row is a container, so XCUITest reports it as not hittable even though it is on
        // screen. Click its centre by coordinate; the row's double-tap gesture still receives it.
        linked.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        XCTAssertTrue(
            element("worktree-current:\(FixtureRepository.linkedBranch)").waitForExistence(timeout: 20),
            "double-tap should make the linked worktree current"
        )
        XCTAssertFalse(element("worktree-current:main").exists)
    }

    func testCreateWorktreeFromSectionMenuAddsAndSwitchesToIt() throws {
        XCTAssertTrue(element("worktree-row:main").waitForExistence(timeout: 60))

        rightClick(app.staticTexts["WORKTREES"])
        let newWorktree = app.menuItems["New Worktree…"]
        XCTAssertTrue(newWorktree.waitForExistence(timeout: 10))
        newWorktree.click()

        let branch = app.textFields["new-worktree-branch"]
        XCTAssertTrue(branch.waitForExistence(timeout: 20), "the Create Worktree sheet opens")
        branch.click()
        branch.typeText("feature-new")

        let create = app.buttons["Create and Switch"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: create, toSatisfy: "isEnabled == true", timeout: 10))
        create.click()

        XCTAssertTrue(element("worktree-row:feature-new").waitForExistence(timeout: 30))
        XCTAssertTrue(
            element("worktree-current:feature-new").waitForExistence(timeout: 20),
            "creating with the switch option on makes the new worktree current"
        )
        XCTAssertFalse(element("worktree-current:main").exists)
        let created = fixture.root.appendingPathComponent("repo-feature-new").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: created), "the checkout exists on disk")
    }

    func testRemoveWorktreeFromRowMenuDeletesTheCheckout() throws {
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedPath))

        rightClick(linked)
        let remove = app.menuItems["Remove Worktree…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.click()

        // Scope to the confirmation sheet: the TouchBar also exposes a "Remove" button.
        let confirm = app.sheets.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "removal asks for confirmation")
        confirm.click()

        XCTAssertTrue(
            wait(for: linked, toSatisfy: "exists == false", timeout: 30),
            "the row disappears once the worktree is removed"
        )
        XCTAssertTrue(app.staticTexts["No worktrees"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("worktree-row:main").exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkedPath), "the folder is deleted")
    }

    func testRemovingADirtyWorktreeAsksAgainAndCancelKeepsTheFiles() throws {
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedScratchPath))

        // First prompt: the ordinary confirmation. Git then refuses the unclean worktree.
        rightClick(linked)
        let remove = app.menuItems["Remove Worktree…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.click()
        let confirm = app.sheets.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.click()

        // Second prompt: it warns the uncommitted files will be permanently deleted.
        let warning = app.sheets.staticTexts
            .matching(NSPredicate(format: "value CONTAINS 'permanently deleted'"))
            .firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 30), "a dirty worktree asks for a second, stronger confirmation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedScratchPath), "nothing is deleted yet")

        // Cancelling leaves the worktree and the uncommitted file alone.
        let cancel = app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()
        XCTAssertTrue(wait(for: warning, toSatisfy: "exists == false", timeout: 10))
        XCTAssertTrue(linked.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedScratchPath))
    }

    func testRemovingADirtyWorktreeForceRemovesItAfterTheSecondConfirmation() throws {
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))

        rightClick(linked)
        let remove = app.menuItems["Remove Worktree…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.click()
        let firstConfirm = app.sheets.buttons["Remove"]
        XCTAssertTrue(firstConfirm.waitForExistence(timeout: 10))
        firstConfirm.click()

        let warning = app.sheets.staticTexts
            .matching(NSPredicate(format: "value CONTAINS 'permanently deleted'"))
            .firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 30))
        let secondConfirm = app.sheets.buttons["Force Remove"]
        XCTAssertTrue(secondConfirm.waitForExistence(timeout: 10))
        secondConfirm.click()

        XCTAssertTrue(
            wait(for: linked, toSatisfy: "exists == false", timeout: 30),
            "the row disappears once the forced removal finishes"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkedPath), "the folder and its uncommitted file are deleted")
        XCTAssertTrue(app.staticTexts["No worktrees"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("worktree-row:main").exists)
    }

    func testRemovingTheActiveWorktreeSwitchesTheTabToTheMainCheckout() throws {
        // #17: removing the checkout the tab is showing has to move the tab somewhere that exists.
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))
        linked.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        XCTAssertTrue(
            element("worktree-current:\(FixtureRepository.linkedBranch)").waitForExistence(timeout: 20),
            "the linked worktree is current before removing it"
        )

        // Menu items are disabled while the switch is still loading, and a menu doesn't update
        // once open, so reopen it until Remove is enabled.
        let remove = app.menuItems["Remove Worktree…"]
        var enabled = false
        let deadline = Date().addingTimeInterval(30)
        while !enabled && Date() < deadline {
            rightClick(linked)
            XCTAssertTrue(remove.waitForExistence(timeout: 10))
            enabled = remove.isEnabled
            if !enabled {
                app.typeKey(.escape, modifierFlags: [])
                _ = wait(for: remove, toSatisfy: "exists == false", timeout: 5)
            }
        }
        XCTAssertTrue(enabled, "the active worktree can be removed while the main checkout exists")
        remove.click()

        let warning = app.sheets.staticTexts
            .matching(NSPredicate(format: "value CONTAINS 'switch this tab to another checkout'"))
            .firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "the confirmation says the tab will switch")
        let confirm = app.sheets.buttons["Remove"]
        XCTAssertTrue(confirm.exists)
        confirm.click()

        XCTAssertTrue(
            wait(for: linked, toSatisfy: "exists == false", timeout: 30),
            "the row disappears once the worktree is removed"
        )
        XCTAssertTrue(
            wait(
                for: app.windows.firstMatch,
                toSatisfy: "NOT (title CONTAINS 'repo-ui') AND title CONTAINS 'repo'",
                timeout: 20
            ),
            "the tab moves to the main checkout"
        )
        XCTAssertTrue(app.staticTexts["No worktrees"].waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkedPath), "the folder is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mainPath), "the main checkout is untouched")
    }

    func testTheMainCheckoutHasNoRemoveItem() {
        let main = element("worktree-row:main")
        XCTAssertTrue(main.waitForExistence(timeout: 60))
        rightClick(main)
        XCTAssertTrue(app.menuItems["Copy Path"].waitForExistence(timeout: 10), "the worktree menu is open")
        XCTAssertFalse(app.menuItems["Remove Worktree…"].exists, "the main checkout can't be removed")
        XCTAssertFalse(app.menuItems["Lock Worktree"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testALockedWorktreeOffersUnlockAndCannotBeRemoved() {
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))
        rightClick(linked)
        XCTAssertTrue(app.menuItems["Unlock Worktree"].waitForExistence(timeout: 10), "a locked worktree offers Unlock")
        XCTAssertFalse(app.menuItems["Lock Worktree"].exists)
        let remove = app.menuItems["Remove Worktree…"]
        XCTAssertTrue(remove.exists)
        XCTAssertFalse(remove.isEnabled, "a locked worktree can't be removed until it is unlocked")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedPath))
    }

    func testNewWorktreeFromABranchChecksOutThatBranch() throws {
        // `feature` exists locally and no worktree has it checked out.
        let branch = element("branch-row:\(FixtureRepository.featureBranch)")
        XCTAssertTrue(branch.waitForExistence(timeout: 60))
        rightClick(branch)
        let item = app.menuItems["New Worktree from Branch…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()

        // The plain checkout sheet names the branch instead of offering a mode or a name field.
        XCTAssertTrue(app.staticTexts["Local branch:"].waitForExistence(timeout: 20), "the Create Worktree sheet opens")
        XCTAssertFalse(app.textFields["new-worktree-branch"].exists, "there is no new branch name to type")
        let create = app.buttons["Create and Switch"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: create, toSatisfy: "isEnabled == true", timeout: 10))
        create.click()

        let row = element("worktree-row:\(FixtureRepository.featureBranch)")
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(
            element("worktree-current:\(FixtureRepository.featureBranch)").waitForExistence(timeout: 20),
            "creating with the switch option on makes the new worktree current"
        )
        let created = fixture.root.appendingPathComponent("repo-\(FixtureRepository.featureBranch)").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: created), "the checkout exists on disk")
        XCTAssertEqual(
            try fixture.git(["-C", created, "symbolic-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "refs/heads/\(FixtureRepository.featureBranch)",
            "the new checkout has the existing branch, not a new one"
        )
        XCTAssertEqual(
            try fixture.git(["branch", "--list", "--format=%(refname:short)"])
                .split(separator: "\n").count,
            2,
            "no branch is created: there are still only main and feature"
        )
    }

    func testCancelOnTheFirstRemoveConfirmationKeepsTheWorktree() throws {
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))
        rightClick(linked)
        let remove = app.menuItems["Remove Worktree…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.click()

        let cancel = app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "removal asks first")
        cancel.click()

        XCTAssertTrue(wait(for: app.sheets.firstMatch, toSatisfy: "exists == false", timeout: 10))
        XCTAssertTrue(linked.exists, "the row stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedPath), "the folder stays")
        XCTAssertTrue(
            try fixture.git(["worktree", "list", "--porcelain"]).contains("/repo-ui\n"),
            "git still lists the worktree"
        )
    }

    func testNewWorktreeInDetachedModeChecksOutNoBranch() throws {
        let mainCommit = try fixture.commitID("main")
        XCTAssertTrue(element("worktree-row:main").waitForExistence(timeout: 60))
        rightClick(app.staticTexts["WORKTREES"])
        let newWorktree = app.menuItems["New Worktree…"]
        XCTAssertTrue(newWorktree.waitForExistence(timeout: 10))
        newWorktree.click()

        let detached = segment("Detached HEAD")
        XCTAssertTrue(detached.waitForExistence(timeout: 20), "the sheet offers Detached HEAD")
        detached.click()
        XCTAssertTrue(
            wait(for: app.textFields["new-worktree-branch"], toSatisfy: "exists == false", timeout: 10),
            "detached mode asks for no branch name"
        )
        let create = app.buttons["Create and Switch"]
        XCTAssertTrue(wait(for: create, toSatisfy: "isEnabled == true", timeout: 10))
        create.click()

        let label = "detached at \(mainCommit.prefix(7))"
        XCTAssertTrue(element("worktree-current:\(label)").waitForExistence(timeout: 30), "the detached worktree is current")
        let created = fixture.root.appendingPathComponent("repo-main").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: created), "the checkout exists on disk")
        XCTAssertEqual(
            try fixture.git(["-C", created, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "HEAD",
            "no branch is checked out there"
        )
        XCTAssertEqual(try fixture.commitID("main"), mainCommit)
        XCTAssertEqual(
            try fixture.git(["-C", created, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            mainCommit,
            "it starts at main's commit"
        )
    }

    func testNewWorktreeFromABranchCheckedOutElsewhereOnlyOffersANewBranch() throws {
        // feature/ui is checked out in the linked worktree, and git allows a branch in only one.
        let branch = element("branch-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(branch.waitForExistence(timeout: 60))
        rightClick(branch)
        let item = app.menuItems["New Worktree from Branch…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()

        XCTAssertTrue(app.textFields["new-worktree-branch"].waitForExistence(timeout: 20), "the sheet asks for a new branch name")
        XCTAssertFalse(app.staticTexts["Local branch:"].exists, "it doesn't offer to check the branch out again")
        XCTAssertFalse(segment("Existing Branch").exists, "Existing Branch isn't offered")
        app.sheets.buttons["Cancel"].click()
    }

    func testADetachedWorktreeRowShowsTheCommitItIsOn() throws {
        let head = String(try fixture.commitID("main").prefix(7))
        let row = element("worktree-row:detached at \(head)")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the detached worktree is listed")
        XCTAssertTrue(row.staticTexts["detached at \(head)"].exists, "its subtitle names the commit")
        XCTAssertTrue(row.staticTexts["repo-ui"].exists, "its title is the folder")
        let main = element("worktree-row:main")
        XCTAssertTrue(main.exists)
        XCTAssertFalse(
            main.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'detached' OR label BEGINSWITH 'detached'")).firstMatch.exists,
            "a row on a branch has no subtitle"
        )
    }

    func testABranchCheckedOutInAnotherWorktreeShowsTheFolderNote() throws {
        let linkedBranch = element("branch-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linkedBranch.waitForExistence(timeout: 60))
        XCTAssertTrue(
            linkedBranch.descendants(matching: .any)["Checked out in repo-ui"].waitForExistence(timeout: 20),
            "feature/ui's icon says where it is checked out"
        )
        XCTAssertFalse(
            element("branch-row:main").descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Checked out in'")).firstMatch.exists,
            "the branch of the checkout being viewed has no note"
        )
    }

    func testSwitchingToADirtyWorktreeShowsItsTitleHistoryAndChanges() throws {
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))
        XCTAssertFalse(element("unstaged-file:scratch.txt").exists, "the main checkout has no scratch.txt")
        // The history shows only the checked-out branch by default, so main's leaves this out.
        XCTAssertTrue(app.staticTexts["initial"].waitForExistence(timeout: 20), "main's history has loaded")
        XCTAssertFalse(app.staticTexts["Linked work"].exists, "main's history has no linked-only commit")

        // Switch from the row menu. Switching by double-click has its own test below.
        rightClick(linked)
        let switchItem = app.menuItems["Switch to Worktree"]
        XCTAssertTrue(switchItem.waitForExistence(timeout: 10))
        switchItem.click()

        XCTAssertTrue(element("worktree-current:\(FixtureRepository.linkedBranch)").waitForExistence(timeout: 20))
        XCTAssertTrue(
            element("unstaged-file:scratch.txt").waitForExistence(timeout: 20),
            "the changes list shows the linked checkout's untracked file"
        )
        XCTAssertTrue(
            wait(for: app.windows.firstMatch, toSatisfy: "title CONTAINS 'repo-ui'", timeout: 20),
            "the window title names the linked checkout"
        )
        XCTAssertTrue(
            app.staticTexts["Linked work"].waitForExistence(timeout: 20),
            "the history switches to the linked checkout's branch"
        )
    }

    func testDoubleClickingADirtyWorktreeShowsItsChangesNotItsHeadCommit() throws {
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["initial"].waitForExistence(timeout: 20), "main's history has loaded")

        // Each click of a double-click is also a single click, which selects the row's head
        // commit. The switch must still end on the linked checkout's Working Changes.
        linked.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        XCTAssertTrue(element("worktree-current:\(FixtureRepository.linkedBranch)").waitForExistence(timeout: 20))
        XCTAssertTrue(
            element("unstaged-file:scratch.txt").waitForExistence(timeout: 20),
            "the panel shows the linked checkout's changes, not its head commit"
        )
    }

    func testDeletingTheActiveWorktreeFolderOutsideTheAppMovesTheTab() throws {
        // #18: the tab must not stay on a folder that no longer exists.
        let linked = element("worktree-row:\(FixtureRepository.linkedBranch)")
        XCTAssertTrue(linked.waitForExistence(timeout: 60))
        linked.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        XCTAssertTrue(element("worktree-current:\(FixtureRepository.linkedBranch)").waitForExistence(timeout: 20))

        try FileManager.default.removeItem(atPath: fixture.linkedPath)

        XCTAssertTrue(
            element("worktree-current:main").waitForExistence(timeout: 60),
            "the tab moves to the main checkout"
        )
    }

    /// A segment of the Create Worktree sheet's mode picker. macOS reports segments as radio
    /// buttons or as buttons, depending on the OS version.
    private func segment(_ title: String) -> XCUIElement {
        app.sheets.descendants(matching: .any)
            .matching(NSPredicate(
                format: "(elementType == %d OR elementType == %d) AND (label == %@ OR title == %@)",
                XCUIElement.ElementType.radioButton.rawValue,
                XCUIElement.ElementType.button.rawValue,
                title, title
            ))
            .firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.element(identifier)
    }
}
