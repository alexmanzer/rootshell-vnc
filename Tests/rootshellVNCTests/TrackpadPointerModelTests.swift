import CoreGraphics
import XCTest
@testable import rootshellVNC

final class TrackpadPointerModelTests: XCTestCase {
    private let framebufferSize = CGSize(width: 1920, height: 1080)

    private func makeModel(
        at position: CGPoint = CGPoint(x: 960, y: 540),
        speed: Double = 1
    ) -> TrackpadPointerModel {
        TrackpadPointerModel(
            position: position,
            framebufferSize: framebufferSize,
            speed: speed)
    }

    func testPositionIsClampedToTheLastAddressablePixel() {
        var model = makeModel(at: CGPoint(x: -50, y: 5_000))
        XCTAssertEqual(model.position.x, 0, accuracy: 0.0001)
        XCTAssertEqual(model.position.y, 1_079, accuracy: 0.0001)

        model.place(at: CGPoint(x: 10_000, y: -10_000))
        XCTAssertEqual(model.position.x, 1_919, accuracy: 0.0001)
        XCTAssertEqual(model.position.y, 0, accuracy: 0.0001)

        model.place(at: CGPoint(x: 12.5, y: 400.25))
        XCTAssertEqual(model.position.x, 12.5, accuracy: 0.0001)
        XCTAssertEqual(model.position.y, 400.25, accuracy: 0.0001)
    }

    func testGainCurveHoldsFlatTailsAroundALinearRamp() {
        XCTAssertEqual(TrackpadPointerModel.gain(forVelocity: 0), 0.9, accuracy: 0.0001)
        XCTAssertEqual(TrackpadPointerModel.gain(forVelocity: 50), 0.9, accuracy: 0.0001)
        XCTAssertEqual(TrackpadPointerModel.gain(forVelocity: 325), 1.55, accuracy: 0.0001)
        XCTAssertEqual(TrackpadPointerModel.gain(forVelocity: 600), 2.2, accuracy: 0.0001)
        XCTAssertEqual(
            TrackpadPointerModel.gain(forVelocity: 10_000), 2.2, accuracy: 0.0001)
        // A backwards velocity is not a faster one; it must not accelerate.
        XCTAssertEqual(TrackpadPointerModel.gain(forVelocity: -800), 0.9, accuracy: 0.0001)
    }

    func testGainIsMonotonicAndBounded() {
        var previous = TrackpadPointerModel.gain(forVelocity: -200)
        for step in stride(from: CGFloat(-200), through: 1_200, by: 5) {
            let gain = TrackpadPointerModel.gain(forVelocity: step)
            XCTAssertGreaterThanOrEqual(gain, previous)
            XCTAssertGreaterThanOrEqual(gain, TrackpadPointerModel.minimumGain)
            XCTAssertLessThanOrEqual(gain, TrackpadPointerModel.maximumGain)
            previous = gain
        }
    }

    func testGainFallsBackToTheFloorForDegenerateVelocity() {
        XCTAssertEqual(TrackpadPointerModel.gain(forVelocity: .nan), 0.9, accuracy: 0.0001)
        XCTAssertEqual(
            TrackpadPointerModel.gain(forVelocity: .infinity), 0.9, accuracy: 0.0001)
        XCTAssertEqual(
            TrackpadPointerModel.gain(forVelocity: -.infinity), 0.9, accuracy: 0.0001)
    }

    func testSpeedIsClampedToTheSupportedRange() {
        var model = makeModel(speed: 99)
        XCTAssertEqual(model.speed, 3, accuracy: 0.0001)

        model.speed = 0.1
        XCTAssertEqual(model.speed, 0.5, accuracy: 0.0001)

        model.speed = 1.75
        XCTAssertEqual(model.speed, 1.75, accuracy: 0.0001)

        model.speed = .nan
        XCTAssertEqual(model.speed, TrackpadPointerModel.defaultSpeed, accuracy: 0.0001)
    }

    func testMotionScalesByGainSpeedAndZoom() {
        var model = makeModel(at: CGPoint(x: 100, y: 100), speed: 2)
        let moved = model.move(
            by: CGPoint(x: 10, y: -5),
            framebufferPixelsPerPoint: 1,
            velocity: 0)

        // 0.9 gain x 2.0 speed x 1 pixel per point.
        XCTAssertEqual(moved.x, 118, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 91, accuracy: 0.0001)
        XCTAssertEqual(model.position.x, 118, accuracy: 0.0001)

        var zoomed = makeModel(at: CGPoint(x: 100, y: 100))
        zoomed.move(
            by: CGPoint(x: 10, y: 0),
            framebufferPixelsPerPoint: 3,
            velocity: 600)
        // 2.2 gain x 1.0 speed x 3 pixels per point.
        XCTAssertEqual(zoomed.position.x, 166, accuracy: 0.0001)
    }

    func testSubpixelMotionAccumulatesAcrossManyMoves() {
        var model = makeModel(at: CGPoint(x: 10, y: 10))
        for _ in 0..<10 {
            // 0.18 framebuffer pixels per move: every individual step would
            // vanish if the position were rounded as it went.
            model.move(
                by: CGPoint(x: 0.2, y: 0),
                framebufferPixelsPerPoint: 1,
                velocity: 0)
        }

        XCTAssertEqual(model.position.x, 11.8, accuracy: 0.0001)
        XCTAssertEqual(model.integerPosition.x, 12)
    }

    func testMoveIgnoresDegenerateInput() {
        var model = makeModel(at: CGPoint(x: 100, y: 100))

        model.move(
            by: CGPoint(x: CGFloat.nan, y: 4),
            framebufferPixelsPerPoint: 1,
            velocity: 100)
        model.move(
            by: CGPoint(x: 10, y: 10),
            framebufferPixelsPerPoint: 0,
            velocity: 100)
        model.move(
            by: CGPoint(x: 10, y: 10),
            framebufferPixelsPerPoint: .infinity,
            velocity: 100)

        XCTAssertEqual(model.position.x, 100, accuracy: 0.0001)
        XCTAssertEqual(model.position.y, 100, accuracy: 0.0001)
    }

    func testIntegerPositionRoundsAndStaysOnTheFramebuffer() {
        var model = makeModel(at: CGPoint(x: 1_918.6, y: 0.4))
        XCTAssertEqual(model.integerPosition.x, 1_919)
        XCTAssertEqual(model.integerPosition.y, 0)

        model.place(at: CGPoint(x: 5_000, y: 5_000))
        XCTAssertEqual(model.integerPosition.x, 1_919)
        XCTAssertEqual(model.integerPosition.y, 1_079)
    }

    func testIntegerPositionSaturatesAtTheProtocolLimit() {
        let model = TrackpadPointerModel(
            position: CGPoint(x: 70_000, y: 70_000),
            framebufferSize: CGSize(width: 80_000, height: 80_000))
        XCTAssertEqual(model.position.x, 70_000, accuracy: 0.0001)
        XCTAssertEqual(model.integerPosition.x, UInt16.max)
        XCTAssertEqual(model.integerPosition.y, UInt16.max)
    }

    func testFramebufferSizeChangeReclampsPosition() {
        var model = makeModel(at: CGPoint(x: 1_900, y: 1_000))
        model.updateFramebufferSize(CGSize(width: 1_280, height: 800))

        XCTAssertEqual(model.framebufferSize, CGSize(width: 1_280, height: 800))
        XCTAssertEqual(model.position.x, 1_279, accuracy: 0.0001)
        XCTAssertEqual(model.position.y, 799, accuracy: 0.0001)
    }

    func testEmptyFramebufferKeepsTheCursorAtTheOrigin() {
        var model = TrackpadPointerModel(
            position: CGPoint(x: 400, y: 400),
            framebufferSize: .zero)
        XCTAssertEqual(model.position, .zero)

        model.move(
            by: CGPoint(x: 50, y: 50),
            framebufferPixelsPerPoint: 1,
            velocity: 300)
        XCTAssertEqual(model.position, .zero)
        XCTAssertEqual(model.integerPosition.x, 0)
        XCTAssertEqual(model.integerPosition.y, 0)

        model.updateFramebufferSize(CGSize(width: CGFloat.nan, height: 600))
        XCTAssertEqual(model.framebufferSize, .zero)
    }
}
