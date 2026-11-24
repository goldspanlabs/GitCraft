import AppKit
import XCTest
@testable import GitCraft

final class GraphLayoutTests: XCTestCase {
    // leftPadding (4) * 2 + one lane (14) = 22 for a single lane.
    func testSingleLaneWidth() {
        XCTAssertEqual(GraphCellView.width(forLanes: 1), 22)
    }

    func testZeroLanesReservesTheSameSpaceAsOneLane() {
        XCTAssertEqual(GraphCellView.width(forLanes: 0), GraphCellView.width(forLanes: 1))
    }

    func testEachAdditionalLaneAddsOneLaneWidth() {
        let perLane = GraphCellView.width(forLanes: 3) - GraphCellView.width(forLanes: 2)
        XCTAssertEqual(perLane, 14)
        XCTAssertEqual(GraphCellView.width(forLanes: 3), 50)
    }
}
