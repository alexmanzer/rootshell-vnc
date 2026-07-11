import Compression
import Darwin
import Foundation
import RFBProtocol

/// Tracks the native AVC message-1/answer lifecycle across in-session media
/// reconfigurations. ScreenSharing sets its `mediaStreamMessage1Received` bit
/// on message 1, rejects another while an answer is pending, and clears the bit
/// when message 2 arrives. A display resize starts another complete cycle.
struct AppleMediaNegotiationGenerationTracker {
    struct Transition: Sendable, Equatable {
        let generation: UInt64
        let isReconfiguration: Bool
    }

    private(set) var generation: UInt64 = 0
    private(set) var isAwaitingAnswer = false

    mutating func beginMessageOne() -> Transition? {
        guard !isAwaitingAnswer else { return nil }
        generation &+= 1
        isAwaitingAnswer = true
        return Transition(
            generation: generation,
            isReconfiguration: generation > 1)
    }

    @discardableResult
    mutating func finishMessageTwo() -> Bool {
        guard isAwaitingAnswer else { return false }
        isAwaitingAnswer = false
        return true
    }
}

/// Selects Apple's native compound screen-video profile.
public enum AppleMediaVideoMode {
    public static var usesTiledHEVC: Bool { true }

    @available(*, deprecated, renamed: "usesTiledHEVC")
    public static var usesExperimentalTiledHEVC: Bool {
        usesTiledHEVC
    }

    public static var negotiatedTilesPerFrame: UInt64 {
        2
    }
}

/// Portable encoder for the Viceroy v1 media-negotiation message used by
/// Apple's RFB media-stream extension.
///
/// The previous implementation replayed a captured compressed protobuf. That
/// accidentally replayed a creation timestamp, an RTP SSRC, endpoint metadata,
/// and display capabilities from the machine on which it was captured. Apart
/// from advertising the wrong client, reusing an SSRC and creation time can be
/// interpreted as a colliding or stale media session.
struct AppleMediaNegotiationProfile: Sendable {
    /// The Viceroy screen stream is negotiated as a logical local-network
    /// transport even when the device reaches that network through cellular
    /// and a VPN. Advertising cellular-only screen rules completes the control
    /// handshake but leaves the peers without a compatible video source.
    private static let screenAccessNetworkType: UInt64 = 1
    private static let screenVideoTransportType: UInt64 = 1

    /// Viceroy negotiates the minimum of the peers' values. Four matches the
    /// native Screen Sharing profile and preserves full-resolution Retina
    /// capture instead of downscaling into the one-tile encoder budget.
    static var publicDecoderTilesPerFrame: UInt64 {
        AppleMediaVideoMode.negotiatedTilesPerFrame
    }

    enum MediaKind: Sendable {
        case audio
        case screen
    }

    struct AspectRatio: Sendable, Equatable {
        let landscapeWidth: UInt32
        let landscapeHeight: UInt32
        let portraitWidth: UInt32
        let portraitHeight: UInt32

        /// Native Viceroy's screen codec capability pair. These are not the
        /// current framebuffer dimensions: a native MacBook capture advertises
        /// this same pair for its non-16:9 display. The server uses it while
        /// selecting its encoder/tiling profile.
        static let screenCodec = AspectRatio(
            landscapeWidth: 16,
            landscapeHeight: 9,
            portraitWidth: 5,
            portraitHeight: 8)

        var featureListValue: String {
            "\(landscapeWidth)/\(landscapeHeight),\(portraitWidth)/\(portraitHeight)"
        }
    }

    struct Endpoint: Sendable, Equatable {
        /// Viewer/answerer role in the endpoint-info protobuf.
        var role: UInt32 = 0
        /// Endpoint-info schema version emitted by the native negotiator.
        var schemaVersion: UInt32 = 1
        var productIdentifier: String
        var mediaSoftwareVersion: String
        var operatingSystemBuild: String

        static func current() -> Endpoint {
            let product = systemString("hw.model")
                ?? systemString("hw.machine")
                ?? unameMachine()
                ?? "AppleDevice"
            let softwareVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "1"
            let osBuild = systemString("kern.osversion")
                ?? ProcessInfo.processInfo.operatingSystemVersionString
            return Endpoint(
                productIdentifier: product,
                mediaSoftwareVersion: softwareVersion,
                operatingSystemBuild: osBuild
            )
        }

        private static func systemString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
            if bytes.last == 0 { bytes.removeLast() }
            return String(decoding: bytes.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }

        private static func unameMachine() -> String? {
            var value = utsname()
            guard uname(&value) == 0 else { return nil }
            return withUnsafePointer(to: &value.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
        }
    }

    let aspectRatio: AspectRatio
    let supportsHDR: Bool
    let tilesPerFrame: UInt64

    init(
        framebufferWidth: UInt16,
        framebufferHeight: UInt16,
        supportsHDR: Bool,
        tilesPerFrame: UInt64 = AppleMediaVideoMode.negotiatedTilesPerFrame
    ) {
        self.aspectRatio = .screenCodec
        self.supportsHDR = supportsHDR
        self.tilesPerFrame = tilesPerFrame
        _ = framebufferWidth
        _ = framebufferHeight
    }

    /// Create an entire binary-plist negotiator offer. Every session-dependent
    /// value is supplied by the caller so tests can verify the wire message.
    func makeOffer(
        kind: MediaKind,
        mode: Int,
        ssrc: UInt32,
        ntpTimestamp: UInt64,
        callID: UUID = UUID(),
        endpoint: Endpoint = .current()
    ) throws -> Data {
        let uncompressed = mediaBlob(
            kind: kind,
            ssrc: ssrc,
            ntpTimestamp: ntpTimestamp
        )
        let compressed = try Self.zlibCompress(uncompressed)
        let plist: [String: Any] = [
            "avcMediaStreamNegotiatorMediaBlob": compressed,
            "avcMediaStreamNegotiatorMode": mode,
            "avcMediaStreamOptionCallID": callID.uuidString,
            "avcMediaStreamOptionRemoteEndpointInfo": endpointInfo(endpoint),
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
    }

    /// Uncompressed protobuf, exposed internally for structural tests.
    func mediaBlob(kind: MediaKind, ssrc: UInt32, ntpTimestamp: UInt64) -> Data {
        var blob = ProtobufEncoder()
        blob.bool(field: 1, true) // allowDynamicMaxBitrate
        blob.bool(field: 2, true) // allowsContentsChangeWithAspectPreservation
        switch kind {
        case .audio:
            blob.message(field: 3, audioSettings(ssrc: ssrc))
        case .screen:
            blob.message(field: 5, screenSettings(ssrc: ssrc))
        }
        blob.string(field: 6, "Viceroy 1.7.0")
        blob.varint(field: 8, 0) // basebandCodecSampleRate (not used for this mode)
        for setting in Self.bandwidthSettings {
            blob.message(field: 9, setting.serialized)
        }
        blob.varint(field: 13, ntpTimestamp)
        blob.varint(field: 14, 2) // VCMediaNegotiationBlob version
        blob.varint(field: 16, 0) // mediaControlInfoVersion
        blob.varint(field: 18, Self.screenAccessNetworkType)
        return blob.data
    }

    private func audioSettings(ssrc: UInt32) -> Data {
        var audio = ProtobufEncoder()
        audio.varint(field: 1, UInt64(ssrc)) // rtpSSRC
        audio.varint(field: 2, 0)            // audioUnitModel
        audio.varint(field: 3, 0)            // supportFlags
        audio.varint(field: 4, 24_191)       // negotiated audio payload bitmap
        audio.varint(field: 5, 0)            // secondaryFlags
        audio.bool(field: 6, false)          // useSBR
        return audio.data
    }

    private func screenSettings(ssrc: UInt32) -> Data {
        var screen = ProtobufEncoder()
        screen.varint(field: 1, UInt64(ssrc)) // rtpSSRC
        screen.bool(field: 2, false)          // allowRTCPFB
        screen.message(field: 3, primaryScreenPayload())
        screen.message(field: 3, secondaryScreenPayload())
        screen.varint(
            field: 6,
            tilesPerFrame)  // tilesPerFrame
        screen.bool(field: 7, true)           // ltrpEnabled
        screen.varint(field: 8, 63)           // supported pixel-format bitmap
        screen.varint(field: 9, supportsHDR ? 9 : 1) // supported HDR-mode bitmap
        screen.bool(field: 12, true)          // blackFrameOnClearScreenEnabled
        return screen.data
    }

    private func primaryScreenPayload() -> Data {
        var payload = ProtobufEncoder()
        payload.varint(field: 1, 123)
        // The primary screen payload contains two encode/decode rule sets. They
        // represent the native primary and alternate format collections.
        for _ in 0..<2 {
            payload.message(field: 2, videoRule(operation: .encode))
            payload.message(field: 2, videoRule(operation: .decode))
        }
        payload.string(
            field: 3,
            "FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;"
                + "AR:\(aspectRatio.featureListValue);XR:\(aspectRatio.featureListValue);"
        )
        payload.varint(field: 4, 1)
        return payload.data
    }

    private func secondaryScreenPayload() -> Data {
        var payload = ProtobufEncoder()
        payload.varint(field: 1, 100)
        payload.message(field: 2, videoRule(operation: .encode))
        payload.message(field: 2, videoRule(operation: .decode))
        payload.string(
            field: 3,
            "FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;"
                + "AR:\(aspectRatio.featureListValue);XR:\(aspectRatio.featureListValue);"
        )
        payload.varint(field: 4, 14)
        return payload.data
    }

    private enum VideoOperation: UInt64 {
        case encode = 1
        case decode = 2
    }

    private func videoRule(operation: VideoOperation) -> Data {
        var rule = ProtobufEncoder()
        rule.varint(field: 1, Self.screenVideoTransportType)
        rule.varint(field: 2, operation.rawValue)
        rule.varint(field: 3, 50_115) // supported format bitmap
        rule.varint(field: 4, 0)      // preferred format index
        return rule.data
    }

    private func endpointInfo(_ endpoint: Endpoint) -> Data {
        var info = ProtobufEncoder()
        info.varint(field: 1, UInt64(endpoint.role))
        info.varint(field: 2, UInt64(endpoint.schemaVersion))
        info.string(field: 3, endpoint.productIdentifier)
        info.string(field: 4, endpoint.mediaSoftwareVersion)
        info.string(field: 5, endpoint.operatingSystemBuild)
        return info.data
    }

    /// Both legacy and extended bandwidth modes are included because the peer
    /// selects one according to its connection/profile type. Legacy maxima are
    /// in kbps; extended maxima are in bps.
    private static let bandwidthSettings: [BandwidthSetting] = [
        .init(legacyMode: 4_074, maximum: 0, extendedMode: 16_384),       // FaceTime 5G
        .init(legacyMode: 0, maximum: 6_000_000, extendedMode: 131_072), // multiway screen Wi-Fi
        .init(legacyMode: 0, maximum: 40_000_000, extendedMode: 12_288), // screen Wi-Fi
        .init(legacyMode: 1, maximum: 299),                               // default Wi-Fi
        .init(legacyMode: 0, maximum: 75_000_000, extendedMode: 524_288), // immersive video Wi-Fi
        .init(legacyMode: 0, maximum: 20_000_000, extendedMode: 98_304),  // low-latency screen Wi-Fi
        .init(legacyMode: 0, maximum: 60_000_000, extendedMode: 262_144), // low-latency screen wired
        .init(legacyMode: 16, maximum: 4_100),                            // legacy screen Wi-Fi
        .init(legacyMode: 0, maximum: 100_000_000, extendedMode: 1_048_576), // immersive video wired
        .init(legacyMode: 4, maximum: 6_500),                             // FaceTime Wi-Fi
    ]

    private struct BandwidthSetting: Sendable {
        let legacyMode: UInt64
        let maximum: UInt64
        var extendedMode: UInt64?

        init(legacyMode: UInt64, maximum: UInt64, extendedMode: UInt64? = nil) {
            self.legacyMode = legacyMode
            self.maximum = maximum
            self.extendedMode = extendedMode
        }

        var serialized: Data {
            var value = ProtobufEncoder()
            value.varint(field: 1, legacyMode)
            value.varint(field: 2, maximum)
            if let extendedMode {
                value.varint(field: 3, extendedMode)
            }
            return value.data
        }
    }

    static func ntpTimestamp(for date: Date = Date()) -> UInt64 {
        let interval = max(0, date.timeIntervalSince1970 + 2_208_988_800)
        let seconds = UInt64(interval.rounded(.down))
        let fraction = UInt64((interval - Double(seconds)) * 4_294_967_296)
        return (seconds << 32) | min(fraction, UInt64(UInt32.max))
    }

    private static func zlibCompress(_ input: Data) throws -> Data {
        var capacity = max(512, input.count * 2)
        while capacity <= 1_048_576 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { outputBytes in
                input.withUnsafeBytes { inputBytes in
                    compression_encode_buffer(
                        outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        inputBytes.bindMemory(to: UInt8.self).baseAddress!,
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 {
                output.count = written
                // Apple's Compression framework emits a raw DEFLATE payload
                // for COMPRESSION_ZLIB. Viceroy's `newDecompressedBlob:`
                // expects the complete RFC 1950 stream: CMF/FLG, DEFLATE data,
                // and the Adler-32 of the uncompressed protobuf.
                var zlib = Data([0x78, 0xda]) // deflate, 32 KiB window, max-level hint
                zlib.append(output)
                let checksum = adler32(input)
                zlib.append(UInt8((checksum >> 24) & 0xff))
                zlib.append(UInt8((checksum >> 16) & 0xff))
                zlib.append(UInt8((checksum >> 8) & 0xff))
                zlib.append(UInt8(checksum & 0xff))
                return zlib
            }
            capacity *= 2
        }
        throw VNCProtocolError.ioError("Could not compress Apple media negotiation blob")
    }

    private static func adler32(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }
}

private struct ProtobufEncoder {
    private(set) var data = Data()

    mutating func varint(field: UInt64, _ value: UInt64) {
        appendVarint((field << 3) | 0)
        appendVarint(value)
    }

    mutating func bool(field: UInt64, _ value: Bool) {
        varint(field: field, value ? 1 : 0)
    }

    mutating func string(field: UInt64, _ value: String) {
        bytes(field: field, Data(value.utf8))
    }

    mutating func message(field: UInt64, _ value: Data) {
        bytes(field: field, value)
    }

    private mutating func bytes(field: UInt64, _ value: Data) {
        appendVarint((field << 3) | 2)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}
