import CoreGraphics

struct RemoteDisplaySize: Sendable, Equatable {
    let pixelWidth: UInt16
    let pixelHeight: UInt16
    let pointWidth: UInt16
    let pointHeight: UInt16

    /// Apple's virtual displays top out at 3840×2160 pixels. Apply the same
    /// bounding rectangle in portrait and landscape while preserving the
    /// client aspect ratio. HiDPI is capped at 2× to match the native client.
    static func matching(
        viewSize: CGSize,
        displayScale: CGFloat
    ) -> RemoteDisplaySize? {
        guard viewSize.width.isFinite,
              viewSize.height.isFinite,
              displayScale.isFinite,
              viewSize.width >= 1,
              viewSize.height >= 1 else { return nil }

        let uiScale = min(2, max(1, displayScale))
        var pixelWidth = viewSize.width * uiScale
        var pixelHeight = viewSize.height * uiScale
        let fit = min(1, min(3840 / pixelWidth, 2160 / pixelHeight))
        pixelWidth *= fit
        pixelHeight *= fit

        // Video encoders and chroma planes require even dimensions. Rounding
        // down cannot exceed the server limit and changes aspect negligibly.
        let evenPixelWidth = max(2, Int(pixelWidth.rounded(.down)) & ~1)
        let evenPixelHeight = max(2, Int(pixelHeight.rounded(.down)) & ~1)
        let pointWidth = max(1, Int((CGFloat(evenPixelWidth) / uiScale).rounded()))
        let pointHeight = max(1, Int((CGFloat(evenPixelHeight) / uiScale).rounded()))

        guard evenPixelWidth <= Int(UInt16.max),
              evenPixelHeight <= Int(UInt16.max),
              pointWidth <= Int(UInt16.max),
              pointHeight <= Int(UInt16.max) else { return nil }
        return RemoteDisplaySize(
            pixelWidth: UInt16(evenPixelWidth),
            pixelHeight: UInt16(evenPixelHeight),
            pointWidth: UInt16(pointWidth),
            pointHeight: UInt16(pointHeight))
    }
}
