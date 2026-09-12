import CoreGraphics
import XCTest
@testable import rootshellVNC

final class TrackpadCursorSizingTests: XCTestCase {
    func testRequestedHeightIsUsedWhenItIsSane() {
        XCTAssertEqual(
            TrackpadCursorStyle.resolvedCursorHeight(16), 16, accuracy: 0.0001)
        XCTAssertEqual(
            TrackpadCursorStyle.resolvedCursorHeight(24), 24, accuracy: 0.0001)
    }

    func testRequestedHeightIsClampedAndNonFiniteFallsBack() {
        XCTAssertEqual(
            TrackpadCursorStyle.resolvedCursorHeight(1),
            TrackpadCursorStyle.minimumCursorHeight,
            accuracy: 0.0001)
        XCTAssertEqual(
            TrackpadCursorStyle.resolvedCursorHeight(1_000),
            TrackpadCursorStyle.maximumCursorHeight,
            accuracy: 0.0001)
        XCTAssertEqual(
            TrackpadCursorStyle.resolvedCursorHeight(.nan),
            TrackpadCursorStyle.defaultCursorHeight,
            accuracy: 0.0001)
    }

    func testBitmapScaleMakesTheServersOwnArrowTheRequestedHeight() {
        // The silhouette the server describes is 22 px tall but the arrow it
        // draws is 17.2 pt: the rest is drop shadow. A 16 pt cursor therefore
        // scales every bitmap shape by 16/17.2, not 16/22.
        let scale = TrackpadCursorStyle.bitmapScale(
            cursorHeight: 16, referenceArrowHeight: 22)
        XCTAssertEqual(
            scale, 16 / TrackpadCursorArtwork.nativeArrowHeight, accuracy: 0.0001)
    }

    func testBitmapScaleKeepsShapesInProportionToEachOther() {
        // A wide resize bar and a tall arrow share one factor, so the bar stays
        // short instead of being stretched to the arrow's height.
        let scale = TrackpadCursorStyle.bitmapScale(
            cursorHeight: 16, referenceArrowHeight: 22)
        let resizeBar = CGSize(width: 32, height: 12)
        // The bar is shorter than a cursor height because macOS draws it
        // that way; one shared factor is what preserves that.
        XCTAssertLessThan(resizeBar.height * scale, 16)
        XCTAssertGreaterThan(resizeBar.width * scale, 16)
    }

    func testBitmapScaleFallsBackWhenNoArrowHasBeenMeasured() {
        XCTAssertEqual(
            TrackpadCursorStyle.bitmapScale(
                cursorHeight: 16,
                referenceArrowHeight: TrackpadCursorStyle.fallbackArrowHeight),
            TrackpadCursorStyle.bitmapScale(
                cursorHeight: 16, referenceArrowHeight: 0),
            accuracy: 0.0001)
        XCTAssertEqual(
            TrackpadCursorStyle.bitmapScale(
                cursorHeight: 16, referenceArrowHeight: .nan),
            16 / TrackpadCursorArtwork.nativeArrowHeight,
            accuracy: 0.0001)
    }

    func testBitmapScaleIsClampedAtBothEnds() {
        XCTAssertEqual(
            TrackpadCursorStyle.bitmapScale(
                cursorHeight: 64, referenceArrowHeight: 2),
            TrackpadCursorStyle.maximumBitmapScale,
            accuracy: 0.0001)
        XCTAssertEqual(
            TrackpadCursorStyle.bitmapScale(
                cursorHeight: 8, referenceArrowHeight: 10_000),
            TrackpadCursorStyle.minimumBitmapScale,
            accuracy: 0.0001)
    }

    func testAnUnrecognisedCursorKeepsTheServersPixels() {
        // Recognition is the matcher's job and it is exact; no shape is drawn
        // as macOS's arrow on the strength of its outline alone.
        XCTAssertNil(TrackpadCursorStyle.serverBitmap.artwork)
        XCTAssertEqual(TrackpadCursorStyle.nativeArrow.artwork, .arrow)
        XCTAssertEqual(TrackpadCursorStyle.nativeIBeam.artwork, .iBeam)
    }
}
