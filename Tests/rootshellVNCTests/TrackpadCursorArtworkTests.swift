import CoreGraphics
import XCTest
@testable import rootshellVNC

/// Guards the bundled macOS cursors: that they ship, that they are the sizes
/// macOS keeps them at, that a bitmap picked for a pixel height is only ever
/// shrunk, and that the artwork is the pointer the sizing arithmetic assumes.
final class TrackpadCursorArtworkTests: XCTestCase {
    private typealias Artwork = TrackpadCursorArtwork

    func testEveryBitmapShapeShipsAtEveryScaleAtItsCanvasSize() throws {
        for shape in Artwork.Shape.bitmapShapes {
            for scale in Artwork.representationScales {
                let image = try XCTUnwrap(
                    Artwork.image(
                        for: shape,
                        pixelHeight: shape.canvasSize.height * scale),
                    "\(shape) at \(scale)x")
                XCTAssertEqual(
                    CGFloat(image.width), shape.canvasSize.width * scale,
                    "\(shape) at \(scale)x")
                XCTAssertEqual(
                    CGFloat(image.height), shape.canvasSize.height * scale,
                    "\(shape) at \(scale)x")
            }
        }
    }

    func testEveryVectorShapeShipsOnItsDeclaredCanvas() throws {
        for shape in Artwork.Shape.vectorShapes {
            let url = try XCTUnwrap(Artwork.url(for: shape, scale: 1), shape.name)
            let document = try XCTUnwrap(CGPDFDocument(url as CFURL), shape.name)
            let page = try XCTUnwrap(document.page(at: 1), shape.name)
            let box = page.getBoxRect(.mediaBox)
            XCTAssertEqual(box.origin, .zero, shape.name)
            XCTAssertEqual(box.size, shape.canvasSize, shape.name)
            XCTAssertTrue(
                CGRect(origin: .zero, size: shape.canvasSize)
                    .contains(shape.hotspot),
                "\(shape.name) hotspot \(shape.hotspot)")
        }
    }

    func testShapeNamesAreUniqueAndLookedUpByName() {
        let names = Artwork.Shape.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Artwork.Shape.named("arrow"), .arrow)
        XCTAssertEqual(
            Artwork.Shape.named("resizeleftright")?.canvasSize,
            CGSize(width: 30, height: 24))
        XCTAssertNil(Artwork.Shape.named("busybutclickable"))
    }

    func testVectorShapeRasterizesAtTheRequestedSizeWithItsShadow() throws {
        let shape = try XCTUnwrap(Artwork.Shape.named("resizeleftright"))
        let onex = try XCTUnwrap(
            Artwork.image(for: shape, pixelHeight: shape.canvasSize.height))
        XCTAssertEqual(onex.width, 30)
        XCTAssertEqual(onex.height, 24)
        let threex = try XCTUnwrap(Artwork.image(for: shape, pixelHeight: 72))
        XCTAssertEqual(threex.width, 90)
        XCTAssertEqual(threex.height, 72)
        // The shadow macOS composes under the vector falls straight down.
        let solid = try XCTUnwrap(Self.bounds(of: threex, alphaAbove: 0.5))
        let shadow = try XCTUnwrap(Self.bounds(of: threex, alphaAbove: 0.02))
        XCTAssertGreaterThan(shadow.maxY, solid.maxY)
        XCTAssertEqual(shadow.minY, solid.minY, accuracy: 1)
    }

    func testRepresentationIsTheSmallestThatIsNotStretched() {
        // A 17 pt arrow on a 3x panel wants a 119 px canvas: 2x (80 px) would
        // be stretched, 5x (200 px) is the first that only shrinks.
        XCTAssertEqual(
            Artwork.representationScale(for: .arrow, pixelHeight: 119), 5)
        XCTAssertEqual(
            Artwork.representationScale(for: .arrow, pixelHeight: 80), 2)
        XCTAssertEqual(
            Artwork.representationScale(for: .arrow, pixelHeight: 81), 5)
        XCTAssertEqual(
            Artwork.representationScale(for: .arrow, pixelHeight: 201), 10)
        // The server's own size, and anything smaller, is the 1x capture.
        XCTAssertEqual(
            Artwork.representationScale(for: .arrow, pixelHeight: 40), 1)
        // Past the largest macOS keeps, the largest is all there is.
        XCTAssertEqual(
            Artwork.representationScale(for: .arrow, pixelHeight: 1_000), 10)
        XCTAssertEqual(
            Artwork.representationScale(for: .iBeam, pixelHeight: 100), 5)
    }

    func testArrowArtworkIsTheHeightTheScaleAssumes() throws {
        // `scale(cursorHeight:)` divides by the arrow's outlined height at 1x.
        // Artwork drawn to another size would silently put every Cursor Size
        // preset off by the same factor.
        let image = try XCTUnwrap(Artwork.image(for: .arrow, pixelHeight: 400))
        let solid = try XCTUnwrap(Self.bounds(of: image, alphaAbove: 0.6))
        XCTAssertEqual(
            solid.height / 10, Artwork.nativeArrowHeight, accuracy: 0.6)
        // The hotspot is the tip: on the black inside the white outline, a
        // point in from the solid shape's top-left corner.
        let hotspot = Artwork.arrowHotspot
        XCTAssertEqual(hotspot.x, solid.minX / 10 + 1, accuracy: 0.7)
        XCTAssertEqual(hotspot.y, solid.minY / 10 + 1.5, accuracy: 0.7)
    }

    func testArrowArtworkLeavesRoomForItsShadow() throws {
        // The canvas is 28x40 for a 10x17 cursor because the shadow falls
        // below and to the right. Artwork cropped to the silhouette would
        // clip the shadow as soon as it was scaled.
        let image = try XCTUnwrap(Artwork.image(for: .arrow, pixelHeight: 400))
        let solid = try XCTUnwrap(Self.bounds(of: image, alphaAbove: 0.6))
        let shadow = try XCTUnwrap(Self.bounds(of: image, alphaAbove: 0.02))
        XCTAssertGreaterThan(shadow.maxY, solid.maxY)
        XCTAssertGreaterThan(shadow.maxX, solid.maxX)
        XCTAssertLessThan(shadow.maxY, CGFloat(image.height))
        XCTAssertLessThan(shadow.maxX, CGFloat(image.width))
    }

    func testIBeamArtworkIsCentredOnItsHotspot() throws {
        let image = try XCTUnwrap(Artwork.image(for: .iBeam, pixelHeight: 220))
        let solid = try XCTUnwrap(Self.bounds(of: image, alphaAbove: 0.6))
        let hotspot = Artwork.iBeamHotspot
        // Vertically the hotspot is the exact middle of the stem.
        XCTAssertEqual(solid.midY / 10, hotspot.y, accuracy: 0.3)
        // macOS quotes the hotspot in whole pixels while the artwork sits on
        // a fractional centre line, so horizontally it is half a point off.
        XCTAssertEqual(solid.midX / 10, hotspot.x, accuracy: 0.6)
        XCTAssertEqual(solid.height / 10, 18.6, accuracy: 0.5)
    }

    func testScaleDrawsTheNativeSizeAtTheNativeHeight() {
        XCTAssertEqual(
            Artwork.scale(cursorHeight: Artwork.nativeArrowHeight),
            1,
            accuracy: 0.0001)
        XCTAssertEqual(Artwork.scale(cursorHeight: 34.4), 2, accuracy: 0.0001)
    }

    func testArtworkAndBitmapShapesAgreeOnScaleAgainstMacOS() {
        // A shape drawn from artwork and one kept as the server's pixels must
        // come out the same size, or the pointer changes scale as it crosses a
        // text field.
        let artwork = Artwork.scale(cursorHeight: 17.2)
        let bitmap = TrackpadCursorStyle.bitmapScale(
            cursorHeight: 17.2,
            referenceArrowHeight: Artwork.nativeArrowShapeHeight)
        XCTAssertEqual(artwork, bitmap, accuracy: 0.0001)
        XCTAssertEqual(artwork, 1, accuracy: 0.0001)
    }

    func testStyleNamesTheArtworkItDraws() throws {
        XCTAssertEqual(TrackpadCursorStyle.nativeArrow.artwork, .arrow)
        XCTAssertEqual(TrackpadCursorStyle.nativeIBeam.artwork, .iBeam)
        XCTAssertEqual(TrackpadCursorStyle.nativeArrow, .native(.arrow))
        let hand = try XCTUnwrap(Artwork.Shape.named("pointinghand"))
        XCTAssertEqual(TrackpadCursorStyle.native(hand).artwork, hand)
        XCTAssertEqual("\(TrackpadCursorStyle.native(hand))", "native(pointinghand)")
        XCTAssertNil(TrackpadCursorStyle.serverBitmap.artwork)
    }

    // MARK: - Pixel access

    /// Bounding box, in canvas pixels with y down, of every pixel whose
    /// alpha exceeds `threshold`.
    static func bounds(
        of image: CGImage, alphaAbove threshold: CGFloat
    ) -> CGRect? {
        let width = image.width
        let height = image.height
        var coverage = [UInt8](repeating: 0, count: width * height)
        let drawn = coverage.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            context.draw(
                image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let cutoff = UInt8(min(255, max(0, threshold * 255)))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where coverage[y * width + x] > cutoff {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // A bitmap context's first row in memory is the top of the picture,
        // so the row index already is the canvas's y-down coordinate.
        return CGRect(
            x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
