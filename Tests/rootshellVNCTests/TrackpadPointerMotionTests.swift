import CoreGraphics
import XCTest
@testable import rootshellVNC

final class TrackpadVelocityEstimatorTests: XCTestCase {
    func testFirstSampleOfAStrokeReportsNoSpeed() {
        var estimator = TrackpadVelocityEstimator()
        // Nothing has elapsed yet, so there is no speed to measure and the
        // opening motion must not be accelerated on a guess.
        XCTAssertEqual(
            estimator.record(translation: CGPoint(x: 40, y: 0), at: 1),
            0,
            accuracy: 0.0001)
        XCTAssertEqual(estimator.velocity, 0, accuracy: 0.0001)
    }

    func testSteadyMotionConvergesOnItsTrueSpeed() {
        var estimator = TrackpadVelocityEstimator()
        var timestamp: Double = 10
        var velocity: CGFloat = 0
        // 10 points every 10 ms is 1000 points per second.
        for _ in 0..<11 {
            velocity = estimator.record(
                translation: CGPoint(x: 6, y: 8),
                at: timestamp)
            timestamp += 0.01
        }
        XCTAssertGreaterThan(velocity, 950)
        XCTAssertLessThan(velocity, 1_000)
    }

    func testSmoothingLagsASingleOutlierInsteadOfFollowingIt() {
        var estimator = TrackpadVelocityEstimator()
        estimator.record(translation: .zero, at: 0)
        let first = estimator.record(
            translation: CGPoint(x: 10, y: 0),
            at: 0.01)
        XCTAssertEqual(first, 400, accuracy: 0.0001)
        // A lone fast callback moves the average part of the way, not all of
        // it, so one jittery frame cannot spike the gain.
        let second = estimator.record(
            translation: CGPoint(x: 100, y: 0),
            at: 0.02)
        XCTAssertEqual(second, 400 + (10_000 - 400) * 0.4, accuracy: 0.0001)
    }

    func testVanishinglyShortIntervalsAreFlooredRatherThanDividedBy() {
        var estimator = TrackpadVelocityEstimator()
        estimator.record(translation: .zero, at: 5)
        let velocity = estimator.record(
            translation: CGPoint(x: 100, y: 0),
            at: 5 + 1e-9)
        XCTAssertTrue(velocity.isFinite)
        // 100 points across the 1 ms floor, weighted by the smoothing factor.
        XCTAssertEqual(velocity, 40_000, accuracy: 0.5)
    }

    func testTimestampsGoingBackwardsStayFinite() {
        var estimator = TrackpadVelocityEstimator()
        estimator.record(translation: .zero, at: 100)
        let velocity = estimator.record(
            translation: CGPoint(x: 10, y: 0),
            at: 99)
        XCTAssertTrue(velocity.isFinite)
        XCTAssertGreaterThan(velocity, 0)
    }

    func testNonFiniteSamplesLeaveTheAverageAndTheClockAlone() {
        var estimator = TrackpadVelocityEstimator()
        estimator.record(translation: .zero, at: 0)
        let established = estimator.record(
            translation: CGPoint(x: 10, y: 0),
            at: 0.01)

        XCTAssertEqual(
            estimator.record(translation: CGPoint(x: CGFloat.nan, y: 0), at: 0.02),
            established,
            accuracy: 0.0001)
        XCTAssertEqual(
            estimator.record(
                translation: CGPoint(x: 10, y: 0),
                at: .infinity),
            established,
            accuracy: 0.0001)
        // The discarded samples did not advance the clock, so the next real
        // one still measures from the last good timestamp.
        XCTAssertEqual(
            estimator.record(translation: CGPoint(x: 10, y: 0), at: 0.02),
            established + (1_000 - established) * 0.4,
            accuracy: 0.0001)
    }

    func testResetClearsBothTheAverageAndTheInterval() {
        var estimator = TrackpadVelocityEstimator()
        estimator.record(translation: .zero, at: 0)
        estimator.record(translation: CGPoint(x: 10, y: 0), at: 0.01)
        XCTAssertGreaterThan(estimator.velocity, 0)

        estimator.reset()
        XCTAssertEqual(estimator.velocity, 0, accuracy: 0.0001)
        // The stroke starts over: the first sample has no interval again.
        XCTAssertEqual(
            estimator.record(translation: CGPoint(x: 10, y: 0), at: 0.02),
            0,
            accuracy: 0.0001)
    }
}

final class TrackpadPointerWireTests: XCTestCase {
    func testWirePointShiftsByThePanesOrigin() {
        let point = TrackpadPointerWire.wirePoint(
            framebufferPoint: (x: 100, y: 50),
            origin: CGPoint(x: 1_920, y: 0))
        XCTAssertEqual(point.x, 2_020)
        XCTAssertEqual(point.y, 50)
    }

    func testWirePointClampsToTheProtocolsCoordinateRange() {
        let low = TrackpadPointerWire.wirePoint(
            framebufferPoint: (x: 4, y: 0),
            origin: CGPoint(x: -40, y: -1))
        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.y, 0)

        let high = TrackpadPointerWire.wirePoint(
            framebufferPoint: (x: 65_535, y: 65_530),
            origin: CGPoint(x: 10, y: 10))
        XCTAssertEqual(high.x, 65_535)
        XCTAssertEqual(high.y, 65_535)
    }

    func testNonFiniteOriginCollapsesToTheOriginRatherThanTrapping() {
        let point = TrackpadPointerWire.wirePoint(
            framebufferPoint: (x: 100, y: 50),
            origin: CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
        XCTAssertEqual(point.x, 0)
        XCTAssertEqual(point.y, 0)
    }

    func testFramebufferPointInvertsWirePoint() {
        let origin = CGPoint(x: 1_920, y: 16)
        let wire = TrackpadPointerWire.wirePoint(
            framebufferPoint: (x: 640, y: 480),
            origin: origin)
        let restored = TrackpadPointerWire.framebufferPoint(
            wirePoint: wire,
            origin: origin)
        XCTAssertEqual(restored.x, 640, accuracy: 0.0001)
        XCTAssertEqual(restored.y, 480, accuracy: 0.0001)
    }

    func testFramebufferPointIgnoresANonFiniteOrigin() {
        let restored = TrackpadPointerWire.framebufferPoint(
            wirePoint: (x: 300, y: 200),
            origin: CGPoint(x: CGFloat.nan, y: 0))
        XCTAssertEqual(restored.x, 300, accuracy: 0.0001)
        XCTAssertEqual(restored.y, 200, accuracy: 0.0001)
    }
}
