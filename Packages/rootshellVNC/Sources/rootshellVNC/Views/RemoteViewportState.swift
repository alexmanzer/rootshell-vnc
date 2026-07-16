import CoreGraphics

enum RemoteViewportPanningMode: CaseIterable, Hashable, Sendable {
    case edge
    case continuous
}

/// Zoom/pan state shared by the lossless and adaptive renderers.
///
/// The state is expressed relative to the aspect-fit desktop: scale 1 is the
/// complete screen, and offset is measured in view points from its centered
/// position. Keeping the transform here gives rendering and input conversion
/// one source of truth.
struct RemoteViewportState: Equatable, Sendable {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 10
    static let edgeScrollActivationInset: CGFloat = 24
    static let maximumEdgeScrollSpeed: CGFloat = 2_400

    private(set) var scale: CGFloat = minimumScale
    private(set) var offset: CGSize = .zero

    var isIdentity: Bool {
        scale == Self.minimumScale && offset == .zero
    }

    mutating func reset() {
        scale = Self.minimumScale
        offset = .zero
    }

    mutating func zoom(
        by factor: CGFloat,
        around anchor: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) {
        guard factor.isFinite, factor > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }

        let oldScale = scale
        let newScale = min(
            Self.maximumScale,
            max(Self.minimumScale, oldScale * factor))
        // Matching UIScrollView's minimum-zoom behavior, pinching inward at
        // the fitted scale restores the canonical centered viewport. This
        // also gives a panned-but-unzoomed desktop an immediate natural reset.
        if newScale == Self.minimumScale, factor < 1 {
            reset()
            return
        }
        guard newScale != oldScale else { return }

        // Keep the remote pixel under the gesture centroid stationary.
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let ratio = newScale / oldScale
        offset = CGSize(
            width: anchor.x - center.x
                - (anchor.x - center.x - offset.width) * ratio,
            height: anchor.y - center.y
                - (anchor.y - center.y - offset.height) * ratio)
        scale = newScale
        clampOffset(viewSize: viewSize, framebufferSize: framebufferSize)
    }

    mutating func pan(
        by translation: CGSize,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) {
        offset.width += translation.width
        offset.height += translation.height
        clampOffset(viewSize: viewSize, framebufferSize: framebufferSize)
    }

    /// Returns the display translation for one frame of pointer edge
    /// scrolling. It uses the same generous overscroll limits as a two-finger
    /// pan, allowing the desktop edge to move as far as the viewport center.
    func edgeScrollTranslation(
        for pointerLocation: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize,
        elapsedTime: Double
    ) -> CGSize {
        guard scale > Self.minimumScale,
              elapsedTime.isFinite, elapsedTime > 0,
              let frame = displayedFrame(
                viewSize: viewSize,
                framebufferSize: framebufferSize) else { return .zero }

        let horizontalVelocity = Self.edgeScrollVelocity(
            coordinate: pointerLocation.x,
            length: viewSize.width)
        let verticalVelocity = Self.edgeScrollVelocity(
            coordinate: pointerLocation.y,
            length: viewSize.height)
        return CGSize(
            width: Self.boundedEdgeTranslation(
                velocity: horizontalVelocity,
                elapsedTime: elapsedTime,
                leadingTravel: max(0, frame.width / 2 - offset.width),
                trailingTravel: max(0, frame.width / 2 + offset.width)),
            height: Self.boundedEdgeTranslation(
                velocity: verticalVelocity,
                elapsedTime: elapsedTime,
                leadingTravel: max(0, frame.height / 2 - offset.height),
                trailingTravel: max(0, frame.height / 2 + offset.height)))
    }

    /// Returns the translation that makes the visible desktop continuously
    /// follow the pointer. Pointer position is treated proportionally: a
    /// pointer one quarter across the viewport selects the corresponding
    /// quarter of the two-finger pan range, including its overscroll margins.
    func cursorFollowingTranslation(
        for pointerLocation: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGSize {
        guard scale > Self.minimumScale,
              let frame = displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize) else { return .zero }

        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let horizontalFraction = min(
            1, max(0, pointerLocation.x / viewSize.width))
        let verticalFraction = min(
            1, max(0, pointerLocation.y / viewSize.height))
        return CGSize(
            width: frame.width * (0.5 - horizontalFraction) - offset.width,
            height: frame.height * (0.5 - verticalFraction) - offset.height)
    }

    private static func edgeScrollVelocity(
        coordinate: CGFloat,
        length: CGFloat
    ) -> CGFloat {
        guard coordinate.isFinite, length > 0 else { return 0 }
        let inset = min(edgeScrollActivationInset, length / 2)
        guard inset > 0 else { return 0 }
        if coordinate < inset {
            return maximumEdgeScrollSpeed
                * min(1, (inset - coordinate) / inset)
        }
        if coordinate > length - inset {
            return -maximumEdgeScrollSpeed
                * min(1, (coordinate - (length - inset)) / inset)
        }
        return 0
    }

    private static func boundedEdgeTranslation(
        velocity: CGFloat,
        elapsedTime: Double,
        leadingTravel: CGFloat,
        trailingTravel: CGFloat
    ) -> CGFloat {
        let proposed = velocity * CGFloat(elapsedTime)
        if proposed > 0 {
            return min(proposed, leadingTravel)
        }
        if proposed < 0 {
            return max(proposed, -trailingTravel)
        }
        return 0
    }

    mutating func clampOffset(viewSize: CGSize, framebufferSize: CGSize) {
        guard let frame = displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize) else {
            offset = .zero
            return
        }

        // Keep the desktop from disappearing completely while allowing a
        // generous working margin around every edge. At the limit, the edge
        // being moved inward may reach the viewport center, but not cross it.
        let horizontalLimit = frame.width / 2
        let verticalLimit = frame.height / 2
        offset.width = min(horizontalLimit, max(-horizontalLimit, offset.width))
        offset.height = min(verticalLimit, max(-verticalLimit, offset.height))
    }

    func framebufferPoint(
        for viewPoint: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGPoint? {
        guard let frame = displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize),
              frame.width > 0, frame.height > 0,
              frame.contains(viewPoint) else { return nil }

        let x = (viewPoint.x - frame.minX) / frame.width * framebufferSize.width
        let y = (viewPoint.y - frame.minY) / frame.height * framebufferSize.height
        guard x >= 0, y >= 0,
              x < framebufferSize.width,
              y < framebufferSize.height else { return nil }
        return CGPoint(x: x, y: y)
    }

    func displayedFrame(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0,
              framebufferSize.width > 0, framebufferSize.height > 0 else {
            return nil
        }

        let fit = min(
            viewSize.width / framebufferSize.width,
            viewSize.height / framebufferSize.height)
        let size = CGSize(
            width: framebufferSize.width * fit * scale,
            height: framebufferSize.height * fit * scale)
        return CGRect(
            x: (viewSize.width - size.width) / 2 + offset.width,
            y: (viewSize.height - size.height) / 2 + offset.height,
            width: size.width,
            height: size.height)
    }
}
