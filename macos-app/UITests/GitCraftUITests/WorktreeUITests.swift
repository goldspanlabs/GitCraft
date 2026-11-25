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
        app.launchArguments = ["-UITestOpenRepository", fixture.mainPath, "-sidebar.worktreesExpanded", "YES"]
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
