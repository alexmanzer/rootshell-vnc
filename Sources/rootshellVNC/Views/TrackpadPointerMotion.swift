import CoreGraphics
import Foundation

/// Finger speed in view points per second, derived from the touch callbacks
/// themselves rather than from a recognizer's own velocity reading.
///
/// `TrackpadPointerModel` picks a point on its acceleration curve from this
/// number, so the figure has to be stable: a raw per-callback quotient swings
/// wildly because UIKit does not deliver touches on an even cadence, and every
/// swing becomes a visible change in cursor gain within a single stroke. A
/// light exponential average keeps the curve tracking the stroke instead of
/// the delivery schedule, while still reacting inside a few frames.
///
/// Intervals are floored rather than discarded: two callbacks a microsecond
/// apart would otherwise divide by nearly zero and report a flick the finger
/// never made.
struct TrackpadVelocityEstimator: Equatable, Sendable {
    /// Weight of the newest sample in the running average. Low enough to
    /// absorb cadence jitter, high enough that a deliberate acceleration is
    /// honoured within roughly three touch callbacks.
    static let smoothingFactor: CGFloat = 0.4
    /// Shortest interval treated as real elapsed time, in seconds.
    static let minimumInterval: Double = 0.001

    private(set) var velocity: CGFloat = 0
    private var lastTimestamp: Double?

    /// Folds one translation delta into the average and returns the speed to
    /// use for it. The first sample of a stroke has no interval to measure, so
    /// it reports zero: the opening motion is deliberately unaccelerated.
    @discardableResult
    mutating func record(
        translation: CGPoint,
        at timestamp: Double
    ) -> CGFloat {
        guard translation.x.isFinite, translation.y.isFinite,
              timestamp.isFinite else { return velocity }
        defer { lastTimestamp = timestamp }
        guard let lastTimestamp else { return velocity }

        let interval = max(timestamp - lastTimestamp, Self.minimumInterval)
        let sample = hypot(translation.x, translation.y) / CGFloat(interval)
        velocity += (sample - velocity) * Self.smoothingFactor
        return velocity
    }

    mutating func reset() {
        velocity = 0
        lastTimestamp = nil
    }
}

/// Converts a pane-local framebuffer coordinate into the coordinate the RFB
/// pointer event carries.
///
/// A pane shows one display out of a possibly larger server framebuffer, so
/// every position the viewport produces is local to that display and has to be
/// shifted by the pane's origin before it goes on the wire. This mirrors the
/// clamping the touch path applies, so a virtual cursor and a finger address
/// the same pixel.
enum TrackpadPointerWire {
    static func wirePoint(
        framebufferPoint point: (x: UInt16, y: UInt16),
        origin: CGPoint
    ) -> (x: UInt16, y: UInt16) {
        (coordinate(CGFloat(point.x) + origin.x),
         coordinate(CGFloat(point.y) + origin.y))
    }

    /// Inverse of `wirePoint`, used to seed a cursor from the last position
    /// the pane sent. Returns a fractional point because the model clamps and
    /// rounds it itself.
    static func framebufferPoint(
        wirePoint point: (x: UInt16, y: UInt16),
        origin: CGPoint
    ) -> CGPoint {
        guard origin.x.isFinite, origin.y.isFinite else {
            return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
        return CGPoint(
            x: CGFloat(point.x) - origin.x,
            y: CGFloat(point.y) - origin.y)
    }

    private static func coordinate(_ value: CGFloat) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16(min(CGFloat(UInt16.max), max(0, value)))
    }
}

/// How the virtual cursor is drawn from the shape the server described.
///
/// The server's cursor bitmap is a 1x asset. Drawn at pixel size on a 3x phone
/// display it is both blurred by the upscale and the wrong size against zoomed
/// content, which is what makes a remote desktop feel like a screenshot rather
/// than a machine. A cursor recognised as one of macOS's own is therefore
/// drawn from the bundled artwork at whatever height the host asks for.
/// Anything else keeps the server's pixels, because a shape nobody has
/// identified means something a guess cannot stand in for.
enum TrackpadCursorStyle: Equatable, Sendable, CustomStringConvertible {
    /// One of macOS's cursors, from the bundled artwork.
    case native(TrackpadCursorArtwork.Shape)
    /// The server's own bitmap, scaled by ``bitmapScale(cursorHeight:referenceArrowHeight:)``.
    case serverBitmap

    static let nativeArrow = TrackpadCursorStyle.native(.arrow)
    static let nativeIBeam = TrackpadCursorStyle.native(.iBeam)

    /// The bundled shape to draw, or nil for the server's pixels.
    var artwork: TrackpadCursorArtwork.Shape? {
        switch self {
        case .native(let shape): return shape
        case .serverBitmap: return nil
        }
    }

    var description: String {
        switch self {
        case .native(let shape): return "native(\(shape.name))"
        case .serverBitmap: return "serverBitmap"
        }
    }

    // MARK: - Sizing

    /// On-screen cursor height in view points when the host expresses no
    /// preference: what macOS itself draws, so the remote pointer matches the
    /// one the user sees on the Mac.
    static let defaultCursorHeight: CGFloat = 17
    static let minimumCursorHeight: CGFloat = 8
    static let maximumCursorHeight: CGFloat = 64
    /// Silhouette height assumed for the server's arrow until one has actually
    /// been seen, as the cursor record describes it (shadow included).
    static let fallbackArrowHeight = TrackpadCursorArtwork.nativeArrowShapeHeight
    /// A tiny server shape is not enlarged past this factor; scaling it up to
    /// a full-size cursor would draw a blur the size of a fingertip.
    static let maximumBitmapScale: CGFloat = 4
    static let minimumBitmapScale: CGFloat = 0.1

    static func resolvedCursorHeight(_ requested: CGFloat) -> CGFloat {
        guard requested.isFinite else { return defaultCursorHeight }
        return min(maximumCursorHeight, max(minimumCursorHeight, requested))
    }

    /// One scale for every shape kept as the server's pixels, derived from how
    /// large the server's own arrow turned out to be.
    ///
    /// Scaling each shape to a common height instead would destroy the
    /// proportions the server drew: a wide resize bar is deliberately short,
    /// and stretching it to an arrow's height balloons it across the screen.
    /// Measuring the arrow once and applying its factor to everything keeps
    /// each cursor the size it is meant to be relative to the others, and puts
    /// the bitmap shapes on the same footing as the redrawn ones.
    ///
    /// `referenceArrowHeight` is a silhouette height, which includes the drop
    /// shadow; it is converted to the visible outlined height first, so a
    /// 17 pt cursor against macOS draws every shape at the Mac's own 1x size.
    static func bitmapScale(
        cursorHeight: CGFloat,
        referenceArrowHeight: CGFloat
    ) -> CGFloat {
        let height = resolvedCursorHeight(cursorHeight)
        let silhouette = referenceArrowHeight.isFinite
            && referenceArrowHeight > 0
            ? referenceArrowHeight
            : fallbackArrowHeight
        let visible = silhouette
            * TrackpadCursorArtwork.nativeArrowHeight
            / TrackpadCursorArtwork.nativeArrowShapeHeight
        return min(
            maximumBitmapScale, max(minimumBitmapScale, height / visible))
    }

}

/// When the desktop starts moving to keep the virtual cursor in view.
///
/// Panning as soon as the cursor nears an edge pins it against that edge and
/// leaves the user reading a desktop that never settles. Holding a generous
/// central rectangle instead makes the viewport behave like a camera trailing
/// the pointer: it stays still while the cursor works in the middle of the
/// screen, and takes up the chase only once the cursor commits to a direction.
enum TrackpadFollowPolicy {
    /// Share of each axis reserved as an inset on that side, leaving a central
    /// dead zone of 60% x 60% where the cursor moves and the desktop does not.
    static let deadZoneInsetFraction: CGFloat = 0.2
}
