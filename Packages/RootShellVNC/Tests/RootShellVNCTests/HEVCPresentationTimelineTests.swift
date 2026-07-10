import XCTest
@testable import RFBRendering

final class HEVCPresentationTimelineTests: XCTestCase {
    func testEverySourceUsesOneTimeline() {
        var timeline = HEVCPresentationTimeline()

        XCTAssertEqual(timeline.next(), 0)
        XCTAssertEqual(timeline.next(), 3000)
        XCTAssertEqual(timeline.next(), 6000)
    }

    func testResetRestartsTimeline() {
        var timeline = HEVCPresentationTimeline()
        _ = timeline.next()
        _ = timeline.next()

        timeline.reset()

        XCTAssertEqual(timeline.next(), 0)
    }
}
