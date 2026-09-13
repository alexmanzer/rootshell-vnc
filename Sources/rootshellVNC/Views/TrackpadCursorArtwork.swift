import CoreGraphics
import Foundation

/// Original rootshellVNC artwork, licensed under the repository's MIT license.
/// These paths were drawn for this project, without extracting or tracing OS assets.
/// The app uses the arrow only before the server supplies a cursor. The caret is
/// available for local UI; received remote shapes are always rendered unchanged.
enum TrackpadCursorArtwork {
    enum Shape: String, CaseIterable, Sendable {
        case arrow
        case caret

        var canvasSize: CGSize { CGSize(width: 28, height: 32) }
        /// Coordinates use a top-left origin.
        var hotspot: CGPoint {
            switch self {
            case .arrow: return CGPoint(x: 4, y: 3)
            case .caret: return CGPoint(x: 14, y: 16)
            }
        }

        var path: CGPath {
            let path = CGMutablePath()
            switch self {
            case .arrow:
                // A slightly leaning pointer with a broad shoulder and tapered tail.
                path.move(to: CGPoint(x: 4, y: 3))
                for point in [
                    CGPoint(x: 7, y: 24), CGPoint(x: 11.2, y: 19.4),
                    CGPoint(x: 15.7, y: 27.2), CGPoint(x: 19.6, y: 24.9),
                    CGPoint(x: 15.2, y: 17.4), CGPoint(x: 22, y: 16.3),
                ] { path.addLine(to: point) }
                path.closeSubpath()
            case .caret:
                // Paired, shallow curved serifs keep the insertion point legible.
                path.move(to: CGPoint(x: 9, y: 5))
                path.addQuadCurve(to: CGPoint(x: 14, y: 7), control: CGPoint(x: 14, y: 5))
                path.addQuadCurve(to: CGPoint(x: 19, y: 5), control: CGPoint(x: 14, y: 5))
                path.move(to: CGPoint(x: 14, y: 7))
                path.addLine(to: CGPoint(x: 14, y: 25))
                path.move(to: CGPoint(x: 9, y: 27))
                path.addQuadCurve(to: CGPoint(x: 14, y: 25), control: CGPoint(x: 14, y: 27))
                path.addQuadCurve(to: CGPoint(x: 19, y: 27), control: CGPoint(x: 14, y: 27))
            }
            return path
        }

        var outlineWidth: CGFloat { self == .arrow ? 1.5 : 4.2 }
        var visibleHeight: CGFloat { path.boundingBoxOfPath.height + outlineWidth }
    }

    static let ink = CGColor(srgbRed: 24 / 255, green: 33 / 255, blue: 43 / 255, alpha: 1)

    /// Renders the vector directly at the destination pixel density. No fixed
    /// resolution asset is enlarged, and all zoom levels share the same geometry.
    static func image(for shape: Shape, pixelHeight: CGFloat) -> CGImage? {
        guard pixelHeight.isFinite, pixelHeight > 0, pixelHeight <= 4096 else { return nil }
        let scale = pixelHeight / shape.canvasSize.height
        let width = Int(ceil(shape.canvasSize.width * scale))
        let height = Int(ceil(pixelHeight))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setShadow(
            offset: CGSize(width: 0, height: -0.8 * scale), blur: 0.9 * scale,
            color: CGColor(gray: 0, alpha: 0.28))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(shape.outlineWidth)
        context.addPath(shape.path)
        if shape == .arrow {
            context.setFillColor(ink)
            context.drawPath(using: .fillStroke)
        } else {
            context.strokePath()
            context.addPath(shape.path)
            context.setStrokeColor(ink)
            context.setLineWidth(1.8)
            context.strokePath()
        }
        context.endTransparencyLayer()
        return context.makeImage()
    }
}
