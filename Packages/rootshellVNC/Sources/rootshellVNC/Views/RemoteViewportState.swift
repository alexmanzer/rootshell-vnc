import CoreGraphics

/// Zoom/pan state shared by the lossless and adaptive renderers.
///
/// The state is expressed relative to the aspect-fit desktop: scale 1 is the
/// complete screen, and offset is measured in view points from its centered
/// position. Keeping the transform here gives rendering and input conversion
/// one source of truth.
struct RemoteViewportState: Equatable, Sendable {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 10

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
