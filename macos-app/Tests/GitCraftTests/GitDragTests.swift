import AppKit
import XCTest
@testable import GitCraft

final class GitDragTests: XCTestCase {
    private let head = String(repeating: "a", count: 40)
    private let source = String(repeating: "b", count: 40)
    private let older = String(repeating: "c", count: 40)

    private func payload(branch: Bool = false, oids: [String]? = nil) -> GitDragPayload {
        GitDragPayload(checkout: "/repo", headOID: head, branch: "main", oids: oids ?? [source],
                       sourceRef: branch ? "refs/heads/feature" : nil, label: branch ? "feature" : "bbbbbbb")
    }

    private func resolve(_ payload: GitDragPayload, _ target: GitDropTarget, option: Bool = false,
                         checkout: String = "/repo", branch: String = "main", headOID: String? = nil,
                         unavailable: Bool = false) -> GitDropResolution {
        .resolve(payload, target: target, checkout: checkout, branch: branch,
                 headOID: headOID ?? head, unavailable: unavailable, option: option)
    }

    func testBranchDirectionAndOption() {
        XCTAssertEqual(resolve(payload(branch: true), .head).action, .merge)
        XCTAssertEqual(resolve(payload(branch: true), .head).message, "Merge feature into main")
        XCTAssertEqual(resolve(payload(branch: true), .branch("main"), option: true).action, .rebase)
        XCTAssertEqual(resolve(payload(branch: true), .head, option: true).message, "Rebase main onto feature")
        XCTAssertFalse(resolve(payload(branch: true), .branch("other")).isAllowed)
        XCTAssertFalse(resolve(payload(branch: true), .commit(older)).isAllowed)
    }

    func testCommitsCopyOntoHeadRegardlessOfOption() {
        for target in [GitDropTarget.head, .branch("main")] {
            for option in [false, true] {
                XCTAssertEqual(resolve(payload(), target, option: option).action, .cherryPick)
            }
        }
        XCTAssertFalse(resolve(payload(oids: [head]), .head).isAllowed)
        XCTAssertFalse(resolve(payload(oids: [source, older]), .head).isAllowed)
    }

    func testCreateBranchAndTagRequireOneObject() {
        for isBranch in [true, false] {
            XCTAssertEqual(resolve(payload(branch: isBranch), .branches).action, .createBranch)
            XCTAssertEqual(resolve(payload(branch: isBranch), .tags).action, .createTag)
        }
        XCTAssertFalse(resolve(payload(oids: [source, older]), .branches).isAllowed)
        XCTAssertFalse(resolve(payload(oids: [source, older]), .tags).isAllowed)
    }

    func testSquashFixupAndSelfDrops() {
        XCTAssertEqual(resolve(payload(), .commit(older)).action, .squash)
        XCTAssertEqual(resolve(payload(), .commit(older), option: true).action, .fixup)
        XCTAssertFalse(resolve(payload(), .commit(source)).isAllowed)
        XCTAssertFalse(resolve(payload(oids: [source, older]), .commit(older)).isAllowed)
        XCTAssertEqual(resolve(payload(oids: [source, head]), .commit(older)).action, .squash)
    }

    func testStaleOrCrossCheckoutDropsAreRefusedForEveryTarget() {
        for target in [GitDropTarget.head, .branches, .tags, .commit(older)] {
            XCTAssertFalse(resolve(payload(), target, checkout: "/other").isAllowed)
            XCTAssertFalse(resolve(payload(), target, branch: "feature").isAllowed)
            XCTAssertFalse(resolve(payload(), target, headOID: source).isAllowed)
            XCTAssertFalse(resolve(payload(), target, unavailable: true).isAllowed)
            XCTAssertFalse(resolve(payload(), target, branch: "").isAllowed)
        }
    }

    func testPayloadRoundTripAndMalformedPayloads() throws {
        let original = payload()
        XCTAssertEqual(GitDragPayload.decode(try XCTUnwrap(original.data)), original)
        XCTAssertNil(GitDragPayload.decode(Data("garbage".utf8)))
        XCTAssertNil(GitDragPayload.decode(Data(repeating: 0, count: 64_001)))
        for oids in [[], ["--help"], [String(repeating: "z", count: 40)], [source, source], Array(repeating: source, count: 101)] {
            XCTAssertNil(GitDragPayload.decode(try XCTUnwrap(payload(oids: oids).data)))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(original.data)) as? [String: Any])
        object["token"] = "another process"
        XCTAssertNil(GitDragPayload.decode(try JSONSerialization.data(withJSONObject: object)))
        let sha256 = payload(oids: [String(repeating: "d", count: 64)])
        XCTAssertEqual(GitDragPayload.decode(try XCTUnwrap(sha256.data)), sha256)
    }

    @MainActor
    func testPasteboardBridgeUsesTheSamePayloadAndRejectsPlainText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([GitDragPayload.pasteboardType], owner: nil)
        board.setData(try XCTUnwrap(payload().data), forType: GitDragPayload.pasteboardType)
        XCTAssertEqual(GitDragPayload.read(from: board), payload())
        board.clearContents()
        board.setString(source, forType: .string)
        XCTAssertNil(GitDragPayload.read(from: board))
        XCTAssertTrue(payload().itemProvider.hasItemConformingToTypeIdentifier(GitDragPayload.typeIdentifier))
    }
}
