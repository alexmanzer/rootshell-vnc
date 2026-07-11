import CoreGraphics

struct RemoteDisplaySize: Sendable, Equatable {
    let pixelWidth: UInt16
    let pixelHeight: UInt16
    let pointWidth: UInt16
    let pointHeight: UInt16

    /// A literal iPhone viewport is too small to be a usable macOS workspace,
    /// so first expand it to a 1024×600-point minimum while preserving the
    /// client aspect ratio. Backing density is discrete: Apple recognizes a
    /// virtual display as HiDPI only when every point is backed by exactly 2×2
    /// pixels.
    static func matching(viewSize: CGSize) -> RemoteDisplaySize? {
        guard viewSize.width.isFinite,
              viewSize.height.isFinite,
              viewSize.width >= 1,
              viewSize.height >= 1 else { return nil }

        let uiScale = 2
        let workspaceScale = max(
            1,
            1024 / viewSize.width,
            600 / viewSize.height)
        let pointWidthValue = viewSize.width * workspaceScale
        let pointHeightValue = viewSize.height * workspaceScale

        // Apple's compound HEVC encoder requires each full-width band on a
        // 16-pixel codec boundary. Quantize in point space so Match Client can
        // accept arbitrary window shapes while preserving an exact 2× backing
        // ratio (8 points × 2 = 16 pixels) instead of silently falling to 1×.
        let pointAlignment: CGFloat = 8
        let roundedPointWidth = (pointWidthValue / pointAlignment).rounded()
            * pointAlignment
        let roundedPointHeight = (pointHeightValue / pointAlignment).rounded()
            * pointAlignment
        let maximumPointDimension = CGFloat(Int(UInt16.max) / uiScale)
        guard roundedPointWidth <= maximumPointDimension,
              roundedPointHeight <= maximumPointDimension else { return nil }

        let pointWidth = max(1, Int(roundedPointWidth))
        let pointHeight = max(1, Int(roundedPointHeight))
        let pixelWidth = pointWidth * uiScale
        let pixelHeight = pointHeight * uiScale

        guard pixelWidth <= Int(UInt16.max),
              pixelHeight <= Int(UInt16.max),
              pointWidth <= Int(UInt16.max),
              pointHeight <= Int(UInt16.max) else { return nil }
        return RemoteDisplaySize(
            pixelWidth: UInt16(pixelWidth),
            pixelHeight: UInt16(pixelHeight),
            pointWidth: UInt16(pointWidth),
            pointHeight: UInt16(pointHeight))
    }
}
