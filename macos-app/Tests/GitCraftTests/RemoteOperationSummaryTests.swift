import XCTest
@testable import GitCraft

final class RemoteOperationSummaryTests: XCTestCase {
    private func branch(
        _ name: String,
        remote: Bool = false,
        head: Bool = false,
        oid: Character = "a",
        ahead: UInt32 = 0,
        behind: UInt32 = 0
    ) -> BranchInfo {
        BranchInfo(
            name: name,
            fullRef: (remote ? "refs/remotes/" : "refs/heads/") + name,
            isRemote: remote,
            isHead: head,
            targetOidHex: String(repeating: oid, count: 40),
            ahead: ahead,
            behind: behind,
            isMerged: false,
            isDefault: false
        )
    }

    private func message(_ op: RemoteOperation, before: [BranchInfo], after: [BranchInfo]) -> String {
        RemoteOperation.successMessage(for: op, before: before, after: after, remote: "origin")
    }

    func testBusyLabels() {
        XCTAssertEqual(RemoteOperation.fetch.busyLabel, "Fetching…")
        XCTAssertEqual(RemoteOperation.pull.busyLabel, "Pulling…")
        XCTAssertEqual(RemoteOperation.push.busyLabel, "Pushing…")
    }

    func testFetchReportsHowFarBehindTheBranchIs() {
        let after = [branch("main", head: true, behind: 3), branch("origin/main", remote: true)]
        XCTAssertEqual(message(.fetch, before: [], after: after), "Fetched. \"main\" is 3 commits behind its upstream.")

        let one = [branch("main", head: true, behind: 1)]
        XCTAssertEqual(message(.fetch, before: [], after: one), "Fetched. \"main\" is 1 commit behind its upstream.")
    }

    func testFetchWithNothingNewOrDetachedHead() {
        XCTAssertEqual(message(.fetch, before: [], after: [branch("main", head: true)]), "Fetched. \"main\" is up to date.")
        XCTAssertEqual(message(.fetch, before: [], after: [branch("main")]), "Fetched.")
    }

    func testPullSaysWhetherTheBranchMoved() {
        let before = [branch("main", head: true, oid: "a", behind: 2)]
        let moved = [branch("main", head: true, oid: "b")]
        XCTAssertEqual(message(.pull, before: before, after: moved), "Pulled into \"main\".")
        XCTAssertEqual(message(.pull, before: before, after: before), "\"main\" is already up to date.")
    }

    func testPushCountsTheCommitsSent() {
        let before = [branch("main", head: true, ahead: 2), branch("origin/main", remote: true)]
        let after = [branch("main", head: true), branch("origin/main", remote: true)]
        XCTAssertEqual(message(.push, before: before, after: after), "Pushed 2 commits from \"main\".")
    }

    func testPushWithNothingToSend() {
        let branches = [branch("main", head: true), branch("origin/main", remote: true)]
        XCTAssertEqual(message(.push, before: branches, after: branches), "Nothing to push. \"main\" is up to date.")
    }

    func testFirstPushPublishesTheBranch() {
        let before = [branch("feature", head: true), branch("origin/main", remote: true)]
        let after = before + [branch("origin/feature", remote: true)]
        XCTAssertEqual(message(.push, before: before, after: after), "Published \"feature\" to origin.")
    }
}
