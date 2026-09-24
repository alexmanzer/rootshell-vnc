import CoreGraphics

/// Virtual cursor driven by relative finger motion, the way a laptop
/// trackpad drives the pointer.
///
/// Direct touch puts the pointer wherever the finger lands, which is fine for
/// tapping but hopeless for the small targets of a desktop UI: the finger
/// covers the very pixel it is aiming at. Accumulating relative motion here
/// instead lets the same finger travel reach any pixel, keeps the pointer
/// visible while it moves, and makes precision a function of gain rather than
/// of fingertip size.
///
/// The model owns nothing but arithmetic so it can be exercised without a
/// view, a connection, or a run loop.
struct TrackpadPointerModel: Equatable, Sendable {
    /// Gain applied below `gainVelocityFloor`. Slightly under 1 so a slow,
    /// deliberate finger lands on a specific pixel instead of sliding past it.
    static let minimumGain: CGFloat = 0.9
    /// Gain reached at `gainVelocityCeiling` and held above it. Capped rather
    /// than left to grow so a fast flick stays predictable and cannot throw
    /// the cursor across a 5K desktop.
    static let maximumGain: CGFloat = 2.2
    /// Finger speed below which no acceleration applies, in view points per
    /// second.
    static let gainVelocityFloor: CGFloat = 50
    /// Finger speed at which acceleration saturates, in view points per
    /// second.
    static let gainVelocityCeiling: CGFloat = 600

    static let minimumSpeed: Double = 0.5
    static let maximumSpeed: Double = 3
    static let defaultSpeed: Double = 1

    /// Cursor position in framebuffer pixels, fractional so slow motion
    /// accumulates.
    ///
    /// A gentle drag can ask for a fraction of a pixel per touch callback. If
    /// the position were rounded on every event, that fraction would be
    /// discarded sixty times a second and the cursor would refuse to move at
    /// all below a threshold speed. The fraction is kept here and only
    /// rounded when a coordinate goes on the wire.
    private(set) var position: CGPoint
    private(set) var framebufferSize: CGSize

    /// User multiplier on top of the acceleration curve, clamped to
    /// `minimumSpeed`...`maximumSpeed` on set so a stray preference value can
    /// never freeze or slingshot the cursor.
    var speed: Double {
        get { storedSpeed }
        set { storedSpeed = Self.clampedSpeed(newValue) }
    }

    private var storedSpeed: Double

    init(
        position: CGPoint,
        framebufferSize: CGSize,
        speed: Double = TrackpadPointerModel.defaultSpeed
    ) {
        self.position = position
        self.framebufferSize = Self.sanitized(framebufferSize)
        self.storedSpeed = Self.clampedSpeed(speed)
        clampPosition()
    }

    /// Moves the cursor by a finger translation measured in view points and
    /// returns the resulting position.
    ///
    /// `framebufferPixelsPerPoint` is how many framebuffer pixels one view
    /// point covers at the current zoom. Scaling by it is what makes the
    /// cursor track the finger on glass: at 3x zoom a view point spans a
    /// third of the remote pixels, so the same finger travel must cover a
    /// third of the desktop, and the pointer stays under the fingertip's
    /// intent instead of racing ahead when the user zooms in.
    ///
    /// `velocity` is the finger's speed in view points per second and is
    /// expected to be a magnitude; it only selects a point on the
    /// acceleration curve.
    @discardableResult
    mutating func move(
        by translation: CGPoint,
        framebufferPixelsPerPoint: CGFloat,
        velocity: CGFloat
    ) -> CGPoint {
        guard translation.x.isFinite, translation.y.isFinite,
              framebufferPixelsPerPoint.isFinite,
              framebufferPixelsPerPoint > 0 else { return position }

        let factor = Self.gain(forVelocity: velocity)
            * CGFloat(storedSpeed)
            * framebufferPixelsPerPoint
        position.x += translation.x * factor
        position.y += translation.y * factor
        clampPosition()
        return position
    }

    /// Places the cursor at an absolute framebuffer point, clamped into the
    /// framebuffer. Used when the pointer has to be seeded or recentered
    /// rather than nudged.
    mutating func place(at point: CGPoint) {
        position = point
        clampPosition()
    }

    /// Adopts a new framebuffer size and re-clamps, so a desktop that shrinks
    /// mid-session cannot leave the cursor outside its own screen.
    mutating func updateFramebufferSize(_ size: CGSize) {
        framebufferSize = Self.sanitized(size)
        clampPosition()
    }

    /// The position as the protocol carries it: rounded, clamped to 0...65535
    /// and to the framebuffer's last addressable pixel.
    var integerPosition: (x: UInt16, y: UInt16) {
        (Self.wireCoordinate(position.x, length: framebufferSize.width),
         Self.wireCoordinate(position.y, length: framebufferSize.height))
    }

    /// Acceleration curve applied before the user's speed multiplier.
    ///
    /// Flat at `minimumGain` up to `gainVelocityFloor`, linear to
    /// `maximumGain` at `gainVelocityCeiling`, flat above. The flat tails are
    /// what make it usable: precision is constant when the finger crawls, and
    /// a hurried swipe cannot become unbounded. Monotonically non-decreasing,
    /// and defined for every input, including the non-finite velocities a
    /// degenerate time delta can produce.
    static func gain(forVelocity pointsPerSecond: CGFloat) -> CGFloat {
        guard pointsPerSecond.isFinite,
              pointsPerSecond > gainVelocityFloor else { return minimumGain }
        guard pointsPerSecond < gainVelocityCeiling else { return maximumGain }

        let progress = (pointsPerSecond - gainVelocityFloor)
            / (gainVelocityCeiling - gainVelocityFloor)
        return minimumGain + (maximumGain - minimumGain) * progress
    }

    private mutating func clampPosition() {
        position = CGPoint(
            x: Self.clamped(position.x, length: framebufferSize.width),
            y: Self.clamped(position.y, length: framebufferSize.height))
    }

    /// A size with a non-positive or non-finite dimension describes no
    /// screen at all; treating it as zero keeps every derived limit defined.
    private static func sanitized(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .zero }
        return size
    }

    private static func clamped(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 0, value.isFinite else { return 0 }
        return min(length - 1, max(0, value))
    }

    private static func wireCoordinate(
        _ value: CGFloat,
        length: CGFloat
    ) -> UInt16 {
        guard length >= 1, value.isFinite else { return 0 }
        let limit = min(CGFloat(UInt16.max), (length - 1).rounded(.down))
        return UInt16(min(limit, max(0, value.rounded())))
    }

    private static func clampedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSpeed }
        return min(maximumSpeed, max(minimumSpeed, value))
    }
}
