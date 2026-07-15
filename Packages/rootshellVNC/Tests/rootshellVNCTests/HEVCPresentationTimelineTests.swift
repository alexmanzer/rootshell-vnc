import XCTest
@testable import RFBRendering

final class HEVCPresentationTimelineTests: XCTestCase {
    func testEverySubmittedBandGetsUniqueMonotonicTime() {
        var timeline = HEVCPresentationTimeline()

        XCTAssertEqual(timeline.next(), 0)
        XCTAssertEqual(timeline.next(), 3_000)
        XCTAssertEqual(timeline.next(), 6_000)
        XCTAssertEqual(HEVCPresentationTimeline.timescale, 90_000)
    }

    func testResetRestartsTimeline() {
        var timeline = HEVCPresentationTimeline()
        _ = timeline.next()
        _ = timeline.next()

        timeline.reset()

        XCTAssertEqual(timeline.next(), 0)
    }
}
