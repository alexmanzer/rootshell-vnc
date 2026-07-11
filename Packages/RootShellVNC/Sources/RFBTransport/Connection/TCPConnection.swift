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

    /// User-space read buffer. RFB parsing does many tiny field-sized reads
    /// (headers, length prefixes); serving them from one large kernel receive
    /// avoids a Network.framework round-trip per field.
    private var receiveBuffer = Data()
    private var receiveOffset = 0
    private var receivedEOF = false

    /// Upper bound for a single kernel receive when filling the buffer.
    private static let receiveChunkLimit = 256 * 1024
    /// Compact the buffer once this much consumed prefix has accumulated.
    private static let compactionThreshold = 64 * 1024

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
        // RFB is a request/response protocol built from small messages
        // (10-byte update requests, 6-byte pointer events). Nagle would hold
        // those writes waiting for a delayed ACK, adding up to ~200ms per
        // round trip, so disable it like every mainstream VNC client does.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.connectionTimeout = 10
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .responsiveData

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
        while bufferedByteCount < count {
            try await fillBuffer(minimum: count - bufferedByteCount)
            if receivedEOF && bufferedByteCount < count {
                throw VNCProtocolError.connectionClosed
            }
        }
        return consumeBuffered(count)
    }

    /// Read up to `maxCount` bytes (at least 1). Useful when the exact size is unknown.
    ///
    /// Must drain the user-space buffer before touching the socket: earlier
    /// large receives may already hold bytes that arrived glued to previous
    /// records, and bypassing the buffer would reorder the stream.
    public func read(upTo maxCount: Int) async throws -> Data {
        if bufferedByteCount == 0 {
            try await fillBuffer(minimum: 1, limit: maxCount)
            if bufferedByteCount == 0 {
                throw VNCProtocolError.connectionClosed
            }
        }
        return consumeBuffered(min(bufferedByteCount, maxCount))
    }

    private var bufferedByteCount: Int {
        receiveBuffer.count - receiveOffset
    }

    /// One kernel receive appended to the buffer. Requests at least `minimum`
    /// bytes but lets the kernel hand over whatever else has already arrived,
    /// so the small header/length/payload reads that follow are served from
    /// user space without further receives.
    private func fillBuffer(minimum: Int, limit: Int = TCPConnection.receiveChunkLimit) async throws {
        guard let conn = connection else {
            throw VNCProtocolError.connectionClosed
        }
        if receivedEOF {
            throw VNCProtocolError.connectionClosed
        }

        let (content, isComplete): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
            conn.receive(
                minimumIncompleteLength: minimum,
                maximumLength: max(minimum, limit)
            ) { content, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: VNCProtocolError.ioError("Read error: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: (content, isComplete))
                }
            }
        }

        if let content, !content.isEmpty {
            receiveBuffer.append(content)
        }
        if isComplete {
            receivedEOF = true
        }
    }

    private func consumeBuffered(_ count: Int) -> Data {
        let start = receiveBuffer.startIndex + receiveOffset
        let result = receiveBuffer.subdata(in: start..<(start + count))
        receiveOffset += count

        if receiveOffset == receiveBuffer.count {
            receiveBuffer.removeAll(keepingCapacity: true)
            receiveOffset = 0
        } else if receiveOffset > Self.compactionThreshold {
            receiveBuffer.removeFirst(receiveOffset)
            receiveOffset = 0
        }
        return result
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
        receiveBuffer.removeAll()
        receiveOffset = 0
        receivedEOF = false
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
