import Foundation
import RFBProtocol

/// Configuration options for a VNC session.
///
/// Use this to customize the behavior of a ``VNCSession`` before connecting.
/// All properties have sensible defaults.
public struct VNCConfiguration: Sendable {

    /// How the server chooses the remote framebuffer dimensions.
    public enum DisplaySizingMode: String, Sendable, Equatable, CaseIterable, Identifiable {
        /// Keep the server's existing physical or virtual display size.
        case remoteDisplay
        /// Ask a capable server to render a display matching this client.
        case matchClient

        public var id: Self { self }

        public var title: String {
            switch self {
            case .remoteDisplay: "Remote Display"
            case .matchClient: "Match Client"
            }
        }

        public var explanation: String {
            switch self {
            case .remoteDisplay:
                "Keep the remote computer's existing display dimensions."
            case .matchClient:
                "Match this window or iPad aspect ratio. Supported Macs use a separate virtual display; other VNC servers resize only when they advertise support."
            }
        }
    }

    /// High-performance video quality profile, mirroring the native client's
    /// Quality setting.
    public enum VideoQualityMode: String, Sendable, Equatable, CaseIterable, Identifiable {
        /// "Adapt quality to network conditions" — the server may lower bitrate
        /// and drop resolution/quality on static regions under pressure.
        case adaptive
        /// Portable lossless RFB over the ordered TCP channel. This avoids the
        /// Apple HEVC/UDP media floor on constrained or UDP-hostile paths while
        /// retaining compressed updates and CopyRect acceleration.
        case standard
        /// "Show the screen at full quality" — mirrors Screen Sharing mode 4
        /// by using lossless Zlib/ZRLE instead of lossy AVConference video.
        case fullQuality

        public var id: Self { self }

        public var title: String {
            switch self {
            case .adaptive: "Adaptive"
            case .standard: "Standard"
            case .fullQuality: "Full Quality"
            }
        }

        public var explanation: String {
            switch self {
            case .adaptive:
                "Low-latency HEVC over UDP for networks that can sustain the video stream."
            case .standard:
                "Reliable compressed RFB over TCP for constrained networks, VPNs, and non-Mac servers."
            case .fullQuality:
                "Lossless framebuffer updates with higher bandwidth and CPU use."
            }
        }
    }

    /// Which high-performance video quality profile to offer the server.
    public var videoQualityMode: VideoQualityMode

    /// Whether a capable server should render at the client viewport size.
    public var displaySizingMode: DisplaySizingMode

    /// Whether negotiated remote system audio should play on this device.
    public var enableRemoteAudio: Bool

    /// Preferred pixel format to request from the server.
    ///
    /// When `nil`, the session requests full-color BGRA8888.
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

    /// Automatic retry behavior after an established TCP connection is lost.
    public var reconnectionPolicy: VNCReconnectionPolicy

    /// Create a VNC session configuration.
    ///
    /// - Parameters:
    ///   - preferredPixelFormat: Pixel format to request, or `nil` for full-color BGRA8888.
    ///   - preferredEncodings: Encodings in priority order.
    ///   - enableHighPerformanceMode: Whether to enable HEVC when available.
    ///   - targetFrameRate: Desired frame rate for update requests.
    ///   - enableProtocolTrace: Whether to record protocol messages.
    public init(
        preferredPixelFormat: PixelFormat? = nil,
        preferredEncodings: [Encoding] = [.copyRect, .raw],
        enableHighPerformanceMode: Bool = true,
        videoQualityMode: VideoQualityMode = .adaptive,
        displaySizingMode: DisplaySizingMode = .matchClient,
        enableRemoteAudio: Bool = true,
        targetFrameRate: Int = 30,
        enableProtocolTrace: Bool = false,
        reconnectionPolicy: VNCReconnectionPolicy = VNCReconnectionPolicy()
    ) {
        self.preferredPixelFormat = preferredPixelFormat
        self.preferredEncodings = preferredEncodings
        self.enableHighPerformanceMode = enableHighPerformanceMode
        self.videoQualityMode = videoQualityMode
        self.displaySizingMode = displaySizingMode
        self.enableRemoteAudio = enableRemoteAudio
        self.targetFrameRate = max(1, min(120, targetFrameRate))
        self.enableProtocolTrace = enableProtocolTrace
        self.reconnectionPolicy = reconnectionPolicy
    }

    /// The interval between frame requests, derived from ``targetFrameRate``.
    var frameRequestInterval: Duration {
        .milliseconds(1000 / max(1, targetFrameRate))
    }

    /// The pixel format the session negotiates and decodes with.
    ///
    /// An explicit ``preferredPixelFormat`` always wins (pass `.rgb555` for
    /// 16-bit "thousands" color — measured ~3x smaller ZRLE payloads against
    /// macOS Screen Sharing when bandwidth, not color, is the constraint).
    /// The default stays full color in every mode.
    var effectivePixelFormat: PixelFormat {
        preferredPixelFormat ?? .bgra8888
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
        } else if videoQualityMode == .standard {
            // Prefer Apple's low-latency adaptive DCT path with portable
            // full-color fallbacks for servers that do not support it.
            let standardEncodings: [Encoding] = [
                .appleMultiVariantScreenshare, .tight, .unknown(-224),
                .zrle, .zlib, .copyRect,
                .unknown(1105), .unknown(1101), .unknown(1100), .unknown(1104),
                .raw, .unknown(-23),
            ]
            for encoding in standardEncodings.reversed() {
                encodings.removeAll { $0 == encoding }
                encodings.insert(encoding, at: 0)
            }
        } else if videoQualityMode == .fullQuality {
            // Full Quality targets fast local networks: bandwidth is
            // plentiful, so prefer Zlib's cheaper encode/decode over ZRLE's
            // tighter compression (matches the native binary's [Zlib, ZRLE]).
            let fullQualityEncodings: [Encoding] = [
                .copyRect, .zlib, .zrle, .raw,
            ]
            for encoding in fullQualityEncodings.reversed() {
                encodings.removeAll { $0 == encoding }
                encodings.insert(encoding, at: 0)
            }
        }

        // Advertise both the legacy notification and the bidirectional screen
        // layout extension. SetDesktopSize is sent only after a server proves
        // support by returning ExtendedDesktopSize.
        if !encodings.contains(.desktopSize) {
            encodings.append(.desktopSize)
        }
        if !encodings.contains(.extendedDesktopSize) {
            encodings.append(.extendedDesktopSize)
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
