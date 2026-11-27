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

    func testCoAuthorLinesOutsideTheTrailerBlockStayInTheBody() {
        let example = "Write trailers like this:\n\n```\nCo-authored-by: Ex <ex@x.com>\n```"
        let quoted = "Co-authored-by: Q <q@x.com>\nis the syntax."

        let draft = SquashMessage.draft(for: [commit("One", body: example), commit("Two", body: quoted)])

        XCTAssertEqual(draft.description, "\(example)\n\nTwo\n\n\(quoted)")
    }

    func testCoAuthorsLeaveTheTrailerBlockAndOtherTrailersStay() {
        let body = "Why.\n\nSigned-off-by: Cy <cy@x.com>\nCo-authored-by: Di <di@x.com>"

        let draft = SquashMessage.draft(for: [commit("One", body: body), commit("Two")])

        XCTAssertEqual(
            draft.description,
            "Why.\n\nSigned-off-by: Cy <cy@x.com>\n\nTwo\n\nCo-authored-by: Di <di@x.com>"
        )
    }

    func testOneAuthorGetsNoCoAuthorLine() {
        let draft = SquashMessage.draft(for: [commit("One"), commit("Two")])

        XCTAssertEqual(draft.description, "Two")
    }
}
