import XCTest

/// End-to-end checks for the WORKTREES sidebar. Each test creates a throwaway repository with
/// a linked worktree, launches the built GitCraft.app on it, and drives the sidebar.
final class WorktreeUITests: XCTestCase {
    private var fixture: FixtureRepository!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try FixtureRepository.make(linkedWorktree: true)
        app = XCUIApplication(url: try GitCraftApp.bundleURL())
        // Force the WORKTREES section open: its expanded state is a persisted user preference.
        app.launchArguments = [
            "-UITestOpenRepository", fixture.mainPath,
            "-sidebar.worktreesExpanded", "YES",
            // Make the sheet's confirm button always read "Create and Switch".
            "-createWorktreeSwitch", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
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
        XCTAssertTrue(element("worktree-row:main").exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkedPath), "the folder is deleted")
    }

    /// Right-clicks the centre of `element` by coordinate. Rows and headers are containers that
    /// XCUITest can report as not hittable even when they are on screen.
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
