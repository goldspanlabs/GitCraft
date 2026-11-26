import XCTest
@testable import GitCraft

final class ErrorSummaryTests: XCTestCase {
    func testShortSingleLineMessageHasNoDetails() {
        let summary = ErrorSummary("nothing to commit")
        XCTAssertEqual(summary.summary, "nothing to commit")
        XCTAssertFalse(summary.hasDetails)
    }

    func testMultiLineMessageSummarisesTheFirstLine() {
        let output = "pre-commit: cargo fmt --check\nDiff in file.rs:8:\n-old\n+new\n"
        let summary = ErrorSummary(output)
        XCTAssertEqual(summary.summary, "pre-commit: cargo fmt --check")
        XCTAssertTrue(summary.hasDetails)
        XCTAssertTrue(summary.full.contains("+new"))
    }

    func testErrorLineWinsOverAStepBannerAbove() {
        // The pre-push hook prints its step name first; the failure is the error line.
        let output = "pre-push: cargo clippy\n    Checking gitcraft-core\nerror: function `f` is never used\n  --> src/graph.rs:67:4\n"
        let summary = ErrorSummary(output)
        XCTAssertEqual(summary.summary, "error: function `f` is never used")
        XCTAssertTrue(summary.hasDetails)
        XCTAssertTrue(summary.full.hasPrefix("pre-push: cargo clippy"))
    }

    func testFatalLineIsPreferredToo() {
        let summary = ErrorSummary("Enumerating objects\nfatal: unable to access remote\n")
        XCTAssertEqual(summary.summary, "fatal: unable to access remote")
    }

    func testLeadingBlankLinesAreSkipped() {
        let summary = ErrorSummary("\n\n  failed to push\nremote: rejected")
        XCTAssertEqual(summary.summary, "failed to push")
    }

    func testVeryLongLineIsTruncatedAndOffersDetails() {
        let long = String(repeating: "x", count: 400)
        let summary = ErrorSummary(long)
        XCTAssertEqual(summary.summary.count, ErrorSummary.maxSummaryLength + 1)
        XCTAssertTrue(summary.hasDetails)
        XCTAssertEqual(summary.full, long)
    }

    func testCoreErrorsShowGitsOwnMessage() {
        let error: Error = GitCraftError.Message(msg: "  fatal: bad ref\n")
        XCTAssertEqual(error.displayMessage, "fatal: bad ref")
    }

    func testGitNotFoundShowsFriendlyMessage() {
        let error: Error = GitCraftError.GitNotFound
        XCTAssertTrue(error.isGitNotFound)
        XCTAssertTrue(error.displayMessage.contains("Git is not installed"))
    }
}
