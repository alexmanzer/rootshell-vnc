import CoreGraphics
import XCTest
@testable import rootshellVNC

final class RemoteViewportStateTests: XCTestCase {
    private let viewSize = CGSize(width: 1000, height: 1000)
    private let framebufferSize = CGSize(width: 1920, height: 1080)

    func testAspectFitCoordinateMapping() throws {
        let viewport = RemoteViewportState()
        let frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))

        XCTAssertEqual(frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 218.75, accuracy: 0.001)
        XCTAssertEqual(frame.width, 1000, accuracy: 0.001)
        XCTAssertEqual(frame.height, 562.5, accuracy: 0.001)

        let center = try XCTUnwrap(viewport.framebufferPoint(
            for: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(center.x, 960, accuracy: 0.001)
        XCTAssertEqual(center.y, 540, accuracy: 0.001)
        XCTAssertNil(viewport.framebufferPoint(
            for: CGPoint(x: 500, y: 100),
            viewSize: viewSize,
            framebufferSize: framebufferSize))
    }

    func testPinchKeepsRemotePixelUnderAnchor() throws {
        var viewport = RemoteViewportState()
        // Keep the requested offset within the pan bounds so clamping does
        // not intentionally move the anchor.
        let anchor = CGPoint(x: 250, y: 470)
        let before = try XCTUnwrap(viewport.framebufferPoint(
            for: anchor,
            viewSize: viewSize,
            framebufferSize: framebufferSize))

        viewport.zoom(
            by: 2,
            around: anchor,
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let after = try XCTUnwrap(viewport.framebufferPoint(
            for: anchor,
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(viewport.scale, 2, accuracy: 0.001)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
    }

    func testPanAllowsDesktopEdgesToReachViewportCenter() throws {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        viewport.pan(
            by: CGSize(width: 10_000, height: 10_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        XCTAssertEqual(viewport.offset.width, 1_000, accuracy: 0.001)
        XCTAssertEqual(viewport.offset.height, 562.5, accuracy: 0.001)

        var frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(frame.minX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.minY, viewSize.height / 2, accuracy: 0.001)

        viewport.pan(
            by: CGSize(width: -20_000, height: -20_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        XCTAssertEqual(viewport.offset.width, -1_000, accuracy: 0.001)
        XCTAssertEqual(viewport.offset.height, -562.5, accuracy: 0.001)
        frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(frame.maxX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, viewSize.height / 2, accuracy: 0.001)

        viewport.reset()
        XCTAssertTrue(viewport.isIdentity)
    }

    func testAspectFitDesktopCanUseHalfViewportMargin() throws {
        var viewport = RemoteViewportState()
        viewport.pan(
            by: CGSize(width: 10_000, height: 10_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(frame.minX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.minY, viewSize.height / 2, accuracy: 0.001)
    }

    func testPinchingInAtMinimumScaleRecentersDesktop() {
        var viewport = RemoteViewportState()
        viewport.pan(
            by: CGSize(width: 10_000, height: 10_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertFalse(viewport.isIdentity)

        viewport.zoom(
            by: 0.5,
            around: CGPoint(x: 900, y: 100),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        XCTAssertTrue(viewport.isIdentity)
    }

    func testPinchingDownToMinimumScaleRecentersDesktop() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 4,
            around: CGPoint(x: 250, y: 750),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        viewport.pan(
            by: CGSize(width: 300, height: -200),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        viewport.zoom(
            by: 0.01,
            around: CGPoint(x: 900, y: 100),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        XCTAssertTrue(viewport.isIdentity)
    }

    func testScaleIsBounded() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 100,
            around: .zero,
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(viewport.scale, RemoteViewportState.maximumScale)
        XCTAssertEqual(viewport.scale, 10)

        viewport.zoom(
            by: 0.001,
            around: .zero,
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(viewport.scale, RemoteViewportState.minimumScale)
    }
}
