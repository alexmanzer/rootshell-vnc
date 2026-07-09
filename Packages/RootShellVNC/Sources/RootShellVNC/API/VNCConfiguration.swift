import Foundation
import RFBProtocol

/// Configuration options for a VNC session.
///
/// Use this to customize the behavior of a ``VNCSession`` before connecting.
/// All properties have sensible defaults.
public struct VNCConfiguration: Sendable {

    /// High-performance video quality profile, mirroring the native client's
    /// Quality setting.
    public enum VideoQualityMode: Sendable, Equatable {
        /// "Adapt quality to network conditions" — the server may lower bitrate
        /// and drop resolution/quality on static regions under pressure.
        case adaptive
        /// "Show the screen at full quality" — mirrors Screen Sharing mode 4
        /// by using lossless Zlib/ZRLE instead of lossy AVConference video.
        case fullQuality
    }

    /// Which high-performance video quality profile to offer the server.
    public var videoQualityMode: VideoQualityMode

    /// Preferred pixel format to request from the server.
    ///
    /// When `nil`, the server's default pixel format is used.
    public var preferredPixelFormat: PixelFormat?

    /// Preferred encodings in priority order.
    ///
    /// The first encoding the server supports will be used. The list should
    /// always include `.raw` as a fallback, though it will be appended
    /// automatically if absent.
    public var preferredEncodings: [Encoding]

    /// Whether to request high-performance mode (HEVC/H.264) when available.
    ///
    /// When `true` and the server supports Apple HEVC or H.264 encodings,
    /// the session will negotiate hardware-accelerated video streaming.
    public var enableHighPerformanceMode: Bool

    /// Target frame rate for framebuffer update requests.
    ///
    /// The session will request incremental updates at approximately this rate.
    /// Valid range is 1...120; values outside this range are clamped.
    public var targetFrameRate: Int

    /// Whether to enable protocol tracing for debugging.
    ///
    /// When `true`, all protocol messages are recorded with timestamps.
    /// This is always enabled in DEBUG builds regardless of this setting.
    public var enableProtocolTrace: Bool

    /// Create a VNC session configuration.
    ///
    /// - Parameters:
    ///   - preferredPixelFormat: Pixel format to request, or `nil` for server default.
    ///   - preferredEncodings: Encodings in priority order.
    ///   - enableHighPerformanceMode: Whether to enable HEVC when available.
    ///   - targetFrameRate: Desired frame rate for update requests.
    ///   - enableProtocolTrace: Whether to record protocol messages.
    public init(
        preferredPixelFormat: PixelFormat? = nil,
        preferredEncodings: [Encoding] = [.copyRect, .raw],
        enableHighPerformanceMode: Bool = true,
        videoQualityMode: VideoQualityMode = .adaptive,
        targetFrameRate: Int = 30,
        enableProtocolTrace: Bool = false
    ) {
        self.preferredPixelFormat = preferredPixelFormat
        self.preferredEncodings = preferredEncodings
        self.enableHighPerformanceMode = enableHighPerformanceMode
        self.videoQualityMode = videoQualityMode
        self.targetFrameRate = max(1, min(120, targetFrameRate))
        self.enableProtocolTrace = enableProtocolTrace
    }

    /// The interval between frame requests, derived from ``targetFrameRate``.
    var frameRequestInterval: Duration {
        .milliseconds(1000 / max(1, targetFrameRate))
    }

    /// The full list of encodings to advertise to the server, including
    /// pseudo-encodings for desktop resize and high-performance mode.
    var effectiveEncodings: [Encoding] {
        var encodings = preferredEncodings

        // Apple's default/high quality mode offers AVC first. Its Full Quality
        // mode does not negotiate AVC at all: the native binary's exact video
        // list is [Zlib (6), ZRLE (16)]. Keep those semantics instead of trying
        // to manufacture a "lossless HEVC" profile that the protocol lacks.
        if enableHighPerformanceMode, videoQualityMode == .adaptive {
            let proModeEncodings: [Encoding] = [
                .appleH264, .appleMultiVariantScreenshare, .appleSubZlibThousands, .zlib, .zrle,
            ]
            for encoding in proModeEncodings.reversed() where !encodings.contains(encoding) {
                encodings.insert(encoding, at: 0)
            }
            for encoding in [Encoding.encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer] {
                if !encodings.contains(encoding) {
                    encodings.append(encoding)
                }
            }
        } else if videoQualityMode == .fullQuality {
            for encoding in [Encoding.zrle, .zlib] where !encodings.contains(encoding) {
                encodings.insert(encoding, at: 0)
            }
        }

        // Always advertise desktop resize support
        if !encodings.contains(.desktopSize) {
            encodings.append(.desktopSize)
        }

        // Always include cursor pseudo-encoding
        if !encodings.contains(.cursor) {
            encodings.append(.cursor)
        }

        // Ensure raw is present as ultimate fallback
        if !encodings.contains(.raw) {
            encodings.append(.raw)
        }

        return encodings
    }
}
