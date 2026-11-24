import XCTest
@testable import GitCraft

final class KnownSenderTests: XCTestCase {
    func testRecognisesGitHubAndClaudeAddresses() {
        XCTAssertEqual(KnownSender(email: "noreply@github.com"), .github)
        XCTAssertEqual(KnownSender(email: " NoReply@GitHub.com "), .github)
        XCTAssertEqual(KnownSender(email: "noreply@anthropic.com"), .claude)
    }

    func testOrdinaryAddressesAreNotKnownSenders() {
        for email in [
            "someone@gmail.com",
            "540510+michaelchu@users.noreply.github.com",
            "noreply@example.com",
            "",
        ] {
            XCTAssertNil(KnownSender(email: email), email)
        }
    }

    func testTilesRender() {
        for sender in [KnownSender.github, .claude] {
            XCTAssertEqual(sender.tile.size.width, 64)
        }
    }
}
