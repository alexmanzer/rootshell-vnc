import CoreGraphics
import Foundation

/// Recognises the cursor bitmap a server sends as one of the bundled macOS
/// cursors.
///
/// macOS sends its system cursors over VNC as the 1x rendering of the very
/// assets bundled here, canvas and hotspot included. Recognition is therefore
/// a comparison of pictures: the same canvas, the same hotspot, and pixels
/// that agree closely enough that anti-aliasing is the only difference. The
/// colours matter as much as the silhouette: the copy, not-allowed and poof
/// cursors are the arrow with the same round badge in different colours, and
/// the two zoom cursors differ only by the sign inside the lens.
///
/// Reference pictures are rendered on first use and kept, so the cost of a
/// new shape is one small raster per candidate that shares its canvas.
final class TrackpadCursorMatcher {
    struct Match: Equatable {
        let shape: TrackpadCursorArtwork.Shape
        /// Share of the pixels either picture covers on which both agree,
        /// 0…1.
        let similarity: Double
    }

    /// Below this two pictures are different cursors. Cursors that share a
    /// canvas and hotspot differ by a badge, an arrowhead or a sign, each of
    /// them well over a tenth of the picture, while anti-aliasing moves a
    /// handful of edge pixels; the bar sits between.
    static let minimumSimilarity: Double = 0.8
    /// Largest difference in any channel of premultiplied RGBA under which two
    /// pixels are the same pixel drawn twice rather than two colours.
    static let channelTolerance: UInt8 = 64

    private var references: [TrackpadCursorArtwork.Shape: [UInt8]?] = [:]

    init() {}

    /// The bundled cursor `image` is, if it is one.
    func match(_ image: CGImage, hotspot: CGPoint) -> Match? {
        guard let closest = closest(to: image, hotspot: hotspot),
              closest.similarity >= Self.minimumSimilarity
        else { return nil }
        return closest
    }

    /// The best candidate whatever its similarity, for telling how near a
    /// miss was. Nil when nothing bundled shares the canvas and hotspot.
    func closest(to image: CGImage, hotspot: CGPoint) -> Match? {
        let size = CGSize(width: image.width, height: image.height)
        let candidates = TrackpadCursorArtwork.Shape.all.filter {
            $0.canvasSize == size && $0.hotspot == hotspot
        }
        guard !candidates.isEmpty else { return nil }
        let sample = TrackpadCursorArtwork.pixels(of: image, size: size)
        var best: Match?
        for shape in candidates {
            guard let reference = reference(for: shape) else { continue }
            let similarity = Self.similarity(sample, reference)
            if similarity > (best?.similarity ?? -1) {
                best = Match(shape: shape, similarity: similarity)
            }
        }
        return best
    }

    private func reference(for shape: TrackpadCursorArtwork.Shape) -> [UInt8]? {
        if let cached = references[shape] { return cached }
        let pixels = TrackpadCursorArtwork.pixels(for: shape)
        references[shape] = pixels
        return pixels
    }

    /// Of the pixels that are solid in either picture, the share that are
    /// solid in both and the same colour within `channelTolerance`. Two empty
    /// pictures are not a match: there is nothing to have matched.
    static func similarity(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, a.count % 4 == 0, !a.isEmpty else { return 0 }
        let solid = TrackpadCursorArtwork.solidAlpha
        var agreeing = 0
        var covered = 0
        var index = 0
        while index < a.count {
            let alphaA = a[index + 3]
            let alphaB = b[index + 3]
            let solidA = alphaA > solid
            let solidB = alphaB > solid
            if solidA || solidB {
                covered += 1
                if solidA && solidB && samePixel(a, b, at: index) {
                    agreeing += 1
                }
            }
            index += 4
        }
        guard covered > 0 else { return 0 }
        return Double(agreeing) / Double(covered)
    }

    private static func samePixel(_ a: [UInt8], _ b: [UInt8], at index: Int) -> Bool {
        for channel in 0..<4 {
            let difference = a[index + channel] > b[index + channel]
                ? a[index + channel] - b[index + channel]
                : b[index + channel] - a[index + channel]
            if difference > channelTolerance { return false }
        }
        return true
    }
}
