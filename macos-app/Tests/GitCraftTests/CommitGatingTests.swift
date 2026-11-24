import XCTest
@testable import GitCraft

final class CommitGatingTests: XCTestCase {
    func testNeedsASummary() {
        XCTAssertFalse(GitPreferences.canCommit(summary: "   ", stagedCount: 1, changedCount: 1, autoStage: true, isBusy: false))
    }

    func testStagedFilesAreEnoughWhenAutoStageIsOff() {
        XCTAssertTrue(GitPreferences.canCommit(summary: "Fix", stagedCount: 1, changedCount: 1, autoStage: false, isBusy: false))
    }

    func testUnstagedChangesOnlyCountWhenAutoStageIsOn() {
        XCTAssertTrue(GitPreferences.canCommit(summary: "Fix", stagedCount: 0, changedCount: 2, autoStage: true, isBusy: false))
        XCTAssertFalse(GitPreferences.canCommit(summary: "Fix", stagedCount: 0, changedCount: 2, autoStage: false, isBusy: false))
    }

    func testNothingToCommitDisablesCommit() {
        XCTAssertFalse(GitPreferences.canCommit(summary: "Fix", stagedCount: 0, changedCount: 0, autoStage: true, isBusy: false))
    }

    func testBusyBlocksCommit() {
        XCTAssertFalse(GitPreferences.canCommit(summary: "Fix", stagedCount: 1, changedCount: 1, autoStage: true, isBusy: true))
    }
}
