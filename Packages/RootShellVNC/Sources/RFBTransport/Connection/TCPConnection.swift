import Foundation
import Network
import RFBProtocol

enum NetworkPathInterfaceKind: Sendable, Equatable {
    case cellular
    case wifi
    case wiredEthernet
    case loopback
    case other
}

struct NetworkPathCharacteristics: Sendable, Equatable {
    let interface: NetworkPathInterfaceKind
    let usesOtherInterface: Bool
    let isExpensive: Bool
    let isConstrained: Bool
}

/// Async wrapper around NWConnection for TCP communication with an RFB server.
///
/// This actor provides a clean async/await interface over Apple's Network framework,
/// handling connection lifecycle, data reading, and sending.
public actor TCPConnection {

    // MARK: - Properties

    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private var connected: Bool = false
    private let log = VNCLogger(category: "TCPConnection")

    // MARK: - Init

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    // MARK: - Connection lifecycle

    /// Connect to the remote host. Throws on failure or timeout.
    public func connect() async throws {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = conn

        log.info("Connecting to \(host):\(port)")

        let logger = log
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeBox = ConnectionResumeBox(continuation: continuation)
            conn.stateUpdateHandler = { [weak conn] state in
                switch state {
                case .ready:
                    conn?.stateUpdateHandler = nil
                    resumeBox.resume()
                case .failed(let error):
                    conn?.stateUpdateHandler = nil
                    conn?.cancel()
                    resumeBox.resume(throwing: VNCProtocolError.ioError("Connection failed: \(error.localizedDescription)"))
                case .cancelled:
                    conn?.stateUpdateHandler = nil
                    resumeBox.resume(throwing: VNCProtocolError.connectionClosed)
                case .waiting(let error):
                    logger.warning("Connection waiting: \(error.localizedDescription)")
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10) { [weak conn] in
                if resumeBox.resume(throwing: VNCProtocolError.ioError("Connection timed out")) {
                    conn?.stateUpdateHandler = nil
                    conn?.cancel()
                }
            }
        }

        connected = true
        log.info("Connected to \(host):\(port)")
    }

    /// Read exactly `count` bytes from the connection. Throws on error or EOF.
    public func read(exactly count: Int) async throws -> Data {
        guard let conn = connection else {
            throw VNCProtocolError.connectionClosed
        }

        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: VNCProtocolError.ioError("Read error: \(error.localizedDescription)"))
                } else if let data = content, data.count == count {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: VNCProtocolError.connectionClosed)
                } else if let data = content {
                    // Got fewer bytes than requested — should not happen with minimumIncompleteLength
                    // but handle gracefully by treating as partial read failure
                    continuation.resume(throwing: VNCProtocolError.ioError(
                        "Short read: expected \(count) bytes, got \(data.count)"))
                } else {
                    continuation.resume(throwing: VNCProtocolError.connectionClosed)
                }
            }
        }
    }

    /// Read up to `maxCount` bytes (at least 1). Useful when the exact size is unknown.
    public func read(upTo maxCount: Int) async throws -> Data {
        guard let conn = connection else {
            throw VNCProtocolError.connectionClosed
        }

        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: 1, maximumLength: maxCount) { content, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: VNCProtocolError.ioError("Read error: \(error.localizedDescription)"))
                } else if let data = content, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: VNCProtocolError.connectionClosed)
                } else {
                    continuation.resume(throwing: VNCProtocolError.connectionClosed)
                }
            }
        }
    }

    /// Send data to the server. Throws on error.
    public func send(_ data: Data) async throws {
        guard let conn = connection else {
            throw VNCProtocolError.connectionClosed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: VNCProtocolError.ioError("Send error: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }

        log.debug("Sent \(data.count) bytes")
    }

    /// Gracefully close the connection.
    public nonisolated func close() {
        // NWConnection.cancel() is thread-safe and can be called from any context.
        // We access properties in a fire-and-forget Task to maintain actor isolation.
        Task { await self.performClose() }
    }

    private func performClose() {
        log.info("Closing connection to \(host):\(port)")
        connection?.cancel()
        connection = nil
        connected = false
    }

    /// Whether the connection is currently established.
    public var isConnected: Bool {
        connected
    }

    /// Snapshot the route selected for the actual RFB connection. This is more
    /// accurate than a process-wide path monitor when a VPN or multiple active
    /// interfaces are present.
    func pathCharacteristics() -> NetworkPathCharacteristics? {
        guard let path = connection?.currentPath else { return nil }
        let interface: NetworkPathInterfaceKind
        if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wiredEthernet
        } else if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.loopback) {
            interface = .loopback
        } else {
            interface = .other
        }
        return NetworkPathCharacteristics(
            interface: interface,
            usesOtherInterface: path.usesInterfaceType(.other),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained)
    }
}

private final class ConnectionResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Void, Error>

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        continuation.resume()
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        continuation.resume(throwing: error)
        return true
    }
}
