import CoreGraphics

struct RemoteDisplaySize: Sendable, Equatable {
    let pixelWidth: UInt16
    let pixelHeight: UInt16
    let pointWidth: UInt16
    let pointHeight: UInt16

    /// Apple's virtual displays top out at 3840×2160 pixels. A literal iPhone
    /// viewport is too small to be a usable macOS workspace, so first expand it
    /// to a 1024×600-point minimum while preserving the client aspect ratio.
    /// HiDPI is capped at 2× to match the native client.
    static func matching(
        viewSize: CGSize,
        displayScale: CGFloat
    ) -> RemoteDisplaySize? {
        guard viewSize.width.isFinite,
              viewSize.height.isFinite,
              displayScale.isFinite,
              viewSize.width >= 1,
              viewSize.height >= 1 else { return nil }

        let requestedUIScale = min(2, max(1, displayScale))
        let workspaceScale = max(
            1,
            1024 / viewSize.width,
            600 / viewSize.height)
        var pointWidthValue = viewSize.width * workspaceScale
        var pointHeightValue = viewSize.height * workspaceScale

        // Prefer reducing backing density over shrinking the logical macOS
        // workspace. This is especially important in portrait, where fitting a
        // 2× framebuffer into 2160 pixels previously turned a requested
        // 1024-point-wide desktop back into an unusable ~600-point workspace.
        let fittedUIScale = min(
            requestedUIScale,
            3840 / pointWidthValue,
            2160 / pointHeightValue)
        let uiScale = max(1, fittedUIScale)
        if fittedUIScale < 1 {
            let pointFit = min(
                1,
                3840 / pointWidthValue,
                2160 / pointHeightValue)
            pointWidthValue *= pointFit
            pointHeightValue *= pointFit
        }
        let pixelWidth = pointWidthValue * uiScale
        let pixelHeight = pointHeightValue * uiScale

        // Video encoders and chroma planes require even dimensions. Rounding
        // down cannot exceed the server limit and changes aspect negligibly.
        let evenPixelWidth = max(2, Int(pixelWidth.rounded(.down)) & ~1)
        let evenPixelHeight = max(2, Int(pixelHeight.rounded(.down)) & ~1)
        let pointWidth = max(1, Int(pointWidthValue.rounded()))
        let pointHeight = max(1, Int(pointHeightValue.rounded()))

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
