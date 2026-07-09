import Foundation
import RFBProtocol

/// Captures diagnostic information about a VNC connection attempt.
///
/// This class records details about the handshake, authentication,
/// and connection lifecycle for debugging and troubleshooting.
///
/// Access diagnostics from a session:
/// ```swift
/// let diagnostics = session.getDiagnostics()
/// print(diagnostics.summary())
/// ```
public final class ConnectionDiagnostics: @unchecked Sendable {

    // MARK: - Properties

    private let lock = NSLock()

    /// The protocol version reported by the server during the handshake.
    public var serverVersion: ProtocolVersion? {
        get { withLock { _serverVersion } }
        set { withLock { _serverVersion = newValue } }
    }
    private var _serverVersion: ProtocolVersion?

    /// The protocol version selected by the client.
    public var clientVersion: ProtocolVersion? {
        get { withLock { _clientVersion } }
        set { withLock { _clientVersion = newValue } }
    }
    private var _clientVersion: ProtocolVersion?

    /// The security types offered by the server.
    public var offeredSecurityTypes: [SecurityType] {
        get { withLock { _offeredSecurityTypes } }
        set { withLock { _offeredSecurityTypes = newValue } }
    }
    private var _offeredSecurityTypes: [SecurityType] = []

    /// The security type selected for the connection.
    public var selectedSecurityType: SecurityType? {
        get { withLock { _selectedSecurityType } }
        set { withLock { _selectedSecurityType = newValue } }
    }
    private var _selectedSecurityType: SecurityType?

    /// The ServerInit message received after authentication.
    public var serverInit: ServerInit? {
        get { withLock { _serverInit } }
        set { withLock { _serverInit = newValue } }
    }
    private var _serverInit: ServerInit?

    /// A description of the encryption mode in use, if any.
    public var encryptionMode: String? {
        get { withLock { _encryptionMode } }
        set { withLock { _encryptionMode = newValue } }
    }
    private var _encryptionMode: String?

    /// Whether the connection is using high-performance mode (HEVC/H.264).
    public var isHighPerformanceMode: Bool {
        get { withLock { _isHighPerformanceMode } }
        set { withLock { _isHighPerformanceMode = newValue } }
    }
    private var _isHighPerformanceMode: Bool = false

    /// When the connection attempt began.
    public var connectionStartTime: Date? {
        get { withLock { _connectionStartTime } }
        set { withLock { _connectionStartTime = newValue } }
    }
    private var _connectionStartTime: Date?

    /// When the handshake completed successfully.
    public var handshakeCompleteTime: Date? {
        get { withLock { _handshakeCompleteTime } }
        set { withLock { _handshakeCompleteTime = newValue } }
    }
    private var _handshakeCompleteTime: Date?

    /// The last protocol error that occurred, if any.
    public var lastError: VNCProtocolError? {
        get { withLock { _lastError } }
        set { withLock { _lastError = newValue } }
    }
    private var _lastError: VNCProtocolError?

    /// The protocol trace recorder for this connection.
    public var protocolTrace: ProtocolTrace {
        get { withLock { _protocolTrace } }
        set { withLock { _protocolTrace = newValue } }
    }
    private var _protocolTrace: ProtocolTrace = ProtocolTrace()

    // MARK: - Init

    /// Create a new connection diagnostics instance.
    public init() {}

    // MARK: - Computed Properties

    /// The time taken for the handshake to complete.
    ///
    /// Returns `nil` if the handshake has not completed.
    public var handshakeDuration: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let start = _connectionStartTime, let end = _handshakeCompleteTime else {
            return nil
        }
        return end.timeIntervalSince(start)
    }

    // MARK: - Operations

    /// Reset all diagnostic data to prepare for a new connection.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _serverVersion = nil
        _clientVersion = nil
        _offeredSecurityTypes = []
        _selectedSecurityType = nil
        _serverInit = nil
        _encryptionMode = nil
        _isHighPerformanceMode = false
        _connectionStartTime = nil
        _handshakeCompleteTime = nil
        _lastError = nil
        _protocolTrace = ProtocolTrace()
    }

    /// Generate a human-readable summary of the connection diagnostics.
    ///
    /// - Returns: A multi-line string containing key diagnostic details.
    public func summary() -> String {
        lock.lock()
        defer { lock.unlock() }

        var lines: [String] = []
        lines.append("=== VNC Connection Diagnostics ===")

        if let sv = _serverVersion {
            lines.append("Server Version: \(sv)")
        }
        if let cv = _clientVersion {
            lines.append("Client Version: \(cv)")
        }

        if !_offeredSecurityTypes.isEmpty {
            let types = _offeredSecurityTypes.map { "\($0)" }.joined(separator: ", ")
            lines.append("Offered Security Types: \(types)")
        }
        if let selected = _selectedSecurityType {
            lines.append("Selected Security Type: \(selected)")
        }

        if let si = _serverInit {
            lines.append("Server Name: \(si.name)")
            lines.append("Framebuffer: \(si.framebufferWidth)x\(si.framebufferHeight)")
            lines.append("Pixel Format: \(si.pixelFormat.bitsPerPixel)bpp, depth=\(si.pixelFormat.depth)")
        }

        if let enc = _encryptionMode {
            lines.append("Encryption: \(enc)")
        }
        lines.append("High-Performance Mode: \(_isHighPerformanceMode)")

        if let start = _connectionStartTime {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            lines.append("Connection Started: \(formatter.string(from: start))")
        }

        if let start = _connectionStartTime, let end = _handshakeCompleteTime {
            let duration = end.timeIntervalSince(start)
            lines.append("Handshake Duration: \(String(format: "%.3f", duration))s")
        }

        if let error = _lastError {
            lines.append("Last Error: \(error.localizedDescription)")
        }

        lines.append("Trace Entries: \(_protocolTrace.count)")
        lines.append("==================================")

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
