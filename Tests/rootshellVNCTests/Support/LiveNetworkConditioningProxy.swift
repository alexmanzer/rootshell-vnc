import Foundation
import Darwin

/// Network conditions applied by the opt-in live Standard-mode benchmark.
///
/// TCP bytes are never discarded: a simulated packet loss becomes a
/// head-of-line recovery stall, matching the user-visible effect of TCP
/// retransmission without corrupting the RFB byte stream.
struct LiveNetworkConditions: Sendable, Equatable {
    var downstreamBytesPerSecond: Int?
    var upstreamBytesPerSecond: Int?
    var oneWayDelayMilliseconds: Int
    var jitterMilliseconds: Int
    var lossPercent: Double
    var lossRecoveryMilliseconds: Int
    var seed: UInt64

    var isImpaired: Bool {
        downstreamBytesPerSecond != nil
            || upstreamBytesPerSecond != nil
            || oneWayDelayMilliseconds > 0
            || jitterMilliseconds > 0
            || lossPercent > 0
    }
}

struct LiveScheduledPacket: Equatable {
    let readyNanos: UInt64
    let simulatedLoss: Bool
}

/// Deterministic propagation/jitter/loss scheduler separated from socket I/O
/// so the impairment model can be unit tested without a privileged shaper.
struct LiveImpairmentScheduler {
    private var random: LiveSeededRandom
    private var deliveryFenceNanos: UInt64 = 0

    init(seed: UInt64) {
        random = LiveSeededRandom(seed: seed)
    }

    mutating func schedule(
        nowNanos: UInt64,
        conditions: LiveNetworkConditions
    ) -> LiveScheduledPacket {
        let jitter: Int
        if conditions.jitterMilliseconds > 0 {
            let width = UInt64(conditions.jitterMilliseconds * 2 + 1)
            jitter = Int(random.next() % width) - conditions.jitterMilliseconds
        } else {
            jitter = 0
        }
        let propagationMilliseconds = max(
            0, conditions.oneWayDelayMilliseconds + jitter)
        var ready = nowNanos &+ UInt64(propagationMilliseconds) * 1_000_000

        let threshold = max(0, min(100, conditions.lossPercent)) / 100
        let loss = threshold > 0 && random.nextUnitDouble() < threshold
        if loss {
            ready &+= UInt64(max(0, conditions.lossRecoveryMilliseconds))
                * 1_000_000
        }

        // TCP cannot deliver bytes after a missing segment. Preserve that
        // head-of-line behavior even when later chunks draw less jitter.
        ready = max(ready, deliveryFenceNanos)
        deliveryFenceNanos = ready
        return LiveScheduledPacket(readyNanos: ready, simulatedLoss: loss)
    }
}

private struct LiveSeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64: small, reproducible, and adequate for test impairment.
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }

    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}

struct LiveNetworkProxySnapshot: Sendable {
    let upstreamBytes: UInt64
    let downstreamBytes: UInt64
    let upstreamPackets: UInt64
    let downstreamPackets: UInt64
    let upstreamSimulatedLosses: UInt64
    let downstreamSimulatedLosses: UInt64
}

/// Single-connection loopback TCP proxy for the opt-in live probe.
///
/// Each direction has a bounded delayed queue. The queue is deliberately
/// small so bandwidth pressure reaches the real server instead of becoming a
/// large stale-frame buffer in the harness itself.
final class LiveNetworkConditioningProxy: @unchecked Sendable {
    let localPort: UInt16

    private enum Direction {
        case upstream
        case downstream
    }

    private struct Counters {
        var upstreamBytes: UInt64 = 0
        var downstreamBytes: UInt64 = 0
        var upstreamPackets: UInt64 = 0
        var downstreamPackets: UInt64 = 0
        var upstreamLosses: UInt64 = 0
        var downstreamLosses: UInt64 = 0
    }

    private let remoteHost: String
    private let remotePort: UInt16
    private let lock = NSLock()
    private var conditions: LiveNetworkConditions
    private var counters = Counters()
    private var listenerFD: Int32
    private var clientFD: Int32 = -1
    private var serverFD: Int32 = -1
    private var stopped = false
    private var relayQueues: [LiveDelayedChunkQueue] = []

    init(
        remoteHost: String,
        remotePort: UInt16,
        conditions: LiveNetworkConditions
    ) throws {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.conditions = conditions

        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Self.posixError("socket") }
        listenerFD = listener

        var reuse: Int32 = 1
        _ = setsockopt(
            listener, SOL_SOCKET, SO_REUSEADDR,
            &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listener, 1) == 0 else {
            let error = Self.posixError("bind/listen")
            Darwin.close(listener)
            throw error
        }
        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            let error = Self.posixError("getsockname")
            Darwin.close(listener)
            throw error
        }
        localPort = UInt16(bigEndian: bound.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptAndRelay()
        }
    }

    deinit { stop() }

    func setDownstreamBytesPerSecond(_ value: Int) {
        lock.withLock {
            conditions.downstreamBytesPerSecond = max(1, value)
        }
    }

    func snapshot() -> LiveNetworkProxySnapshot {
        lock.withLock {
            LiveNetworkProxySnapshot(
                upstreamBytes: counters.upstreamBytes,
                downstreamBytes: counters.downstreamBytes,
                upstreamPackets: counters.upstreamPackets,
                downstreamPackets: counters.downstreamPackets,
                upstreamSimulatedLosses: counters.upstreamLosses,
                downstreamSimulatedLosses: counters.downstreamLosses)
        }
    }

    func stop() {
        let stoppedState: (Int32, Int32, Int32, [LiveDelayedChunkQueue])? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            let result = (listenerFD, clientFD, serverFD, relayQueues)
            listenerFD = -1
            clientFD = -1
            serverFD = -1
            relayQueues.removeAll()
            return result
        }
        guard let stoppedState else { return }
        stoppedState.3.forEach { $0.stop() }
        for descriptor in [stoppedState.0, stoppedState.1, stoppedState.2]
            where descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func acceptAndRelay() {
        let accepted = Darwin.accept(listenerFD, nil, nil)
        guard accepted >= 0 else { return }
        let upstream = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard upstream >= 0 else {
            Darwin.close(accepted)
            return
        }
        for descriptor in [accepted, upstream] {
            var noSignal: Int32 = 1
            _ = setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        }
        var receiveBuffer: Int32 = 8 * 1_024
        _ = setsockopt(
            upstream, SOL_SOCKET, SO_RCVBUF,
            &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer)))
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = remotePort.bigEndian
        guard inet_pton(AF_INET, remoteHost, &remote.sin_addr) == 1 else {
            Darwin.close(accepted)
            Darwin.close(upstream)
            return
        }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(accepted)
            Darwin.close(upstream)
            return
        }
        let shouldRelay = lock.withLock {
            guard !stopped else { return false }
            clientFD = accepted
            serverFD = upstream
            return true
        }
        guard shouldRelay else {
            Darwin.close(accepted)
            Darwin.close(upstream)
            return
        }

        startRelay(
            from: accepted, to: upstream, direction: .upstream,
            seedXor: 0xa5a5_a5a5_a5a5_a5a5)
        startRelay(
            from: upstream, to: accepted, direction: .downstream,
            seedXor: 0x5a5a_5a5a_5a5a_5a5a)
    }

    private func startRelay(
        from source: Int32,
        to destination: Int32,
        direction: Direction,
        seedXor: UInt64
    ) {
        let queue = LiveDelayedChunkQueue(maxBufferedBytes: 16 * 1_024)
        lock.withLock { relayQueues.append(queue) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, queue] in
            self?.writeRelay(queue: queue, to: destination, direction: direction)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, queue] in
            self?.readRelay(
                from: source, queue: queue, direction: direction,
                seedXor: seedXor)
        }
    }

    private func readRelay(
        from source: Int32,
        queue: LiveDelayedChunkQueue,
        direction: Direction,
        seedXor: UInt64
    ) {
        let initial = currentConditions()
        var scheduler = LiveImpairmentScheduler(seed: initial.seed ^ seedXor)
        // Approximate an Ethernet payload. Loss is sampled per chunk so the
        // configured percentage remains meaningful across update sizes.
        var buffer = [UInt8](repeating: 0, count: 1_200)
        while !isStopped {
            let count = Darwin.recv(source, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            let current = currentConditions()
            let scheduled = scheduler.schedule(
                nowNanos: DispatchTime.now().uptimeNanoseconds,
                conditions: current)
            let data = Data(buffer[..<count])
            guard queue.enqueue(
                LiveDelayedChunk(data: data, readyNanos: scheduled.readyNanos))
            else { break }
            recordRead(
                direction: direction, bytes: count,
                simulatedLoss: scheduled.simulatedLoss)
        }
        queue.finish()
    }

    private func writeRelay(
        queue: LiveDelayedChunkQueue,
        to destination: Int32,
        direction: Direction
    ) {
        var nextWriteNanos = DispatchTime.now().uptimeNanoseconds
        while let chunk = queue.peek() {
            let bytesPerSecond = rate(for: direction, in: currentConditions())
            let target = max(chunk.readyNanos, nextWriteNanos)
            while !isStopped {
                let now = DispatchTime.now().uptimeNanoseconds
                guard target > now else { break }
                let delayMicros = min(
                    (target - now) / 1_000,
                    UInt64(50_000))
                usleep(useconds_t(max(1, delayMicros)))
            }
            guard !isStopped else { break }

            var sent = 0
            let count = chunk.data.count
            while sent < count {
                let written = chunk.data.withUnsafeBytes { raw in
                    Darwin.send(
                        destination, raw.baseAddress!.advanced(by: sent),
                        count - sent, 0)
                }
                guard written > 0 else { stop(); return }
                sent += written
            }
            queue.removePeeked()
            if let bytesPerSecond {
                let duration = UInt64(count) * 1_000_000_000
                    / UInt64(max(1, bytesPerSecond))
                nextWriteNanos = max(
                    target, DispatchTime.now().uptimeNanoseconds) &+ duration
            } else {
                nextWriteNanos = DispatchTime.now().uptimeNanoseconds
            }
        }
        stop()
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private func currentConditions() -> LiveNetworkConditions {
        lock.withLock { conditions }
    }

    private func rate(
        for direction: Direction,
        in conditions: LiveNetworkConditions
    ) -> Int? {
        switch direction {
        case .upstream: conditions.upstreamBytesPerSecond
        case .downstream: conditions.downstreamBytesPerSecond
        }
    }

    private func recordRead(
        direction: Direction,
        bytes: Int,
        simulatedLoss: Bool
    ) {
        lock.withLock {
            switch direction {
            case .upstream:
                counters.upstreamBytes &+= UInt64(bytes)
                counters.upstreamPackets &+= 1
                if simulatedLoss { counters.upstreamLosses &+= 1 }
            case .downstream:
                counters.downstreamBytes &+= UInt64(bytes)
                counters.downstreamPackets &+= 1
                if simulatedLoss { counters.downstreamLosses &+= 1 }
            }
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey:
                "\(operation) failed: \(String(cString: strerror(errno)))"])
    }
}

private struct LiveDelayedChunk {
    let data: Data
    let readyNanos: UInt64
}

private final class LiveDelayedChunkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private let maxBufferedBytes: Int
    private var chunks: [LiveDelayedChunk] = []
    private var bufferedBytes = 0
    private var finished = false
    private var stopped = false

    init(maxBufferedBytes: Int) {
        self.maxBufferedBytes = max(1, maxBufferedBytes)
    }

    func enqueue(_ chunk: LiveDelayedChunk) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !stopped && !finished && !chunks.isEmpty
                && bufferedBytes + chunk.data.count > maxBufferedBytes {
            condition.wait()
        }
        guard !stopped && !finished else { return false }
        chunks.append(chunk)
        bufferedBytes += chunk.data.count
        condition.broadcast()
        return true
    }

    func peek() -> LiveDelayedChunk? {
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty && !finished && !stopped {
            condition.wait()
        }
        return chunks.first
    }

    func removePeeked() {
        condition.lock()
        if !chunks.isEmpty {
            bufferedBytes -= chunks.removeFirst().data.count
        }
        condition.broadcast()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}
