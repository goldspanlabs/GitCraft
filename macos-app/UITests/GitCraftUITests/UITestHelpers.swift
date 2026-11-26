import XCTest

extension XCTestCase {
    /// Right-clicks the centre of `element` by coordinate. Rows and headers are containers that
    /// XCUITest can report as not hittable even when they are on screen.
    func rightClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    }

    /// A menu item titled `title` that is currently on screen. The menu bar's Repository menu
    /// carries the same titles (New Branch…, New Worktree…) and stays in the tree while closed,
    /// so a plain `app.menuItems[title]` matches two elements and can't be clicked.
    /// `isHittable` is not a valid predicate key path for queries, so the label query is
    /// filtered here in Swift instead. Falls back to the first match if none becomes hittable.
    func openMenuItem(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let matches = app.menuItems.matching(NSPredicate(format: "label == %@", title))
        func hittableMatch() -> XCUIElement? {
            (0..<matches.count).lazy.map { matches.element(boundBy: $0) }.first { $0.isHittable }
        }
        var found: XCUIElement?
        _ = waitUntil(timeout: timeout) {
            found = hittableMatch()
            return found != nil
        }
        return found ?? matches.firstMatch
    }

    /// Polls `element` against `predicate` at a short interval until it holds or `timeout` passes.
    /// Avoids `XCTNSPredicateExpectation`'s ~1s polling cadence.
    func wait(
        for element: XCUIElement,
        toSatisfy predicate: String,
        argument: String? = nil,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> Bool {
        let compiled = argument.map { NSPredicate(format: predicate, $0) } ?? NSPredicate(format: predicate)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if compiled.evaluate(with: element) { return true }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(min(pollInterval, remaining)))
        }
    }

    /// Polls `condition` until it holds or `timeout` passes. Used for checks on the repository
    /// on disk, which the UI changes asynchronously.
    func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(min(pollInterval, remaining)))
        }
    }
}

extension XCUIApplication {
    /// Looks up an element by accessibility identifier inside the main window instead of walking
    /// the entire application tree (menu bar, TouchBar, auxiliary windows).
    func element(_ identifier: String) -> XCUIElement {
        windows.firstMatch.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
