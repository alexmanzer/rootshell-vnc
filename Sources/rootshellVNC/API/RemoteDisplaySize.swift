import CoreGraphics

struct RemoteDisplaySize: Sendable, Equatable {
    /// Apple's compound screen codec can advertise an 8192-pixel virtual
    /// display, but the public VideoToolbox path rejects full-width bands above
    /// 5120 pixels asynchronously with kVTVideoDecoderBadDataErr. Keep Match
    /// Client inside the largest coded dimension this receiver can sustain.
    private static let maximumDecodedPixelDimension: CGFloat = 5120

    /// The negotiated screen profile uses a 60 fps tier through 3840×2160 and
    /// a 30 fps tier for larger areas such as 3840×2304 and 3696×2416. A Match
    /// Client window larger than UHD must therefore trade
    /// a few percent of backing resolution for the full 60 fps.
    private static let maximumSustained60FPSPixelArea: CGFloat = 3840 * 2160

    let pixelWidth: UInt16
    let pixelHeight: UInt16
    let pointWidth: UInt16
    let pointHeight: UInt16

    /// Exact host-selected pixels. No implicit Retina doubling or upward rounding.
    /// Express Apple's virtual workspace in half as many points (2× backing).
    static func explicit(pixelSize: CGSize) -> RemoteDisplaySize? {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width >= 16, pixelSize.height >= 16,
              pixelSize.width <= 5120, pixelSize.height <= 5120,
              pixelSize.width * pixelSize.height <= 3840 * 2160,
              pixelSize.width.truncatingRemainder(dividingBy: 16) == 0,
              pixelSize.height.truncatingRemainder(dividingBy: 16) == 0 else { return nil }
        return RemoteDisplaySize(pixelWidth: UInt16(pixelSize.width),
            pixelHeight: UInt16(pixelSize.height), pointWidth: UInt16(pixelSize.width / 2),
            pointHeight: UInt16(pixelSize.height / 2))
    }

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

        // Stay inside the encoder's 60 fps area tier (see
        // maximumSustained60FPSPixelArea): shrink both axes uniformly so the
        // negotiated pixel area never crosses into the server's 30 fps mode.
        let maximumPointArea = maximumSustained60FPSPixelArea
            / CGFloat(uiScale * uiScale)
        let fpsFit = min(
            1,
            (maximumPointArea / (pointWidthValue * pointHeightValue))
                .squareRoot())
        pointWidthValue *= fpsFit
        pointHeightValue *= fpsFit

        // Apple's compound HEVC encoder requires each full-width band on a
        // 16-pixel codec boundary. Quantize in point space so Match Client can
        // accept arbitrary window shapes while preserving an exact 2× backing
        // ratio (8 points × 2 = 16 pixels) instead of silently falling to 1×.
        let pointAlignment: CGFloat = 8
        // When the fps cap engaged, alignment must not round back up across
        // the area threshold it just enforced.
        let alignmentRounding: FloatingPointRoundingRule =
            fpsFit < 1 ? .down : .toNearestOrAwayFromZero
        let roundedPointWidth = (pointWidthValue / pointAlignment)
            .rounded(alignmentRounding) * pointAlignment
        let roundedPointHeight = (pointHeightValue / pointAlignment)
            .rounded(alignmentRounding) * pointAlignment
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
