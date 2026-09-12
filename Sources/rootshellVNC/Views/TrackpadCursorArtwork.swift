import CoreGraphics
import Foundation
import ImageIO

/// macOS's own cursors, as macOS draws them.
///
/// The server ships its pointer as a 1x bitmap. Scaled onto a 3x phone panel
/// that is a blur, and scaled down for a fitted desktop it is a smear, which is
/// what made the remote screen feel like a screenshot instead of a machine.
/// macOS draws the same cursors from assets it keeps for its own displays:
/// the arrow and the text I-beam as bitmaps at several scales, everything
/// else as a vector PDF with a drop shadow described beside it. Bundling
/// those gives a pointer that is sharp at any size and any zoom, and looks
/// like the Mac's because it is.
///
/// The arrow is a WindowServer asset with no file on disk, captured through
/// `NSCursor.arrow` on a Mac; the I-beam is the same capture. The vectors are
/// HIServices' `Resources/cursors/<name>/cursor.pdf`, re-saved through Quartz
/// to drop the Illustrator payload that was most of each file, with the
/// hotspot and shadow from the `info.plist` next to it. The animated cursors
/// (the wait cursor, the counting hands) are left out. All of it is Apple's
/// design, bundled for a personal build; shipping it further is the
/// maintainer's call.
///
/// Sizes and hotspots are in 1x points on each cursor's own canvas, y down,
/// which is the space the server quotes its hotspot in.
enum TrackpadCursorArtwork {
    struct Shape: Hashable, Sendable, CustomStringConvertible {
        enum Source: Hashable, Sendable {
            /// PNG captures at each of `representationScales`.
            case bitmaps
            /// The vector macOS draws the cursor from, shadow added here.
            case vector
        }

        let name: String
        /// The cursor's own 1x canvas. The arrow's is far larger than the
        /// visible cursor because it also has to hold the drop shadow.
        let canvasSize: CGSize
        /// Hotspot in that same 1x canvas.
        let hotspot: CGPoint
        let source: Source

        var resourceStem: String { "macos-cursor-\(name)" }
        var description: String { name }

        /// macOS's arrow, hotspot on its tip.
        static let arrow = Shape(
            name: "arrow", canvasSize: arrowCanvasSize, hotspot: arrowHotspot,
            source: .bitmaps)
        /// macOS's text I-beam, hotspot at the centre of its stem.
        static let iBeam = Shape(
            name: "ibeam", canvasSize: iBeamCanvasSize, hotspot: iBeamHotspot,
            source: .bitmaps)

        static let bitmapShapes: [Shape] = [arrow, iBeam]

        /// HIServices' static cursors, by their names there.
        static let vectorShapes: [Shape] = [
            vector("cell", 18, 18, 9, 9),
            vector("closedhand", 32, 32, 16, 17),
            vector("contextualmenu", 28, 40, 5, 5),
            vector("copy", 28, 40, 5, 5),
            vector("cross", 24, 24, 11, 11),
            vector("help", 18, 18, 9, 9),
            vector("ibeamvertical", 22, 21, 11, 10),
            vector("makealias", 16, 21, 11, 3),
            vector("move", 24, 24, 12, 12),
            vector("notallowed", 28, 40, 5, 5),
            vector("openhand", 32, 32, 16, 17),
            vector("pointinghand", 32, 32, 13, 8),
            vector("poof", 28, 40, 5, 5),
            vector("resizedown", 24, 24, 12, 11),
            vector("resizeeast", 24, 18, 12, 9),
            vector("resizeeastwest", 24, 18, 12, 9),
            vector("resizeleft", 24, 24, 12, 12),
            vector("resizeleftright", 30, 24, 15, 12),
            vector("resizenorth", 18, 28, 9, 14),
            vector("resizenortheast", 22, 22, 11, 11),
            vector("resizenortheastsouthwest", 22, 22, 11, 11),
            vector("resizenorthsouth", 18, 28, 9, 14),
            vector("resizenorthwest", 22, 22, 11, 11),
            vector("resizenorthwestsoutheast", 22, 22, 11, 11),
            vector("resizeright", 24, 24, 12, 12),
            vector("resizesouth", 18, 28, 9, 14),
            vector("resizesoutheast", 22, 22, 11, 11),
            vector("resizesouthwest", 22, 22, 11, 11),
            vector("resizeup", 24, 24, 12, 13),
            vector("resizeupdown", 24, 28, 12, 14),
            vector("resizewest", 24, 18, 12, 9),
            vector("screenshotselection", 32, 32, 15, 15),
            vector("screenshotwindow", 28, 25, 14, 11),
            vector("zoomin", 28, 26, 12, 11),
            vector("zoomout", 28, 26, 12, 11),
        ]

        static let all: [Shape] = bitmapShapes + vectorShapes

        static func named(_ name: String) -> Shape? {
            all.first { $0.name == name }
        }

        private static func vector(
            _ name: String,
            _ width: CGFloat, _ height: CGFloat,
            _ hotX: CGFloat, _ hotY: CGFloat
        ) -> Shape {
            Shape(
                name: name,
                canvasSize: CGSize(width: width, height: height),
                hotspot: CGPoint(x: hotX, y: hotY),
                source: .vector)
        }
    }

    // MARK: - Arrow

    static let arrowCanvasSize = CGSize(width: 28, height: 40)
    static let arrowHotspot = CGPoint(x: 5, y: 5)
    /// Height of the arrow including its white outline, at 1x. A cursor drawn
    /// this tall is exactly the size macOS draws its own.
    static let nativeArrowHeight: CGFloat = 17.2
    /// Height of the same arrow as the server's cursor record describes it.
    /// That record's alpha covers the drop shadow as well as the outline, so
    /// the silhouette the decoder reports is taller than the cursor looks.
    static let nativeArrowShapeHeight: CGFloat = 22

    // MARK: - I-beam

    static let iBeamCanvasSize = CGSize(width: 23, height: 22)
    static let iBeamHotspot = CGPoint(x: 12, y: 11)

    // MARK: - Vector shadow

    /// What every cursor's `info.plist` asks for: two points of blur, black at
    /// 0.45, one point down. In 1x points, y down.
    static let vectorShadowOffset = CGSize(width: 0, height: 1)
    static let vectorShadowBlur: CGFloat = 2
    static let vectorShadowAlpha: CGFloat = 0.45

    // MARK: - Bitmap representations

    /// The scales macOS keeps the bitmap cursors at, smallest first. 1x is
    /// what the server itself sends and is kept for recognising it.
    static let representationScales: [CGFloat] = [1, 2, 5, 10]

    /// The smallest bundled scale whose canvas is at least `pixelHeight` tall,
    /// so the image is only ever downsampled. Past the largest, that one.
    static func representationScale(
        for shape: Shape, pixelHeight: CGFloat
    ) -> CGFloat {
        let canvasHeight = shape.canvasSize.height
        for scale in representationScales
        where canvasHeight * scale >= pixelHeight {
            return scale
        }
        return representationScales[representationScales.count - 1]
    }

    static func resourceName(for shape: Shape, scale: CGFloat) -> String {
        "\(shape.resourceStem)-\(Int(scale))x"
    }

    // MARK: - Loading

    static func url(for shape: Shape, scale: CGFloat) -> URL? {
        switch shape.source {
        case .bitmaps:
            return url(named: resourceName(for: shape, scale: scale), extension: "png")
        case .vector:
            return url(named: shape.resourceStem, extension: "pdf")
        }
    }

    private static func url(named name: String, extension ext: String) -> URL? {
        // SwiftPM flattens processed resources; Xcode keeps the folder.
        Bundle.module.url(
            forResource: name, withExtension: ext, subdirectory: "Cursors")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }

    /// The cursor rendered for a canvas `pixelHeight` pixels tall: a bitmap
    /// shape as the smallest capture that covers it, a vector shape drawn at
    /// exactly that size.
    static func image(for shape: Shape, pixelHeight: CGFloat) -> CGImage? {
        switch shape.source {
        case .bitmaps:
            let scale = representationScale(for: shape, pixelHeight: pixelHeight)
            guard let url = url(for: shape, scale: scale),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        case .vector:
            return rasterize(shape, scale: pixelHeight / shape.canvasSize.height)
        }
    }

    /// Draws a vector cursor `scale` times its 1x canvas, shadow included,
    /// the way macOS composes it. At 1x the result is pixel for pixel what
    /// macOS sends over VNC.
    static func rasterize(_ shape: Shape, scale: CGFloat) -> CGImage? {
        guard shape.source == .vector, scale > 0, scale.isFinite,
              let url = url(for: shape, scale: 1),
              let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1)
        else { return nil }
        let width = Int((shape.canvasSize.width * scale).rounded())
        let height = Int((shape.canvasSize.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Shadow offset and blur are read in the context's base space: this
        // bitmap's pixel grid, y up, so "one point down" is a negative offset
        // and both figures scale with the drawing.
        context.setShadow(
            offset: CGSize(
                width: vectorShadowOffset.width * scale,
                height: -vectorShadowOffset.height * scale),
            blur: vectorShadowBlur * scale,
            color: CGColor(gray: 0, alpha: vectorShadowAlpha))
        // One shadow under the whole cursor, not one under each of its
        // subpaths: the white border must not shade the black fill.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        context.endTransparencyLayer()
        return context.makeImage()
    }

    // MARK: - Pixels

    /// Alpha above which a pixel counts as the cursor rather than its shadow.
    /// macOS's shadows peak at 0.45, so a half is safely above them and
    /// safely below any outline pixel.
    static let solidAlpha: UInt8 = 127

    /// `image` fitted to `size`, as premultiplied RGBA bytes, four per pixel,
    /// rows top down. An image larger than `size` is downsampled on the way
    /// in, which is how a 2x capture yields the 1x picture the server sends.
    static func pixels(of image: CGImage, size: CGSize) -> [UInt8] {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return [] }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.interpolationQuality = .high
            context.draw(
                image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// A bundled cursor at 1x, as the server would send it.
    static func pixels(for shape: Shape) -> [UInt8]? {
        guard let image = image(for: shape, pixelHeight: shape.canvasSize.height)
        else { return nil }
        return pixels(of: image, size: shape.canvasSize)
    }

    // MARK: - Sizing

    /// Factor that draws a cursor `cursorHeight` points tall.
    static func scale(cursorHeight: CGFloat) -> CGFloat {
        TrackpadCursorStyle.resolvedCursorHeight(cursorHeight)
            / nativeArrowHeight
    }
}
