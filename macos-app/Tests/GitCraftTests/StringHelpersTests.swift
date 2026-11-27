import XCTest
@testable import GitCraft

final class StringHelpersTests: XCTestCase {
    func testJoinedOntoOneLineJoinsEachKindOfLineBreak() {
        XCTAssertEqual("one\ntwo".joinedOntoOneLine, "one two")
        XCTAssertEqual("one\r\ntwo".joinedOntoOneLine, "one two")
        XCTAssertEqual("one\rtwo".joinedOntoOneLine, "one two")
        XCTAssertEqual("one\u{2028}two\u{2029}three".joinedOntoOneLine, "one two three")
    }

    func testARunOfBreaksAndTheSpacesAroundItBecomeOneSpace() {
        XCTAssertEqual("one\n\n\ntwo".joinedOntoOneLine, "one two")
        XCTAssertEqual("one  \n\t  two".joinedOntoOneLine, "one two")
    }

    func testBreaksAtTheEndsAreDropped() {
        XCTAssertEqual("\n\none\ntwo\n".joinedOntoOneLine, "one two")
    }

    func testTextWithoutBreaksIsUnchanged() {
        XCTAssertEqual("one  two\tthree ".joinedOntoOneLine, "one  two\tthree ")
        XCTAssertEqual("".joinedOntoOneLine, "")
    }
}
