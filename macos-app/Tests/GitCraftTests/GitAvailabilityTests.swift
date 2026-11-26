import Foundation
import XCTest
@testable import GitCraft

final class GitAvailabilityTests: XCTestCase {
    @MainActor
    func testRefreshGitAvailabilityTracksProviderState() {
        var current: GitAvailability = .missing
        let workspace = WorkspaceState(gitAvailabilityProvider: { current })

        XCTAssertEqual(workspace.refreshGitAvailability(), .missing)
        XCTAssertEqual(workspace.gitAvailability, .missing)

        current = .needsCommandLineTools
        XCTAssertEqual(workspace.refreshGitAvailability(), .needsCommandLineTools)
        XCTAssertEqual(workspace.gitAvailability, .needsCommandLineTools)

        current = .available
        XCTAssertEqual(workspace.refreshGitAvailability(), .available)
        XCTAssertEqual(workspace.gitAvailability, .available)
    }

    @MainActor
    func testOpenRepositoryIsGatedWhenGitIsUnavailable() {
        var current: GitAvailability = .missing
        let workspace = WorkspaceState(gitAvailabilityProvider: { current })
        XCTAssertEqual(workspace.refreshGitAvailability(), .missing)

        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitcraft-missing-git-\(UUID().uuidString)")
        XCTAssertFalse(workspace.openRepository(at: nonexistent))
        XCTAssertNil(workspace.openError, "gating on missing git should not record a repo open error")

        // Once git becomes available, openRepository proceeds to attempt opening and reports
        // the normal repository error for a non-repo path.
        current = .available
        XCTAssertFalse(workspace.openRepository(at: nonexistent))
        XCTAssertEqual(workspace.gitAvailability, .available)
        XCTAssertNotNil(workspace.openError)
    }
}
