import Foundation
import Network
import NIOCore
@preconcurrency import NIOSSL
import NIOTLS
import NIOTransportServices
import RFBProtocol
import Security

public enum NetworkPathInterfaceKind: Sendable, Equatable {
    case cellular
    case wifi
    case wiredEthernet
    case loopback
    case other
}

public struct NetworkPathCharacteristics: Sendable, Equatable {
    public let interface: NetworkPathInterfaceKind
    public let usesOtherInterface: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool

    public init(
        interface: NetworkPathInterfaceKind,
        usesOtherInterface: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) {
        self.interface = interface
        self.usesOtherInterface = usesOtherInterface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

/// Async TCP byte stream backed by Network.framework through NIO Transport
/// Services. Keeping the channel in a NIO pipeline lets VeNCrypt insert an
/// NIOSSL handler after the plaintext RFB security negotiation (STARTTLS).
public actor TCPConnection: RFBConnection {
    private static let eventLoopGroup = NIOTSEventLoopGroup(
        loopCount: 1,
        defaultQoS: .userInitiated)

    private let host: String
    private let port: UInt16
    private let log = VNCLogger(category: "TCPConnection")
    private var channel: Channel?
    private var inboundHandler: InboundByteStreamHandler?
    private var inboundQueue: InboundByteQueue?
    private var disconnectHandler: (@Sendable (VNCProtocolError) -> Void)?
    private var connected = false
    private var isClosing = false

    /// User-space read buffer. RFB parsing does many small field-sized reads,
    /// so a single channel read is shared across subsequent parser requests.
    private var receiveBuffer = Data()
    private var receiveOffset = 0
    private static let compactionThreshold = 64 * 1024

    /// Dial retry tuning; injectable so tests don't sit through real backoffs.
    private let maxDialAttempts: Int
    private let dialRetryBackoffNanos: UInt64
    private let connectTimeoutSeconds: Int

    public init(host: String, port: UInt16) {
        self.init(
            host: host, port: port,
            maxDialAttempts: 3,
            dialRetryBackoffNanos: 1_000_000_000,
            connectTimeoutSeconds: 10)
    }

    init(
        host: String,
        port: UInt16,
        maxDialAttempts: Int,
        dialRetryBackoffNanos: UInt64,
        connectTimeoutSeconds: Int
    ) {
        self.host = host
        self.port = port
        self.maxDialAttempts = max(1, maxDialAttempts)
        self.dialRetryBackoffNanos = dialRetryBackoffNanos
        self.connectTimeoutSeconds = max(1, connectTimeoutSeconds)
    }

    public func connect() async throws {
        guard channel == nil else { return }
        isClosing = false
        receiveBuffer.removeAll(keepingCapacity: true)
        receiveOffset = 0

        // On-demand VPNs (Tailscale and friends) bring their tunnel up in
        // response to the first dial, which can fail before the route exists.
        // Retry briefly so the tunnel warmed by a failed attempt gets used,
        // instead of surfacing the failure and making the user reconnect.
        for attempt in 1...maxDialAttempts {
            let attemptStart = DispatchTime.now().uptimeNanoseconds
            do {
                try await dialOnce()
                return
            } catch {
                // Elapsed time discriminates failure modes: ~instant means
                // refused/unroutable, ~connectTimeout means the dial sat in
                // Network.framework's .waiting (cold DNS or path not ready).
                let elapsedMilliseconds =
                    (DispatchTime.now().uptimeNanoseconds &- attemptStart) / 1_000_000
                guard attempt < maxDialAttempts, !isClosing else {
                    log.error(
                        "Connect attempt \(attempt)/\(maxDialAttempts) to \(host):\(port) "
                            + "failed after \(elapsedMilliseconds)ms "
                            + "(\(error.localizedDescription)); giving up")
                    throw error
                }
                log.warning(
                    "Connect attempt \(attempt)/\(maxDialAttempts) to \(host):\(port) "
                        + "failed after \(elapsedMilliseconds)ms "
                        + "(\(error.localizedDescription)); retrying")
                try await Task.sleep(nanoseconds: UInt64(attempt) * dialRetryBackoffNanos)
                guard !isClosing else { throw error }
            }
        }
    }

    private func dialOnce() async throws {
        let handler = InboundByteStreamHandler { [weak self] error in
            Task { await self?.notifyUnexpectedDisconnect(error) }
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        tcpOptions.connectionTimeout = connectTimeoutSeconds

        let bootstrap = NIOTSConnectionBootstrap(group: Self.eventLoopGroup)
            .connectTimeout(.seconds(Int64(connectTimeoutSeconds)))
            .withQoS(.userInitiated)
            .tcpOptions(tcpOptions)
            // RFB framebuffer processing applies its own credit-based
            // backpressure. Read only when the parser needs another chunk so
            // a paused renderer also stops draining the kernel socket.
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(NIOTSChannelOptions.allowLocalEndpointReuse, value: true)
            .configureNWParameters { parameters in
                parameters.serviceClass = .responsiveData
            }
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        log.info("Connecting to \(host):\(port)")
        do {
            let connectedChannel = try await bootstrap
                .connect(host: host, port: Int(port))
                .get()
            channel = connectedChannel
            inboundHandler = handler
            inboundQueue = handler.queue
            connected = true
            log.info("Connected to \(host):\(port)")
        } catch {
            let protocolError = VNCProtocolError.ioError(
                "Connection failed: \(error.localizedDescription)")
            handler.finish(throwing: protocolError)
            throw protocolError
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count >= 0 else {
            throw VNCProtocolError.protocolViolation("Negative read length")
        }
        while bufferedByteCount < count {
            try await fillBuffer()
        }
        return consumeBuffered(count)
    }

    public func read(upTo maxCount: Int) async throws -> Data {
        guard maxCount > 0 else {
            throw VNCProtocolError.protocolViolation("Read length must be positive")
        }
        if bufferedByteCount == 0 {
            try await fillBuffer()
        }
        return consumeBuffered(min(bufferedByteCount, maxCount))
    }

    private var bufferedByteCount: Int {
        receiveBuffer.count - receiveOffset
    }

    private func fillBuffer() async throws {
        guard let inboundQueue, let channel else {
            throw VNCProtocolError.connectionClosed
        }
        do {
            let data = try await inboundQueue.next {
                channel.read()
            }
            if !data.isEmpty { receiveBuffer.append(data) }
        } catch let error as VNCProtocolError {
            throw error
        } catch {
            throw VNCProtocolError.ioError("Read error: \(error.localizedDescription)")
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

    public func send(_ data: Data) async throws {
        guard let channel, channel.isActive else {
            throw VNCProtocolError.connectionClosed
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            throw VNCProtocolError.ioError("Send error: \(error.localizedDescription)")
        }
        log.debug("Sent \(data.count) bytes")
    }

    public func close() async {
        isClosing = true
        log.info("Closing connection to \(host):\(port)")
        if let channel {
            try? await channel.close().get()
        }
        inboundHandler?.finish()
        channel = nil
        inboundHandler = nil
        inboundQueue = nil
        connected = false
        receiveBuffer.removeAll()
        receiveOffset = 0
    }

    public var isConnected: Bool { connected }

    public func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) {
        disconnectHandler = handler
    }

    private func notifyUnexpectedDisconnect(_ error: VNCProtocolError) {
        connected = false
        guard !isClosing else { return }
        disconnectHandler?(error)
    }

    public func pathCharacteristics() async -> NetworkPathCharacteristics? {
        guard let channel else { return nil }
        guard let path = try? await channel
            .getOption(NIOTSChannelOptions.currentPath)
            .get() else { return nil }
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

    public func supportsTLSUpgrade() async -> Bool { true }

    public func startTLS(configuration: RFBTLSConfiguration) async throws {
        guard let channel, let inboundHandler else {
            throw VNCProtocolError.connectionClosed
        }

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .fullVerification
        tlsConfiguration.trustRoots = .default
        let context: NIOSSLContext
        do {
            context = try NIOSSLContext(configuration: tlsConfiguration)
        } catch {
            throw VNCProtocolError.ioError(
                "Could not initialize TLS: \(error.localizedDescription)")
        }

        let sslHandler: NIOSSLClientHandler
        do {
            let host = Self.unbracketedHost(configuration.serverHostname)
            let tlsServerName = Self.tlsServerName(for: host)
            let isIPAddress = tlsServerName == nil
            let validationHandler = configuration.certificateValidationHandler
            if validationHandler != nil || isIPAddress {
                sslHandler = try NIOSSLClientHandler(
                    context: context,
                    // NIOSSL intentionally rejects IP literals as SNI names.
                    // Certificate identity for literals is checked below by
                    // Security.framework using the original endpoint.
                    serverHostname: tlsServerName,
                    customVerificationCallback: { certificates, promise in
                        Self.validateCertificateChain(
                            certificates,
                            host: host,
                            port: configuration.serverPort,
                            validationHandler: validationHandler,
                            promise: promise)
                    })
            } else {
                sslHandler = try NIOSSLClientHandler(
                    context: context,
                    serverHostname: configuration.serverHostname)
            }
            let sendableHandler = SendableSSLHandler(sslHandler)
            inboundHandler.beginTLSHandshake()
            // Build and install the non-Sendable NIOSSL handler entirely on
            // the channel's event loop. Only the explicitly synchronized box
            // crosses from this actor to the event-loop closure.
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(
                    sendableHandler.value,
                    position: .first)
            }.get()
            channel.read()
            try await inboundHandler.waitForTLSHandshake()
        } catch let error as VNCProtocolError {
            throw error
        } catch {
            throw VNCProtocolError.authenticationFailed(
                "TLS handshake failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func validateCertificateChain(
        _ certificates: [NIOSSLCertificate],
        host: String,
        port: UInt16,
        validationHandler: VNCCertificateValidationHandler?,
        promise: EventLoopPromise<NIOSSLVerificationResult>
    ) {
        let derChain: [Data]
        do {
            derChain = try certificates.map { Data(try $0.toDERBytes()) }
        } catch {
            promise.succeed(.failed)
            return
        }

        let queue = DispatchQueue(
            label: "com.rootshell.vnc.certificate-validation",
            qos: .userInitiated)
        queue.async {
            if platformTrusts(derChain: derChain, hostname: host) {
                promise.succeed(.certificateVerified)
                return
            }
            guard let validationHandler else {
                promise.succeed(.failed)
                return
            }
            Task {
                let request = VNCCertificateValidationRequest(
                    host: host,
                    port: port,
                    certificateChainDER: derChain)
                let result = await validationHandler(request)
                switch result {
                case .acceptOnce, .acceptAndStore:
                    promise.succeed(.certificateVerified)
                case .reject:
                    promise.succeed(.failed)
                }
            }
        }
    }

    private nonisolated static func platformTrusts(
        derChain: [Data],
        hostname: String
    ) -> Bool {
        let certificates = derChain.compactMap {
            SecCertificateCreateWithData(nil, $0 as CFData)
        }
        guard certificates.count == derChain.count, !certificates.isEmpty else {
            return false
        }
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(
            certificates as CFArray,
            policy,
            &trust) == errSecSuccess,
            let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    private nonisolated static func unbracketedHost(_ host: String) -> String {
        guard host.first == "[", host.last == "]" else { return host }
        return String(host.dropFirst().dropLast())
    }

    private nonisolated static func isIPAddress(_ host: String) -> Bool {
        IPv4Address(host) != nil || IPv6Address(host) != nil
    }

    /// NIOSSL accepts DNS names for SNI/identity checking but rejects IP
    /// literals at handler construction time. IP identity is instead checked
    /// by ``platformTrusts(derChain:hostname:)``.
    nonisolated static func tlsServerName(for endpointHost: String) -> String? {
        let host = unbracketedHost(endpointHost)
        return isIPAddress(host) ? nil : host
    }
}

private final class InboundByteStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let queue = InboundByteQueue()
    private let disconnect: @Sendable (VNCProtocolError) -> Void
    private let lock = NSLock()
    private var tlsResult: Result<Void, Error>?
    private var tlsContinuation: CheckedContinuation<Void, Error>?
    private var tlsHandshakePending = false
    private var didFinish = false

    init(disconnect: @escaping @Sendable (VNCProtocolError) -> Void) {
        self.disconnect = disconnect
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        queue.yield(Data(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            completeTLS(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        lock.lock()
        let continueTLSReads = tlsHandshakePending
        lock.unlock()
        if continueTLSReads {
            context.read()
        }
        context.fireChannelReadComplete()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let protocolError = VNCProtocolError.ioError(error.localizedDescription)
        completeTLS(.failure(protocolError))
        finish(throwing: protocolError)
        disconnect(protocolError)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let error = VNCProtocolError.connectionClosed
        completeTLS(.failure(error))
        finish(throwing: error)
        disconnect(error)
        context.fireChannelInactive()
    }

    func waitForTLSHandshake() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let tlsResult {
                lock.unlock()
                continuation.resume(with: tlsResult)
            } else {
                tlsContinuation = continuation
                lock.unlock()
            }
        }
    }

    func beginTLSHandshake() {
        lock.lock()
        tlsHandshakePending = true
        lock.unlock()
    }

    private func completeTLS(_ result: Result<Void, Error>) {
        lock.lock()
        guard tlsResult == nil else {
            lock.unlock()
            return
        }
        tlsResult = result
        tlsHandshakePending = false
        let continuation = tlsContinuation
        tlsContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        queue.finish(throwing: error ?? VNCProtocolError.connectionClosed)
    }
}

private final class InboundByteQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var terminalError: Error?

    func yield(_ data: Data) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            buffered.append(data)
            lock.unlock()
        }
    }

    func next(onReadNeeded: @escaping @Sendable () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffered.isEmpty {
                let data = buffered.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else if let terminalError {
                lock.unlock()
                continuation.resume(throwing: terminalError)
            } else {
                precondition(waiter == nil, "RFB byte stream supports one reader")
                waiter = continuation
                lock.unlock()
                onReadNeeded()
            }
        }
    }

    func finish(throwing error: Error) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        terminalError = error
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }
}

private final class SendableSSLHandler: @unchecked Sendable {
    let value: NIOSSLClientHandler

    init(_ value: NIOSSLClientHandler) {
        self.value = value
    }
}
