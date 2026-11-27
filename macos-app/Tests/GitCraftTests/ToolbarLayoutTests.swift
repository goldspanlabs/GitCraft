import AppKit
import XCTest
@testable import GitCraft

final class ToolbarLayoutTests: XCTestCase {
    @MainActor
    func testActionButtonsStayCenteredInTheTopBar() throws {
        _ = NSApplication.shared
        let root = temporaryFolderURL("gitcraft-toolbar")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeTestRepository(at: root.appendingPathComponent("repo", isDirectory: true))
        let workspace = WorkspaceState()
        XCTAssertTrue(workspace.openRepository(at: URL(fileURLWithPath: RepoTab.canonicalPath(for: repo.path))))
        let window = try XCTUnwrap(NSApp.windows.first {
            ($0.windowController as? RepoWindowController)?.tab.repoPath.hasSuffix(root.lastPathComponent + "/repo") == true
        })
        defer { window.close() }
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)

        for collapsed in [true, false] {
            split.splitViewItems[0].isCollapsed = collapsed
            for (width, sidebarWidth) in [(1040.0, 220.0), (1040, 340), (1180, 260), (1800, 220), (1040, 220)] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 700), display: true)
                if !collapsed { split.splitView.setPosition(sidebarWidth, ofDividerAt: 0) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                // A running app does this after every event; the test has no event loop.
                window.update()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                // The top bar starts at the sidebar's edge while the sidebar is showing.
                let sidebar = split.splitViewItems[0].viewController.view
                let leading = collapsed ? 0 : sidebar.convert(sidebar.bounds, to: nil).maxX
                let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == .repoActions })
                let view = try XCTUnwrap(item.view)
                XCTAssertNotNil(view.window, "actions overflowed at \(width)")
                XCTAssertEqual(
                    view.convert(view.bounds, to: nil).midX, (leading + window.frame.width) / 2, accuracy: 3,
                    "width \(width), sidebar \(leading)"
                )

                // The neighbours make room rather than disappearing or overlapping.
                let frames = try XCTUnwrap(window.toolbar).items.compactMap { item -> NSRect? in
                    guard [.repoTitle, .repoActions, .repoSearch].contains(item.itemIdentifier) else { return nil }
                    let view = (item as? NSSearchToolbarItem)?.searchField ?? item.view
                    guard let view, view.window != nil else { return nil }
                    return view.convert(view.bounds, to: nil)
                }
                XCTAssertEqual(frames.count, 3, "width \(width), sidebar \(leading)")
                for (left, right) in zip(frames, frames.dropFirst()) {
                    XCTAssertLessThanOrEqual(left.maxX, right.minX, "width \(width), sidebar \(leading)")
                }
            }
        }
    }
}
