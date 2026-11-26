import Foundation
import XCTest
@testable import GitCraft

private final class AvailabilityBox: @unchecked Sendable {
    var value: GitAvailability
    init(_ value: GitAvailability) { self.value = value }
}

final class GitAvailabilityTests: XCTestCase {
    @MainActor
    func testRefreshGitAvailabilityAsyncTracksProviderState() async {
        let box = AvailabilityBox(.missing)
        let workspace = WorkspaceState(gitAvailabilityProvider: { box.value })

        let first = await workspace.refreshGitAvailabilityAsync()
        XCTAssertEqual(first, .missing)
        XCTAssertEqual(workspace.gitAvailability, .missing)

        box.value = .needsCommandLineTools
        let second = await workspace.refreshGitAvailabilityAsync()
        XCTAssertEqual(second, .needsCommandLineTools)
        XCTAssertEqual(workspace.gitAvailability, .needsCommandLineTools)

        box.value = .available
        let third = await workspace.refreshGitAvailabilityAsync()
        XCTAssertEqual(third, .available)
        XCTAssertEqual(workspace.gitAvailability, .available)
    }

    @MainActor
    func testOpenRepositoryRevalidatesWhenGitIsRemovedAfterLaunch() {
        let box = AvailabilityBox(.available)
        let workspace = WorkspaceState(gitAvailabilityProvider: { box.value })
        XCTAssertEqual(workspace.refreshGitAvailability(), .available)

        // Simulate git being removed after launch while cached gitAvailability is still .available.
        box.value = .missing
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitcraft-missing-git-\(UUID().uuidString)")
        XCTAssertFalse(workspace.openRepository(at: nonexistent))
        XCTAssertEqual(workspace.gitAvailability, .missing)
        XCTAssertNil(workspace.openError, "gating on missing git should not record a repo open error")

        // Once git becomes available again, openRepository proceeds and reports the repo error.
        box.value = .available
        XCTAssertFalse(workspace.openRepository(at: nonexistent))
        XCTAssertEqual(workspace.gitAvailability, .available)
        XCTAssertNotNil(workspace.openError)
    }
}
