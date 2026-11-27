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
        RemoteOperation.successMessage(for: op, before: before, after: after)
    }

    func testBusyLabels() {
        XCTAssertEqual(RemoteOperation.fetch.busyLabel, "Fetching…")
        XCTAssertEqual(RemoteOperation.pull.busyLabel, "Pulling…")
        XCTAssertEqual(RemoteOperation.push.busyLabel, "Pushing…")
    }

    func testFetchReportsHowFarBehindTheBranchIs() {
        let after = [branch("main", head: true, behind: 3), branch("origin/main", remote: true)]
        XCTAssertEqual(message(.fetch, before: [], after: after), "Fetched. \"main\" is 3 commits behind the remote.")

        let one = [branch("main", head: true, behind: 1)]
        XCTAssertEqual(message(.fetch, before: [], after: one), "Fetched. \"main\" is 1 commit behind the remote.")
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

    private func push(
        _ branch: String,
        to destination: String,
        commits: UInt32,
        published: Bool = false,
        upToDate: Bool = false,
        forced: Bool = false,
        includedBranch: Bool = true
    ) -> String {
        RemoteOperation.pushMessage(PushResult(
            branch: branch, destination: destination, commits: commits,
            published: published, upToDate: upToDate, forced: forced, includedBranch: includedBranch
        ))
    }

    func testPushCountsTheCommitsSentToTheRealDestination() {
        XCTAssertEqual(push("main", to: "origin/main", commits: 2, published: false), "Pushed 2 commits to origin/main.")
        XCTAssertEqual(push("main", to: "fork/main", commits: 1, published: false), "Pushed 1 commit to fork/main.")
    }

    func testPushWithNothingToSend() {
        XCTAssertEqual(
            push("main", to: "origin/main", commits: 0, upToDate: true),
            "Nothing to push. origin/main already has \"main\"."
        )
    }

    func testFirstPushPublishesTheBranch() {
        XCTAssertEqual(
            push("feature", to: "origin/feature", commits: 0, published: true),
            "Published \"feature\" to origin/feature."
        )
    }

    func testAForcedRewindIsAnUpdateNotANoOp() {
        XCTAssertEqual(
            push("main", to: "origin/main", commits: 0, forced: true),
            "Force-pushed \"main\" to origin/main."
        )
    }

    func testAPushThatSkippedTheBranchDoesntClaimIt() {
        XCTAssertEqual(
            push("main", to: "origin/main", commits: 0, includedBranch: false),
            "Pushed, but not \"main\": your push settings send other branches only."
        )
    }

    func testAPushGitDidntCountStillSaysItPushed() {
        XCTAssertEqual(push("main", to: "origin/main", commits: 0), "Pushed \"main\" to origin/main.")
    }
}
