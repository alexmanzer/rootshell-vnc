import Foundation
import Network
import RFBProtocol

/// UDP channel for receiving HEVC video streams and sending control messages.
///
/// This actor wraps NWConnection (or NWListener for receiving) to provide
/// an async/await interface for UDP datagram communication.
public actor UDPChannel {

    // MARK: - Properties

    private var listener: NWListener?
    private var connectedConnection: NWConnection?
    private var incomingConnections: [NWConnection] = []
    private let requestedPort: UInt16?
    private let remoteHost: String?
    private let remotePort: UInt16?
    private var boundPort: UInt16?
    private var isRunning: Bool = false
    private let log = VNCLogger(category: "UDPChannel")

    /// Pending receive continuations. Datagrams are queued and delivered in order.
    private var receiveContinuations: [CheckedContinuation<Data, Error>] = []
    private var datagramQueue: [Data] = []

    // MARK: - Init

    /// Create a UDP channel.
    /// - Parameter localPort: If provided, bind to this specific port. If nil, let the OS choose.
    public init(localPort: UInt16?, remoteHost: String? = nil, remotePort: UInt16? = nil) {
        self.requestedPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    // MARK: - Lifecycle

    /// Start listening for UDP packets.
    public func start() async throws {
        if let remoteHost, let remotePort {
            try await startConnected(remoteHost: remoteHost, remotePort: remotePort)
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let port: NWEndpoint.Port
        if let p = requestedPort {
            port = NWEndpoint.Port(rawValue: p)!
        } else {
            port = .any
        }

        let lst = try NWListener(using: params, on: port)
        self.listener = lst

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lst.stateUpdateHandler = { [weak lst] state in
                switch state {
                case .ready:
                    lst?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    lst?.stateUpdateHandler = nil
                    continuation.resume(throwing: VNCProtocolError.ioError("UDP listener failed: \(error.localizedDescription)"))
                case .cancelled:
                    lst?.stateUpdateHandler = nil
                    continuation.resume(throwing: VNCProtocolError.connectionClosed)
                default:
                    break
                }
            }

            lst.newConnectionHandler = { [weak self] newConn in
                Task { [weak self] in
                    await self?.handleIncomingConnection(newConn)
                }
            }

            lst.start(queue: .global(qos: .userInitiated))
        }

        if let actualPort = lst.port?.rawValue {
            boundPort = actualPort
        }

        isRunning = true
        log.info("UDP channel started on port \(boundPort.map(String.init) ?? "unknown")")
    }

    private func startConnected(remoteHost: String, remotePort: UInt16) async throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        if let requestedPort {
            let localPort = NWEndpoint.Port(rawValue: requestedPort)!
            params.requiredLocalEndpoint = .hostPort(
                host: .ipv4(IPv4Address("0.0.0.0")!),
                port: localPort
            )
        }

        let remoteNWPort = NWEndpoint.Port(rawValue: remotePort)!
        let conn = NWConnection(host: NWEndpoint.Host(remoteHost), port: remoteNWPort, using: params)
        connectedConnection = conn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak conn] state in
                switch state {
                case .ready:
                    conn?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    conn?.stateUpdateHandler = nil
                    continuation.resume(throwing: VNCProtocolError.ioError(
                        "UDP connection failed: \(error.localizedDescription)"))
                case .cancelled:
                    conn?.stateUpdateHandler = nil
                    continuation.resume(throwing: VNCProtocolError.connectionClosed)
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
        }

        boundPort = requestedPort
        isRunning = true
        receiveLoop(on: conn)
        log.info("UDP channel connected from port \(boundPort.map(String.init) ?? "unknown") to \(remoteHost):\(remotePort)")
    }

    /// Receive the next datagram. Blocks until a datagram is available.
    public func receive() async throws -> Data {
        // If we have queued datagrams, return immediately
        if !datagramQueue.isEmpty {
            return datagramQueue.removeFirst()
        }

        // Otherwise wait for one
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuations.append(continuation)
        }
    }

    /// Send a datagram to the specified endpoint.
    public func send(_ data: Data) async throws {
        guard let conn = connectedConnection else {
            throw VNCProtocolError.protocolViolation("UDP channel is not connected")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: VNCProtocolError.ioError(
                        "UDP send error: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Send a datagram to the specified endpoint.
    public func send(_ data: Data, to endpoint: NWEndpoint) async throws {
        if connectedConnection != nil {
            try await send(data)
            return
        }

        let params = NWParameters.udp
        let conn = NWConnection(to: endpoint, using: params)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: data, completion: .contentProcessed { error in
                        if let error = error {
                            continuation.resume(throwing: VNCProtocolError.ioError(
                                "UDP send error: \(error.localizedDescription)"))
                        } else {
                            continuation.resume()
                        }
                        conn.cancel()
                    })
                case .failed(let error):
                    continuation.resume(throwing: VNCProtocolError.ioError(
                        "UDP connection failed: \(error.localizedDescription)"))
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Close the channel.
    public func close() {
        log.info("Closing UDP channel")
        connectedConnection?.cancel()
        connectedConnection = nil
        listener?.cancel()
        listener = nil
        for connection in incomingConnections {
            connection.cancel()
        }
        incomingConnections.removeAll()
        isRunning = false

        // Cancel any waiting receivers
        let pending = receiveContinuations
        receiveContinuations.removeAll()
        for cont in pending {
            cont.resume(throwing: VNCProtocolError.connectionClosed)
        }
    }

    /// The local port this channel is bound to (after start).
    public var localPort: UInt16? {
        boundPort
    }

    // MARK: - Private

    private func handleIncomingConnection(_ conn: NWConnection) {
        incomingConnections.append(conn)
        conn.start(queue: .global(qos: .userInitiated))
        receiveLoop(on: conn)
    }

    private nonisolated func receiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                Task {
                    await self.enqueueDatagram(data)
                }
            }

            if error == nil {
                self.receiveLoop(on: conn)
            }
        }
    }

    private func enqueueDatagram(_ data: Data) {
        if !receiveContinuations.isEmpty {
            let cont = receiveContinuations.removeFirst()
            cont.resume(returning: data)
        } else {
            datagramQueue.append(data)
        }
    }
}
