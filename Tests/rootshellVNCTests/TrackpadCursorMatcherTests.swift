import CoreGraphics
import XCTest
@testable import rootshellVNC

/// The matcher is fed what macOS sends over VNC: the 1x rendering of the same
/// assets that are bundled. These tests feed it exactly that, then the near
/// misses it must tell apart.
final class TrackpadCursorMatcherTests: XCTestCase {
    private typealias Artwork = TrackpadCursorArtwork

    func testEveryBundledCursorIsRecognisedFromItsOwnServerSizedRendering() throws {
        let matcher = TrackpadCursorMatcher()
        for shape in Artwork.Shape.all {
            let image = try XCTUnwrap(Self.serverImage(of: shape), shape.name)
            let match = try XCTUnwrap(
                matcher.match(image, hotspot: shape.hotspot), shape.name)
            XCTAssertEqual(
                match.shape, shape,
                "\(shape.name) was taken for \(match.shape.name)")
            XCTAssertGreaterThan(match.similarity, 0.99, shape.name)
        }
    }

    func testCursorsThatDifferBySilhouetteStayUnderTheBar() throws {
        // The arrow's badged variants add a badge to it; the hands differ by
        // their fingers; the cell cross and the help mark share nothing but a
        // canvas. A shape this far from another must not be accepted as it.
        let pairs = [
            ("arrow", "copy"), ("arrow", "notallowed"), ("arrow", "poof"),
            ("arrow", "contextualmenu"), ("openhand", "closedhand"),
            ("cell", "help"),
        ]
        for (first, second) in pairs {
            XCTAssertLessThan(
                try Self.similarity(first, second),
                TrackpadCursorMatcher.minimumSimilarity,
                "\(first) vs \(second)")
        }
    }

    func testCursorsThatDifferOnlyByColourOrASignAreStillTwoCursors() throws {
        // Copy, not-allowed and poof share one silhouette: the arrow with a
        // round badge, in green, red and grey. Zoom in and out differ by the
        // sign in the lens; the resize pairs by one arrowhead. Silhouettes
        // alone called several of these identical.
        let pairs = [
            ("copy", "notallowed"), ("copy", "poof"), ("notallowed", "poof"),
            ("zoomin", "zoomout"), ("resizenorth", "resizenorthsouth"),
            ("resizeeast", "resizeeastwest"),
            ("resizenortheast", "resizenortheastsouthwest"),
        ]
        for (first, second) in pairs {
            XCTAssertLessThan(
                try Self.similarity(first, second), 0.98,
                "\(first) vs \(second)")
        }
    }

    func testAntialiasingDifferencesAreTolerated() throws {
        // A server that rasterises the same vector slightly differently
        // yields edge pixels that disagree. Rendering at 2x and averaging
        // down is a harsher version of that, and still has to match.
        let matcher = TrackpadCursorMatcher()
        for name in ["resizeleftright", "pointinghand", "cross", "ibeamvertical"] {
            let shape = try XCTUnwrap(Artwork.Shape.named(name))
            let twox = try XCTUnwrap(Artwork.rasterize(shape, scale: 2))
            let onex = try XCTUnwrap(Self.downsampled(twox, to: shape.canvasSize))
            let match = try XCTUnwrap(matcher.match(onex, hotspot: shape.hotspot), name)
            XCTAssertEqual(match.shape, shape, name)
        }
    }

    func testAnotherCanvasOrHotspotIsNeverAMatch() throws {
        let matcher = TrackpadCursorMatcher()
        let arrow = try XCTUnwrap(Self.serverImage(of: .arrow))
        XCTAssertNil(matcher.match(arrow, hotspot: CGPoint(x: 6, y: 5)))
        XCTAssertNil(matcher.closest(to: arrow, hotspot: CGPoint(x: 6, y: 5)))
        // A Linux arrow on a canvas macOS never uses.
        let foreign = try XCTUnwrap(Self.blankImage(width: 20, height: 20))
        XCTAssertNil(matcher.closest(to: foreign, hotspot: .zero))
    }

    func testEmptyCursorOnAKnownCanvasIsNotAMatch() throws {
        let matcher = TrackpadCursorMatcher()
        let blank = try XCTUnwrap(Self.blankImage(width: 30, height: 24))
        let closest = try XCTUnwrap(
            matcher.closest(to: blank, hotspot: CGPoint(x: 15, y: 12)))
        XCTAssertEqual(closest.similarity, 0)
        XCTAssertNil(matcher.match(blank, hotspot: CGPoint(x: 15, y: 12)))
    }

    func testSimilarityIsAgreementOverCoverage() {
        let black: [UInt8] = [0, 0, 0, 255]
        let white: [UInt8] = [255, 255, 255, 255]
        let nearlyBlack: [UInt8] = [40, 40, 40, 255]
        let clear: [UInt8] = [0, 0, 0, 0]
        // Four pixels: agree, disagree in colour, one-sided, neither.
        let a = black + black + black + clear
        let b = nearlyBlack + white + clear + clear
        XCTAssertEqual(
            TrackpadCursorMatcher.similarity(a, b), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(TrackpadCursorMatcher.similarity(clear, clear), 0)
        XCTAssertEqual(TrackpadCursorMatcher.similarity(black, black + black), 0)
        XCTAssertEqual(TrackpadCursorMatcher.similarity([], []), 0)
    }

    // MARK: - Fixtures

    private static func similarity(_ first: String, _ second: String) throws -> Double {
        let a = try XCTUnwrap(Artwork.pixels(for: XCTUnwrap(Artwork.Shape.named(first))))
        let b = try XCTUnwrap(Artwork.pixels(for: XCTUnwrap(Artwork.Shape.named(second))))
        return TrackpadCursorMatcher.similarity(a, b)
    }

    /// The cursor as the server sends it: the 1x canvas.
    private static func serverImage(of shape: Artwork.Shape) -> CGImage? {
        Artwork.image(for: shape, pixelHeight: shape.canvasSize.height)
    }

    private static func blankImage(width: Int, height: Int) -> CGImage? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }

    private static func downsampled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
