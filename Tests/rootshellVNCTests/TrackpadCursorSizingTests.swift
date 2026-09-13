import CoreGraphics
import XCTest
@testable import rootshellVNC

final class TrackpadCursorSizingTests: XCTestCase {
    func testRemoteArtworkAlwaysWinsOverFallback() {
        for presence in [RemoteCursorPresence.undescribed, .described] {
            for allowFallback in [false, true] {
                XCTAssertEqual(TrackpadCursorStyle.resolve(
                    hasServerCursor: true, presence: presence,
                    allowingFallback: allowFallback, serverRendersCursor: false), .serverBitmap)
            }
        }
    }

    func testFallbackOnlyBeforeFirstDescriptionInRelativeMode() {
        XCTAssertEqual(TrackpadCursorStyle.resolve(
            hasServerCursor: false, presence: .undescribed,
            allowingFallback: true, serverRendersCursor: false), .fallbackArrow)
        for presence in RemoteCursorPresence.allCases {
            XCTAssertEqual(TrackpadCursorStyle.resolve(
                hasServerCursor: false, presence: presence,
                allowingFallback: false, serverRendersCursor: false), .hidden)
        }
        XCTAssertEqual(TrackpadCursorStyle.resolve(
            hasServerCursor: false, presence: .described,
            allowingFallback: true, serverRendersCursor: false), .hidden)
    }

    func testExplicitHideAndEmbeddedCursorSuppressEveryOverlay() {
        for hasCursor in [false, true] {
            XCTAssertEqual(TrackpadCursorStyle.resolve(
                hasServerCursor: hasCursor, presence: .hidden,
                allowingFallback: true, serverRendersCursor: false), .hidden)
            for presence in RemoteCursorPresence.allCases {
                XCTAssertEqual(TrackpadCursorStyle.resolve(
                    hasServerCursor: hasCursor, presence: presence,
                    allowingFallback: true, serverRendersCursor: true), .hidden)
            }
        }
    }

    func testUniformBitmapScalePreservesServerSizesAndHotspots() {
        XCTAssertEqual(TrackpadCursorStyle.bitmapScale(cursorHeight: 17), 1)
        let scale = TrackpadCursorStyle.bitmapScale(cursorHeight: 34)
        XCTAssertEqual(scale, 2)
        // A short resize bar stays short; its hotspot tracks the same transform.
        XCTAssertEqual(CGSize(width: 32 * scale, height: 8 * scale), CGSize(width: 64, height: 16))
        XCTAssertEqual(CGPoint(x: 16 * scale, y: 4 * scale), CGPoint(x: 32, y: 8))
    }

    func testSizePreferenceClampsAndRejectsNonFiniteValues() {
        XCTAssertEqual(TrackpadCursorStyle.resolvedCursorHeight(1), 8)
        XCTAssertEqual(TrackpadCursorStyle.resolvedCursorHeight(1000), 64)
        for value in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertEqual(TrackpadCursorStyle.resolvedCursorHeight(value), 17)
        }
    }
}
