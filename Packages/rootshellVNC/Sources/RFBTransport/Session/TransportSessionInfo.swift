import Foundation
import RFBProtocol

// MARK: - Content encryption

/// Semantic description of whether session content is encrypted on the wire.
///
/// This describes only what the RFB layer itself provides; a host-injected
/// tunnel (SSH) may encrypt an otherwise-plaintext session at a lower layer.
public enum VNCContentEncryption: Sendable, Equatable {
    /// VeNCrypt X.509 TLS wraps the entire RFB stream.
    case tlsX509
    /// Apple ComCryption: the control channel is AES-CBC encrypted and, when
    /// `mediaSRTP` is true, the accelerated UDP media path is SRTP-protected.
    /// `cipherMode`/`keyLength` mirror the server's EncryptionInfo record
    /// when one has arrived.
    case appleComCryption(cipherMode: UInt32?, keyLength: UInt32?, mediaSRTP: Bool)
    /// Content is not encrypted by the RFB layer (authentication, if any,
    /// protected only the credential exchange).
    case none
}

// MARK: - Handshake snapshot

/// Immutable snapshot of negotiated handshake facts, valid once the
/// connection reaches ServerInit.
public struct TransportHandshakeInfo: Sendable, Equatable {
    /// The version string the server reported, before client selection.
    public let serverReportedVersion: ProtocolVersion?
    /// The version the client answered with (the operative protocol level).
    public let negotiatedVersion: ProtocolVersion?
    /// Security types the server offered. On the RFB 3.3 server-selected
    /// path this holds just the server's choice.
    public let offeredSecurityTypes: [SecurityType]
    /// The security type actually used for authentication.
    public let selectedSecurityType: SecurityType?
    public let contentEncryption: VNCContentEncryption
    /// Structured command support advertised by an Apple RFB 3.889 server;
    /// nil for regular RFB servers.
    public let appleServerCapabilities: AppleServerCapabilities?
}

// MARK: - Live statistics

/// Per-encoding traffic seen in standard-mode framebuffer updates.
public struct EncodingUsage: Sendable, Equatable {
    public let encoding: Encoding
    public let rectangles: UInt64
    public let bytes: UInt64
}

/// Immutable live-statistics snapshot. Cumulative counters cover the current
/// connection; `recent*` fields describe the window since the previous
/// `statisticsSnapshot()` call and are nil on the first call or when the
/// window is too short to be meaningful.
public struct TransportStatistics: Sendable, Equatable {
    /// Whether Apple's accelerated UDP media path is active.
    public let isHighPerformanceMode: Bool

    // Apple media (High Performance) path, all zero in standard mode.
    public let mediaBytesReceived: UInt64
    public let mediaPacketsReceived: UInt64
    public let audioPacketsReceived: UInt64
    /// Packets confirmed lost after the reorder window expired.
    public let packetsLostCumulative: UInt64
    public let bandwidthEstimateKbps: Double?
    /// Windowed receive rate from the rate controller.
    public let throughputKbps: Double?
    public let queueDelayMilliseconds: Double?
    public let oneWayRelativeDelayMilliseconds: Double?
    public let videoSourceCount: Int

    // Standard (TCP framebuffer) path, near-zero once HEVC media takes over.
    /// Framebuffer message bytes including rectangle headers and payloads.
    public let framebufferBytesReceived: UInt64
    public let framebufferUpdateCount: UInt64
    public let framebufferRectCount: UInt64
    /// Content-rectangle traffic by encoding, sorted by bytes descending.
    public let encodingUsage: [EncodingUsage]

    // Sliding window over media + framebuffer bytes combined.
    public let recentInterval: TimeInterval?
    public let recentBitrateKbps: Double?
    /// Loss share of packets expected in the recent window (media path only).
    public let recentPacketLossPercent: Double?

    // Liveness. In High Performance mode the video and rate-control traffic is
    // UDP and what stays on TCP is request/response, so an idle remote desktop
    // legitimately leaves the control channel silent. That silence is also the
    // condition TCP keepalive acts on, which makes these the numbers to look at
    // when a session drops for no visible reason. Keepalive arms only once the
    // socket is quiet in *both* directions, so read the two together.
    /// Seconds since the read loop last took bytes off the control channel,
    /// or nil before the first post-handshake read.
    public let secondsSinceControlChannelByte: TimeInterval?
    /// Cumulative bytes the read loop has taken off the control channel.
    public let controlChannelBytesReceived: UInt64
    /// Seconds since the last control-channel write, or nil if there has been
    /// none on this connection.
    public let secondsSinceControlChannelSend: TimeInterval?
    /// Cumulative bytes written to the control channel.
    public let controlChannelBytesSent: UInt64
    /// Seconds since the last video RTP packet was ingested, or nil if none
    /// has arrived (including every standard-mode session).
    public let secondsSinceVideoRTPPacket: TimeInterval?
    /// Seconds since the handshake completed, or nil if it has not.
    public let connectionUptime: TimeInterval?
}
