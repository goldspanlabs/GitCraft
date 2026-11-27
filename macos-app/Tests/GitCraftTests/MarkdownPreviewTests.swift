import XCTest
@testable import GitCraft

final class MarkdownPreviewTests: XCTestCase {
    func testIsMarkdownPathRecognizesMarkdownExtensions() {
        XCTAssertTrue(RepoTab.isMarkdownPath("README.md"))
        XCTAssertTrue(RepoTab.isMarkdownPath("docs/GUIDE.MD"))
        XCTAssertTrue(RepoTab.isMarkdownPath("notes.markdown"))
        XCTAssertTrue(RepoTab.isMarkdownPath("changelog.mdown"))
        XCTAssertTrue(RepoTab.isMarkdownPath("spec.mkd"))

        XCTAssertFalse(RepoTab.isMarkdownPath(nil))
        XCTAssertFalse(RepoTab.isMarkdownPath("Sources/App.swift"))
        XCTAssertFalse(RepoTab.isMarkdownPath("README"))
        XCTAssertFalse(RepoTab.isMarkdownPath("All Changed Files"))
    }
}
