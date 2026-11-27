import XCTest
@testable import GitCraft

final class ToastStackTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitcraft-toast-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func makeTab() throws -> (RepoTab, URL) {
        let root = try makeTempDir()
        let repo = try makeTestRepository(at: root.appendingPathComponent("repo", isDirectory: true))
        return (try RepoTab(url: repo), root)
    }

    @MainActor
    func testToastsStackOldestFirst() throws {
        let (tab, root) = try makeTab()
        defer { tab.stopWatcher(); try? FileManager.default.removeItem(at: root) }

        tab.showToast("Pushed 1 commit from \"main\".", isSuccess: true)
        tab.showToast("Fetched. \"main\" is up to date.", isSuccess: true)

        XCTAssertEqual(tab.toasts.map(\.message), [
            "Pushed 1 commit from \"main\".",
            "Fetched. \"main\" is up to date.",
        ])
    }

    @MainActor
    func testTheOldestToastGivesWayPastTheLimit() throws {
        let (tab, root) = try makeTab()
        defer { tab.stopWatcher(); try? FileManager.default.removeItem(at: root) }

        for index in 1 ... RepoTab.maxToasts + 1 {
            tab.showToast("Note \(index)")
        }

        XCTAssertEqual(tab.toasts.count, RepoTab.maxToasts)
        XCTAssertEqual(tab.toasts.first?.message, "Note 2")
        XCTAssertEqual(tab.toasts.last?.message, "Note \(RepoTab.maxToasts + 1)")
    }

    @MainActor
    func testRepeatedTextMovesTheNoteInsteadOfDuplicatingIt() throws {
        let (tab, root) = try makeTab()
        defer { tab.stopWatcher(); try? FileManager.default.removeItem(at: root) }

        tab.showToast("Fetched.")
        let firstID = try XCTUnwrap(tab.toasts.first?.id)
        tab.showToast("Pulled into \"main\".")
        tab.showToast("Fetched.")

        XCTAssertEqual(tab.toasts.map(\.message), ["Pulled into \"main\".", "Fetched."])
        XCTAssertNotEqual(tab.toasts.last?.id, firstID, "a fresh note, so its timer starts again")
    }

    @MainActor
    func testDismissingRemovesOnlyThatToast() throws {
        let (tab, root) = try makeTab()
        defer { tab.stopWatcher(); try? FileManager.default.removeItem(at: root) }

        tab.showToast("One")
        tab.showToast("Two")
        tab.dismissToast(try XCTUnwrap(tab.toasts.first?.id))

        XCTAssertEqual(tab.toasts.map(\.message), ["Two"])
    }
}
