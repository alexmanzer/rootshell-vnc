import Foundation

/// Ordered handoff between the transport actor and the media decode queue.
///
/// Packets received before the decoder installs its sink stay here instead of
/// taking a second delivery path through `AsyncStream`. Installing the sink and
/// draining this buffer happen in one actor turn, so packets on either side of
/// the handoff cannot overtake one another.
struct AppleMediaPacketHandoff {
    typealias Sink = @Sendable (Data) -> Void

    struct DrainResult: Equatable {
        let packetCount: Int
        let byteCount: Int
        let overflowed: Bool
        let droppedPacketCount: Int
    }

    enum DeliveryResult: Equatable {
        case delivered
        case buffered
        case overflow
    }

    private let maximumPackets: Int
    private let maximumBytes: Int
    private var sink: Sink?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private(set) var overflowed = false
    private(set) var droppedPacketCount = 0

    init(maximumPackets: Int = 16_384, maximumBytes: Int = 64 * 1024 * 1024) {
        self.maximumPackets = maximumPackets
        self.maximumBytes = maximumBytes
    }

    var bufferedPacketCount: Int { pending.count }
    var bufferedByteCount: Int { pendingBytes }

    mutating func deliver(_ packet: Data) -> DeliveryResult {
        if let sink {
            sink(packet)
            return .delivered
        }

        guard pending.count < maximumPackets,
              pendingBytes <= maximumBytes - packet.count else {
            // Keep the oldest startup packets (parameter sets and the initial
            // IRAP) and reject the newest data. The caller requests a refresh
            // after the sink is installed if this ever occurs.
            overflowed = true
            droppedPacketCount += 1
            return .overflow
        }

        pending.append(packet)
        pendingBytes += packet.count
        return .buffered
    }

    mutating func installSink(_ newSink: Sink?) -> DrainResult {
        sink = newSink
        guard let newSink else {
            return DrainResult(
                packetCount: 0,
                byteCount: 0,
                overflowed: overflowed,
                droppedPacketCount: droppedPacketCount)
        }

        let packets = pending
        let bytes = pendingBytes
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        for packet in packets {
            newSink(packet)
        }
        return DrainResult(
            packetCount: packets.count,
            byteCount: bytes,
            overflowed: overflowed,
            droppedPacketCount: droppedPacketCount)
    }

    mutating func reset() {
        sink = nil
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        overflowed = false
        droppedPacketCount = 0
    }
}

/// Small packet-level jitter buffer for Apple's per-SSRC RTP sequence spaces.
/// It restores benign UDP reordering before HEVC FU reassembly and reports a
/// loss only after the missing packet has exceeded a bounded wait.
struct AppleMediaRTPReorderBuffer {
    struct Gap: Equatable {
        let ssrc: UInt32
        let missingPacketCount: Int
        let frameRTPTimestamp: UInt32
        let estimatedFramePacketCount: Int

        init(
            ssrc: UInt32,
            missingPacketCount: Int,
            frameRTPTimestamp: UInt32 = 0,
            estimatedFramePacketCount: Int? = nil
        ) {
            self.ssrc = ssrc
            self.missingPacketCount = missingPacketCount
            self.frameRTPTimestamp = frameRTPTimestamp
            self.estimatedFramePacketCount = estimatedFramePacketCount
                ?? missingPacketCount
        }
    }

    struct RetransmissionRequest: Equatable {
        let ssrc: UInt32
        let missingSequences: [UInt16]
    }

    struct Result {
        fileprivate var released: [(ssrc: UInt32, arrivalOrdinal: UInt64, data: Data)] = []
        var gaps: [Gap] = []
        var retransmissionRequests: [RetransmissionRequest] = []
        var duplicateOrLatePacketCount = 0

        var packets: [Data] {
            // Preserve arrival ordering between independent SSRCs, but assign
            // each stream's arrival slots to its sequence-ordered releases.
            // Sorting directly by each packet's original arrival ordinal would
            // undo the exact within-SSRC reordering this buffer exists to do.
            let streams = Dictionary(grouping: released, by: \.ssrc)
            var globallyOrdered: [(ordinal: UInt64, data: Data)] = []
            globallyOrdered.reserveCapacity(released.count)
            for packets in streams.values {
                let arrivalSlots = packets.map(\.arrivalOrdinal).sorted()
                for (index, packet) in packets.enumerated() {
                    globallyOrdered.append((arrivalSlots[index], packet.data))
                }
            }
            return globallyOrdered.sorted { $0.ordinal < $1.ordinal }.map(\.data)
        }

        mutating func merge(_ other: Result) {
            released.append(contentsOf: other.released)
            gaps.append(contentsOf: other.gaps)
            retransmissionRequests.append(contentsOf: other.retransmissionRequests)
            duplicateOrLatePacketCount += other.duplicateOrLatePacketCount
        }
    }

    private struct BufferedPacket {
        let data: Data
        let arrivalNanos: UInt64
        let ordinal: UInt64
    }

    private struct StreamState {
        var firstSequence: UInt16
        var startupDeadlineNanos: UInt64
        var started = false
        var nextSequence: UInt16?
        var gapDeadlineNanos: UInt64?
        var nextNACKDeadlineNanos: UInt64?
        var pending: [UInt16: BufferedPacket] = [:]
        /// RTP marker delimits frames even on Apple screen streams whose RTP
        /// timestamp does not advance. These fields let confirmed loss report
        /// the observed damaged-frame size instead of inventing a constant.
        var activeFrameTimestamp: UInt32?
        var activeFrameReceivedPacketCount = 0
    }

    private let startupHoldNanos: UInt64
    private let maximumGapWaitNanos: UInt64
    private let nackRetryNanos: UInt64
    private let maximumBufferedPacketsPerStream: Int
    private var streams: [UInt32: StreamState] = [:]
    private var nextOrdinal: UInt64 = 0

    init(
        startupHoldNanos: UInt64 = 8_000_000,
        // This wait is entered only after a sequence hole, so it does not add
        // latency to normal playback. One hundred milliseconds was too short:
        // a lone delayed/retransmitted fragment was declared lost and poisoned
        // the long HEVC reference chain. Keep requesting it for a bounded 300
        // ms before releasing newer packets.
        maximumGapWaitNanos: UInt64 = 300_000_000,
        nackRetryNanos: UInt64 = 25_000_000,
        // At the negotiated 65 Mbps ceiling, 300 ms can contain roughly 1,700
        // full-size RTP packets. The former 512-packet cap forced a loss before
        // the time deadline during high-bitrate motion.
        maximumBufferedPacketsPerStream: Int = 4096
    ) {
        self.startupHoldNanos = startupHoldNanos
        self.maximumGapWaitNanos = maximumGapWaitNanos
        self.nackRetryNanos = nackRetryNanos
        self.maximumBufferedPacketsPerStream = maximumBufferedPacketsPerStream
    }

    var queuedPacketCount: Int {
        streams.values.reduce(0) { $0 + $1.pending.count }
    }

    var nextDeadlineNanos: UInt64? {
        streams.values.compactMap { state in
            guard state.started else { return state.startupDeadlineNanos }
            return [state.gapDeadlineNanos, state.nextNACKDeadlineNanos]
                .compactMap { $0 }
                .min()
        }.min()
    }

    mutating func insert(
        packet: Data,
        ssrc: UInt32,
        sequence: UInt16,
        nowNanos: UInt64
    ) -> Result {
        var result = flushExpired(nowNanos: nowNanos)
        nextOrdinal &+= 1

        var state = streams[ssrc] ?? StreamState(
            firstSequence: sequence,
            startupDeadlineNanos: nowNanos &+ startupHoldNanos)

        if state.pending[sequence] != nil {
            result.duplicateOrLatePacketCount += 1
            streams[ssrc] = state
            return result
        }

        if state.started, let next = state.nextSequence {
            let forward = sequence &- next
            if forward >= 0x8000 {
                result.duplicateOrLatePacketCount += 1
                streams[ssrc] = state
                return result
            }
        }

        state.pending[sequence] = BufferedPacket(
            data: packet,
            arrivalNanos: nowNanos,
            ordinal: nextOrdinal)
        if state.pending.count >= maximumBufferedPacketsPerStream {
            if !state.started { start(&state) }
            drain(&state, ssrc: ssrc, nowNanos: nowNanos, forceGap: true, into: &result)
        } else if state.started {
            drain(&state, ssrc: ssrc, nowNanos: nowNanos, forceGap: false, into: &result)
        }
        streams[ssrc] = state
        return result
    }

    mutating func flushExpired(nowNanos: UInt64) -> Result {
        var result = Result()

        for ssrc in Array(streams.keys) {
            guard var state = streams[ssrc] else { continue }
            if !state.started, nowNanos >= state.startupDeadlineNanos {
                start(&state)
            }

            var streamResult = Result()
            let forceGap = state.gapDeadlineNanos.map { nowNanos >= $0 } ?? false
            drain(&state, ssrc: ssrc, nowNanos: nowNanos, forceGap: forceGap, into: &streamResult)

            result.merge(streamResult)
            streams[ssrc] = state
        }
        return result
    }

    mutating func reset() {
        streams.removeAll(keepingCapacity: false)
        nextOrdinal = 0
    }

    private func start(_ state: inout StreamState) {
        guard !state.started, !state.pending.isEmpty else { return }
        let reference = state.firstSequence
        let earliest = state.pending.keys.min { lhs, rhs in
            Self.signedDistance(lhs, from: reference) < Self.signedDistance(rhs, from: reference)
        }!
        state.started = true
        state.nextSequence = earliest
    }

    private func drain(
        _ state: inout StreamState,
        ssrc: UInt32,
        nowNanos: UInt64,
        forceGap: Bool,
        into result: inout Result
    ) {
        guard state.started, var next = state.nextSequence else { return }
        var shouldForceGap = forceGap

        while true {
            if let buffered = state.pending.removeValue(forKey: next) {
                result.released.append((ssrc, buffered.ordinal, buffered.data))
                noteReleasedFramePacket(buffered.data, state: &state)
                next &+= 1
                state.nextSequence = next
                state.gapDeadlineNanos = nil
                state.nextNACKDeadlineNanos = nil
                shouldForceGap = false
                continue
            }

            guard let nearest = nearestFutureSequence(to: next, in: state.pending) else {
                state.gapDeadlineNanos = nil
                state.nextNACKDeadlineNanos = nil
                break
            }

            let missing = Int(nearest &- next)
            if shouldForceGap || state.pending.count >= maximumBufferedPacketsPerStream {
                let frame = estimateDamagedFrame(
                    state: state,
                    nearestSequence: nearest,
                    missingPacketCount: missing)
                result.gaps.append(Gap(
                    ssrc: ssrc,
                    missingPacketCount: missing,
                    frameRTPTimestamp: frame.timestamp,
                    estimatedFramePacketCount: frame.packetCount))
                next = nearest
                state.nextSequence = nearest
                state.gapDeadlineNanos = nil
                state.nextNACKDeadlineNanos = nil
                shouldForceGap = false
                continue
            }

            if state.gapDeadlineNanos == nil {
                let oldestArrival = state.pending.values.map(\.arrivalNanos).min() ?? nowNanos
                state.gapDeadlineNanos = oldestArrival &+ maximumGapWaitNanos
                state.nextNACKDeadlineNanos = nowNanos
            }
            if let nackDeadline = state.nextNACKDeadlineNanos,
               nowNanos >= nackDeadline {
                // RFC 4585 Generic NACK can describe many holes, but cap one
                // request to a bounded window. A pathological jump must not
                // allocate tens of thousands of sequence numbers.
                let requestCount = min(missing, 256)
                let sequences = (0..<requestCount).map { next &+ UInt16($0) }
                result.retransmissionRequests.append(.init(
                    ssrc: ssrc,
                    missingSequences: sequences))
                state.nextNACKDeadlineNanos = nowNanos &+ nackRetryNanos
            }
            break
        }
    }

    private func nearestFutureSequence(
        to sequence: UInt16,
        in pending: [UInt16: BufferedPacket]
    ) -> UInt16? {
        pending.keys
            .filter {
                let distance = $0 &- sequence
                return distance != 0 && distance < 0x8000
            }
            .min { ($0 &- sequence) < ($1 &- sequence) }
    }

    private struct RTPFrameBoundary {
        let timestamp: UInt32
        let marker: Bool
    }

    /// Read only standard RTP fields. The full RTP parser remains in the
    /// rendering layer; loss accounting needs no HEVC or Apple-private bytes.
    private func frameBoundary(in packet: Data) -> RTPFrameBoundary? {
        guard packet.count >= 12 else { return nil }
        let base = packet.startIndex
        guard packet[base] >> 6 == 2 else { return nil }
        let timestamp = UInt32(packet[base + 4]) << 24
            | UInt32(packet[base + 5]) << 16
            | UInt32(packet[base + 6]) << 8
            | UInt32(packet[base + 7])
        return RTPFrameBoundary(
            timestamp: timestamp,
            marker: packet[base + 1] & 0x80 != 0)
    }

    private func noteReleasedFramePacket(
        _ packet: Data,
        state: inout StreamState
    ) {
        guard let boundary = frameBoundary(in: packet) else { return }
        if state.activeFrameTimestamp != boundary.timestamp {
            state.activeFrameTimestamp = boundary.timestamp
            state.activeFrameReceivedPacketCount = 0
        }
        state.activeFrameReceivedPacketCount += 1
        if boundary.marker {
            state.activeFrameTimestamp = nil
            state.activeFrameReceivedPacketCount = 0
        }
    }

    /// Estimate the damaged frame size from packets actually present on both
    /// sides of the hole. Missing RTP marker packets make an exact frame split
    /// unknowable from standard RTP alone, but the estimate remains derived
    /// from this frame's observed boundaries and is bounded on serialization.
    private func estimateDamagedFrame(
        state: StreamState,
        nearestSequence: UInt16,
        missingPacketCount: Int
    ) -> (timestamp: UInt32, packetCount: Int) {
        let nearestBoundary = state.pending[nearestSequence]
            .flatMap { frameBoundary(in: $0.data) }
        let timestamp = state.activeFrameTimestamp
            ?? nearestBoundary?.timestamp
            ?? 0
        var received = state.activeFrameTimestamp == nil
            ? 0
            : state.activeFrameReceivedPacketCount
        var sequence = nearestSequence

        while let buffered = state.pending[sequence],
              let boundary = frameBoundary(in: buffered.data) {
            if received > 0, boundary.timestamp != timestamp { break }
            received += 1
            if boundary.marker { break }
            sequence &+= 1
        }
        return (timestamp, max(missingPacketCount, received + missingPacketCount))
    }

    private static func signedDistance(_ sequence: UInt16, from reference: UInt16) -> Int {
        let distance = Int(sequence &- reference)
        return distance < 0x8000 ? distance : distance - 0x1_0000
    }

}
