import CoreGraphics

struct RemoteDisplaySize: Sendable, Equatable {
    /// Apple's compound screen codec can advertise an 8192-pixel virtual
    /// display, but the public VideoToolbox path rejects full-width bands above
    /// 5120 pixels asynchronously with kVTVideoDecoderBadDataErr. Keep Match
    /// Client inside the largest coded dimension this receiver can sustain.
    private static let maximumDecodedPixelDimension: CGFloat = 5120

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
        var pointWidthValue = viewSize.width * workspaceScale
        var pointHeightValue = viewSize.height * workspaceScale

        // Each HEVC band is full desktop width. Fit both axes together so a
        // large or unusually shaped window cannot negotiate a coded dimension
        // that creates a valid VT session but then fails every submitted frame.
        let maximumDecodedPointDimension = maximumDecodedPixelDimension
            / CGFloat(uiScale)
        let decodeFit = min(
            1,
            maximumDecodedPointDimension / pointWidthValue,
            maximumDecodedPointDimension / pointHeightValue)
        pointWidthValue *= decodeFit
        pointHeightValue *= decodeFit

        // Apple's compound HEVC encoder requires each full-width band on a
        // 16-pixel codec boundary. Quantize in point space so Match Client can
        // accept arbitrary window shapes while preserving an exact 2× backing
        // ratio (8 points × 2 = 16 pixels) instead of silently falling to 1×.
        let pointAlignment: CGFloat = 8
        let roundedPointWidth = (pointWidthValue / pointAlignment).rounded()
            * pointAlignment
        let roundedPointHeight = (pointHeightValue / pointAlignment).rounded()
            * pointAlignment
        let maximumPointDimension = min(
            CGFloat(Int(UInt16.max) / uiScale),
            maximumDecodedPointDimension)
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
