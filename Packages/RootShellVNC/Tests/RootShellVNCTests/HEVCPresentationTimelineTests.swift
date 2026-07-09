import XCTest
@testable import RFBRendering

final class HEVCPresentationTimelineTests: XCTestCase {
    func testTilesAdvanceIndependentTimelines() {
        var timeline = HEVCPresentationTimeline()

        XCTAssertEqual(timeline.next(source: 10, independentTiles: true), 0)
        XCTAssertEqual(timeline.next(source: 20, independentTiles: true), 0)
        XCTAssertEqual(timeline.next(source: 10, independentTiles: true), 3000)
        XCTAssertEqual(timeline.next(source: 20, independentTiles: true), 3000)
    }

    func testConventionalStreamUsesOneTimeline() {
        var timeline = HEVCPresentationTimeline()

        XCTAssertEqual(timeline.next(source: 10, independentTiles: false), 0)
        XCTAssertEqual(timeline.next(source: 20, independentTiles: false), 3000)
        XCTAssertEqual(timeline.next(source: 10, independentTiles: false), 6000)
    }

    func testResetRestartsEveryTimeline() {
        var timeline = HEVCPresentationTimeline()
        _ = timeline.next(source: 10, independentTiles: true)
        _ = timeline.next(source: 10, independentTiles: true)
        _ = timeline.next(source: 20, independentTiles: false)

        timeline.reset()

        XCTAssertEqual(timeline.next(source: 10, independentTiles: true), 0)
        XCTAssertEqual(timeline.next(source: 20, independentTiles: false), 0)
    }
}
