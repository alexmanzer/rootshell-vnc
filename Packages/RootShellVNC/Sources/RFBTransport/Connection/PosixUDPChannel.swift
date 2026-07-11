import Foundation
import Darwin
import RFBProtocol

/// Amortized-O(1) FIFO used between the socket read source and the transport
/// actor. `Array.removeFirst()` shifts every remaining element and made the old
/// queue progressively more expensive precisely when an RTP burst built a
/// backlog. This queue advances a head index and compacts only occasionally.
public struct PosixUDPDatagram: Sendable, Equatable {
    public let data: Data
    /// Monotonic timestamp captured as the datagram is drained from the socket.
    /// Keeping this with the bytes lets congestion control see userspace/actor
    /// queueing instead of mistaking delayed processing for network arrival.
    public let arrivalNanos: UInt64

    public init(data: Data, arrivalNanos: UInt64) {
        self.data = data
        self.arrivalNanos = arrivalNanos
    }
}

struct BoundedDatagramFIFO {
    private var storage: [PosixUDPDatagram] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    /// Appends datagrams in order and, if the hard memory bound is exceeded,
    /// drops the oldest entries. Returns the number dropped.
    mutating func append(contentsOf datagrams: [PosixUDPDatagram]) -> Int {
        guard !datagrams.isEmpty else { return 0 }
        storage.append(contentsOf: datagrams)
        let overflow = max(0, count - capacity)
        head += overflow
        compactIfNeeded()
        return overflow
    }

    mutating func popFirst() -> PosixUDPDatagram? {
        guard head < storage.count else { return nil }
        let value = storage[head]
        head += 1
        compactIfNeeded()
        return value
    }

    /// Removes up to `limit` datagrams without an actor/continuation round trip
    /// for every packet in a burst.
    mutating func popFirst(upTo limit: Int) -> [PosixUDPDatagram] {
        guard limit > 0, head < storage.count else { return [] }
        let end = min(storage.count, head + limit)
        let values = Array(storage[head..<end])
        head = end
        compactIfNeeded()
        return values
    }

    private mutating func compactIfNeeded() {
        guard head > 0 else { return }
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 4096 && head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
    }
}

/// A UDP channel backed directly by a POSIX socket.
///
/// This mirrors Apple Screen Sharing's native
/// `+[SSSession udpSocketWithAVCMediaStreamConfig:port:]` exactly:
///
/// ```
/// fd = socket(AF_INET, SOCK_DGRAM, 0)
/// setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
/// setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, 1)
/// bind(fd, INADDR_ANY : port)
/// connect(fd, serverIP : port)     // symmetric RTP: same port both ends
/// ```
///
/// `Network.framework` (`NWListener`/`NWConnection`) does not reliably expose
/// `SO_REUSEPORT`, which the native path requires so the viewer can bind the
/// *same* UDP port the server already holds (this is what makes loopback and
/// symmetric-port RTP work). This actor uses the raw BSD API so the behavior
/// matches the native client bit-for-bit.
public actor PosixUDPChannel {

    // MARK: - Properties

    private let requestedLocalPort: UInt16?
    private let remoteHost: String?
    private let remotePort: UInt16?
    private let enableReusePort: Bool

    private var fd: Int32 = -1
    private var boundPort: UInt16?
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "com.rootshell.vnc.udp.read", qos: .userInitiated)
    private nonisolated let log = VNCLogger(category: "PosixUDPChannel")

    // Datagram handoff state, guarded by `stateLock` (NOT actor-isolated: the
    // read source appends from `readQueue`, `receive()` consumes from the
    // actor). Ordering is load-bearing: the previous design spawned one
    // unstructured Task per drained batch to hop onto the actor, and Swift
    // gives NO FIFO guarantee between separately-created Tasks — under load,
    // batch N+1 regularly landed before batch N, reordering RTP packets inside
    // the client. Reordered video packets shred HEVC fragmentation units and
    // read as sequence gaps, i.e. macroblocks that worsen with system load.
    private let stateLock = NSLock()
    private nonisolated(unsafe) var pendingDatagrams = BoundedDatagramFIFO(
        capacity: 8192)
    private nonisolated(unsafe) var receiveWaiters: [
        CheckedContinuation<PosixUDPDatagram, Error>
    ] = []
    private nonisolated(unsafe) var lastBacklogLogNanos: UInt64 = 0
    private nonisolated(unsafe) var lockedClosed = false
    /// Soft cap so a stalled consumer degrades like a kernel buffer overflow
    /// (bounded memory, oldest dropped) instead of growing without bound.
    private var closed = false

    // MARK: - Init

    /// Create a POSIX UDP channel.
    ///
    /// - Parameters:
    ///   - localPort: Local port to bind (INADDR_ANY). `nil`/`0` lets the OS choose.
    ///   - remoteHost: If provided, `connect()` the socket to this host so it only
    ///     receives datagrams from (and `send`s to) that peer.
    ///   - remotePort: Remote port to connect to. Native uses the same value as
    ///     `localPort` (symmetric RTP).
    ///   - enableReusePort: Set `SO_REUSEADDR`/`SO_REUSEPORT` before bind. Required
    ///     to bind a port the server already holds (loopback / symmetric port).
    public init(
        localPort: UInt16?,
        remoteHost: String? = nil,
        remotePort: UInt16? = nil,
        enableReusePort: Bool = true
    ) {
        self.requestedLocalPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.enableReusePort = enableReusePort
    }

    // MARK: - Lifecycle

    public func start() async throws {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            throw VNCProtocolError.ioError("UDP socket() failed: \(errnoString())")
        }
        fd = sock

        if enableReusePort {
            setBoolOption(SO_REUSEADDR)
            setBoolOption(SO_REUSEPORT)
        }

        // Apple's HEVC media bursts hard; the default receive buffer holds only
        // tens of milliseconds, so processing bursts drop packets and shred
        // large keyframes. Request a much larger buffer (macOS may cap it).
        setIntOption(SO_RCVBUF, value: 8 * 1024 * 1024)

        // bind(INADDR_ANY : localPort)
        var localAddr = sockaddr_in()
        localAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_port = (requestedLocalPort ?? 0).bigEndian
        localAddr.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &localAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errnoString()
            closeFD()
            throw VNCProtocolError.ioError("UDP bind(:\(requestedLocalPort ?? 0)) failed: \(err)")
        }

        // connect(remoteIP : remotePort) — native always connects (symmetric).
        if let remoteHost, let remotePort {
            var remoteAddr = sockaddr_in()
            remoteAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            remoteAddr.sin_family = sa_family_t(AF_INET)
            remoteAddr.sin_port = remotePort.bigEndian
            guard let resolved = Self.resolveIPv4(remoteHost) else {
                closeFD()
                throw VNCProtocolError.ioError("UDP connect: cannot resolve remote host \(remoteHost)")
            }
            remoteAddr.sin_addr = resolved
            let connectResult = withUnsafePointer(to: &remoteAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                let err = errnoString()
                closeFD()
                throw VNCProtocolError.ioError("UDP connect(\(remoteHost):\(remotePort)) failed: \(err)")
            }
        }

        // Resolve the actually-bound local port.
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        if nameResult == 0 {
            boundPort = UInt16(bigEndian: boundAddr.sin_port)
        } else {
            boundPort = requestedLocalPort
        }

        // Non-blocking + dispatch read source.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        startReadSource()

        var actualRcvBuf: Int32 = 0
        var optLen = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actualRcvBuf, &optLen)
        log.info("POSIX UDP SO_RCVBUF=\(actualRcvBuf)")

        log.info("POSIX UDP started local=\(boundPort.map(String.init) ?? "?") "
            + "remote=\(remoteHost ?? "-"):\(remotePort.map(String.init) ?? "-") "
            + "reusePort=\(enableReusePort)")
    }

    /// Receive the next datagram (payload only; connected peer filtering applied).
    /// Datagrams are delivered in exact socket-drain order.
    public func receive() async throws -> Data {
        try await receiveDatagram().data
    }

    /// Receive bytes together with their socket-drain time. The timestamp is
    /// required by the media congestion controller; `receive()` remains as the
    /// compatibility convenience for callers that need only bytes.
    public func receiveDatagram() async throws -> PosixUDPDatagram {
        try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            if let datagram = pendingDatagrams.popFirst() {
                stateLock.unlock()
                continuation.resume(returning: datagram)
            } else if lockedClosed {
                stateLock.unlock()
                continuation.resume(throwing: VNCProtocolError.connectionClosed)
            } else {
                receiveWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    /// Receive one ordered socket burst. The first datagram uses the existing
    /// waiter path; everything already queued behind it is drained under the
    /// same lock. Large compound HEVC pictures contain hundreds of RTP packets,
    /// and crossing two Swift actor boundaries per datagram allowed the
    /// userspace FIFO to overflow under GUI load.
    public func receiveDatagramBatch(maxCount: Int = 512) async throws -> [PosixUDPDatagram] {
        let limit = max(1, maxCount)
        let first = try await receiveDatagram()
        guard limit > 1 else { return [first] }

        let remainder = stateLock.withLock {
            pendingDatagrams.popFirst(upTo: limit - 1)
        }
        return [first] + remainder
    }

    /// Send a datagram to the connected peer.
    public func send(_ data: Data) async throws {
        guard fd >= 0 else {
            throw VNCProtocolError.protocolViolation("UDP channel is not open")
        }
        let sent: Int = data.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress, raw.count, 0)
        }
        if sent < 0 {
            throw VNCProtocolError.ioError("UDP send failed: \(errnoString())")
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        log.info("Closing POSIX UDP channel")
        readSource?.cancel()
        readSource = nil
        closeFD()

        stateLock.lock()
        lockedClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        stateLock.unlock()
        for cont in waiters {
            cont.resume(throwing: VNCProtocolError.connectionClosed)
        }
    }

    /// The local port this channel is bound to (after `start`).
    public var localPort: UInt16? { boundPort }

    // MARK: - Private

    private func setBoolOption(_ option: Int32) {
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    private func setIntOption(_ option: Int32, value: Int32) {
        var v = value
        _ = setsockopt(fd, SOL_SOCKET, option, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    private func startReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        let capturedFD = fd
        source.setEventHandler { [weak self] in
            // Drain the socket as fast as possible into a batch (a Task per
            // datagram was slow enough that the kernel buffer overflowed even
            // on loopback), then publish the batch under the state lock, still
            // on this serial read queue — NEVER via a spawned Task, which has
            // no FIFO guarantee and reordered batches under load.
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var batch: [PosixUDPDatagram] = []
            while true {
                let n = recv(capturedFD, &buffer, buffer.count, 0)
                if n > 0 {
                    batch.append(PosixUDPDatagram(
                        data: Data(buffer[0..<n]),
                        arrivalNanos: DispatchTime.now().uptimeNanoseconds))
                } else {
                    break
                }
            }
            if !batch.isEmpty {
                self?.publishBatchInOrder(batch)
            }
        }
        readSource = source
        source.resume()
    }

    /// Append a drained batch and satisfy any waiting `receive()` calls, all
    /// under the state lock so socket-drain order is exactly delivery order.
    /// `nonisolated` — runs on the serial read queue, not the actor.
    private nonisolated func publishBatchInOrder(_ batch: [PosixUDPDatagram]) {
        stateLock.lock()
        let dropped = pendingDatagrams.append(contentsOf: batch)
        let queued = pendingDatagrams.count
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldLogBacklog = queued >= 512
            && (lastBacklogLogNanos == 0 || now &- lastBacklogLogNanos >= 1_000_000_000)
        if shouldLogBacklog { lastBacklogLogNanos = now }
        var resumes: [(CheckedContinuation<PosixUDPDatagram, Error>, PosixUDPDatagram)] = []
        while !receiveWaiters.isEmpty, let datagram = pendingDatagrams.popFirst() {
            resumes.append((receiveWaiters.removeFirst(), datagram))
        }
        stateLock.unlock()
        if dropped > 0 {
            log.error("UDP userspace receive queue overflow; dropped \(dropped) oldest datagrams")
        } else if shouldLogBacklog {
            log.warning("UDP userspace receive backlog=\(queued) datagrams")
        }
        for (cont, datagram) in resumes {
            cont.resume(returning: datagram)
        }
    }

    private func closeFD() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private nonisolated func errnoString() -> String {
        String(cString: strerror(errno))
    }

    /// Resolve a host (numeric IP or hostname like "localhost") to an IPv4
    /// address. `inet_pton` only accepts numeric IPs, so hostnames need DNS.
    private static func resolveIPv4(_ host: String) -> in_addr? {
        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) == 1 { return addr }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let sa = info.pointee.ai_addr else { return nil }
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }
}
