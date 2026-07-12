import XCTest
@testable import rootshellVNC

final class DecodeOutputStallDetectorTests: XCTestCase {
    func testStaticStreamDoesNotLookStalled() {
        var detector = DecodeOutputStallDetector(
            stallThresholdNanos: 100,
            recoveryCooldownNanos: 200)

        XCTAssertFalse(detector.observe(
            submittedFrameCount: 0,
            deliveredFrameCount: 0,
            nowNanos: 1_000))
        XCTAssertFalse(detector.observe(
            submittedFrameCount: 0,
            deliveredFrameCount: 0,
            nowNanos: 10_000))
    }

    func testContinuingSubmissionsWithoutOutputTriggerRecovery() {
        var detector = DecodeOutputStallDetector(
            stallThresholdNanos: 100,
            recoveryCooldownNanos: 200)

        XCTAssertFalse(detector.observe(
            submittedFrameCount: 1,
            deliveredFrameCount: 0,
            nowNanos: 1_000))
        XCTAssertFalse(detector.observe(
            submittedFrameCount: 2,
            deliveredFrameCount: 0,
            nowNanos: 1_099))
        XCTAssertTrue(detector.observe(
            submittedFrameCount: 3,
            deliveredFrameCount: 0,
            nowNanos: 1_100))
        XCTAssertFalse(detector.observe(
            submittedFrameCount: 4,
            deliveredFrameCount: 0,
            nowNanos: 1_200))
        XCTAssertTrue(detector.observe(
            submittedFrameCount: 5,
            deliveredFrameCount: 0,
            nowNanos: 1_300))
    }

    func testOutputProgressClearsStallWindow() {
        var detector = DecodeOutputStallDetector(
            stallThresholdNanos: 100,
            recoveryCooldownNanos: 200)

        XCTAssertFalse(detector.observe(
            submittedFrameCount: 1,
            deliveredFrameCount: 0,
            nowNanos: 1_000))
        XCTAssertFalse(detector.observe(
            submittedFrameCount: 2,
            deliveredFrameCount: 1,
            nowNanos: 1_100))
        XCTAssertFalse(detector.observe(
            submittedFrameCount: 3,
            deliveredFrameCount: 1,
            nowNanos: 1_200))
        XCTAssertFalse(detector.observe(
            submittedFrameCount: 4,
            deliveredFrameCount: 1,
            nowNanos: 1_299))
        XCTAssertTrue(detector.observe(
            submittedFrameCount: 5,
            deliveredFrameCount: 1,
            nowNanos: 1_300))
    }
}
