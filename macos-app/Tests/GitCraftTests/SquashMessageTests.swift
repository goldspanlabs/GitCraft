import XCTest
@testable import GitCraft

/// The message a squash starts with.
final class SquashMessageTests: XCTestCase {
    private func commit(
        _ summary: String,
        body: String = "",
        author: String = "Ada",
        email: String = "ada@x.com"
    ) -> SquashCommit {
        SquashCommit(
            oidHex: summary, shortOid: summary, summary: summary, body: body,
            authorName: author, authorEmail: email
        )
    }

    func testCombinesMessagesAndCreditsOtherAuthorsOnce() {
        let draft = SquashMessage.draft(for: [
            commit("Add parser", body: "Why."),
            commit("Fix typo", author: "Bo", email: "bo@x.com"),
            commit("Handle empty input", author: "Bo", email: "BO@x.com"),
        ])

        XCTAssertEqual(draft.summary, "Add parser")
        XCTAssertEqual(
            draft.description,
            "Why.\n\nFix typo\n\nHandle empty input\n\nCo-authored-by: Bo <bo@x.com>"
        )
    }

    func testLaterBodiesFollowTheirSummaries() {
        let draft = SquashMessage.draft(for: [commit("One"), commit("Two", body: "Because.")])

        XCTAssertEqual(draft.description, "Two\n\nBecause.")
    }

    func testExistingCoAuthorLinesMoveToTheEndOnePerEmail() {
        let draft = SquashMessage.draft(for: [
            commit("One", body: "First.\n\nCo-authored-by: Cy <cy@x.com>"),
            commit("Two", body: "co-authored-by: Cy <CY@x.com>\nCo-authored-by: Di <di@x.com>"),
            commit("Three", author: "Di", email: "di@x.com"),
        ])

        XCTAssertEqual(
            draft.description,
            "First.\n\nTwo\n\nThree\n\nCo-authored-by: Cy <cy@x.com>\nCo-authored-by: Di <di@x.com>"
        )
    }

    func testOneAuthorGetsNoCoAuthorLine() {
        let draft = SquashMessage.draft(for: [commit("One"), commit("Two")])

        XCTAssertEqual(draft.description, "Two")
    }
}
