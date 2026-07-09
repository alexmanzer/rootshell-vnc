import Foundation
import CoreVideo
import CoreMedia
import RFBProtocol

/// Summary of one packet submitted to the accelerated video pipeline.
public struct VideoStreamFeedResult: Sendable, Equatable {
    public let byteCount: Int
    public let isActive: Bool
    public let isRTCP: Bool
    public let sequenceNumber: UInt16?
    public let payloadType: UInt8?
    public let timestamp: UInt32?
    public let nalUnitTypes: [UInt8]
    public let decodedNALUnitCount: Int
    public let errorDescription: String?

    public var reachedHEVCNALUnits: Bool {
        !nalUnitTypes.isEmpty
    }

    public init(
        byteCount: Int,
        isActive: Bool,
        isRTCP: Bool = false,
        sequenceNumber: UInt16? = nil,
        payloadType: UInt8? = nil,
        timestamp: UInt32? = nil,
        nalUnitTypes: [UInt8] = [],
        decodedNALUnitCount: Int = 0,
        errorDescription: String? = nil
    ) {
        self.byteCount = byteCount
        self.isActive = isActive
        self.isRTCP = isRTCP
        self.sequenceNumber = sequenceNumber
        self.payloadType = payloadType
        self.timestamp = timestamp
        self.nalUnitTypes = nalUnitTypes
        self.decodedNALUnitCount = decodedNALUnitCount
        self.errorDescription = errorDescription
    }
}

/// Manages the accelerated HEVC video stream for high-performance VNC mode.
///
/// Apple splits one HEVC video across several RTP SSRCs (round-robin by frame:
/// consecutive frames land on different SSRCs, and each P-frame references the
/// immediately preceding frame in a sibling SSRC). All SSRCs share identical
/// parameter sets. So reassembly is tracked **per SSRC** (fragmentation units
/// only regroup within their own SSRC), but the recovered NAL units are fed to
/// a **single** decoder — feeding them to per-SSRC decoders breaks every
/// P-frame's cross-SSRC reference. The single global decode order is carried in
/// each NAL's DON (DONL); NAL units are reordered by DON before decode so that
/// jittered (Wi-Fi) arrivals don't corrupt the reference chain.
public final class VideoStreamManager: @unchecked Sendable {

    /// Delivers a decoded frame and the source SSRC (which screen band it is).
    public typealias FrameCallback = @Sendable (CVPixelBuffer, UInt32) -> Void

    private let lock = NSLock()
    private var decoder: HEVCDecoder?
    private var demuxer: RTPDemuxer
    private var frameCallback: FrameCallback?
    private var _isActive: Bool = false
    private var streamID: UInt32 = 0
    private var frameCounter: Int64 = 0
    private var droppedPacketLogCount = 0
    private var pendingVPS: Data?
    private var pendingSPS: Data?
    private var pendingPPS: Data?
    private let log = VNCLogger(category: "VideoStream")

    // MARK: - Loss detection & recovery
    //
    // The stream never carries IRAP frames after startup: measured live, a
    // 30 s session with 4 bands decodes exactly ONE IRAP NAL total, and 40
    // keyframe requests during a loss produced zero new ones. The server heals
    // corruption by GRADUAL INTRA REFRESH — a rolling intra-coded sweep inside
    // ordinary P-frames. Two consequences:
    //   1. After a loss we must KEEP DECODING: the sweep can only rebuild the
    //      reference chain if the decoder consumes the frames carrying it.
    //      (An earlier fix dropped frames until the next IRAP — that froze the
    //      stream forever.)
    //   2. "Healed" cannot be detected by NAL type; we treat the stream as
    //      recovering for a fixed window after the last detected loss, during
    //      which the recovery loop keeps nudging the server for a refresh.
    // The old drop-until-IRAP gate is kept behind ROOTSHELL_VNC_ENABLE_IRAP_GATE=1
    // for experiments against servers that do answer with real IDRs.
    private var seenVideoSSRCs: Set<UInt32> = []
    private var awaitingIRAP: Set<UInt32> = []
    private var lastVideoSeq: [UInt32: UInt16] = [:]
    private var lastLossNanos: UInt64 = 0
    private let healWindowNanos: UInt64 = 1_500_000_000
    /// Kill-switch for A/B testing: ROOTSHELL_VNC_DISABLE_LOSS_RECOVERY=1.
    var lossRecoveryEnabled = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_DISABLE_LOSS_RECOVERY"] != "1"
    /// Experimental drop-until-IRAP gate (see above). Default OFF.
    var irapGateEnabled = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_ENABLE_IRAP_GATE"] == "1"
    /// Fired (off-lock) when a fresh loss is detected while no recovery is in
    /// flight. VNCSession wires this to the transport's keyframe request.
    public var onLossDetected: (@Sendable () -> Void)?

    /// Counters for tests/diagnostics.
    public struct LossStats: Sendable, Equatable {
        public var gapsDetected = 0
        public var framesDroppedWhileGated = 0
        public var irapsDecoded = 0
        public var gatedBandCount = 0
        public init() {}
    }
    private var lossStats = LossStats()

    /// Snapshot of the loss/gating counters.
    public var lossStatsSnapshot: LossStats {
        lock.lock()
        defer { lock.unlock() }
        var s = lossStats
        s.gatedBandCount = awaitingIRAP.count
        return s
    }

    /// True while the stream is considered to be recovering from loss: with
    /// the IRAP gate on, until every band saw a fresh IRAP; otherwise for a
    /// fixed window after the last detected loss (intra-refresh streams give
    /// no in-band "healed" signal). Drives the recovery request loop.
    public var hasGatedBands: Bool {
        lock.lock()
        defer { lock.unlock() }
        if irapGateEnabled { return !awaitingIRAP.isEmpty }
        return lastLossNanos != 0
            && DispatchTime.now().uptimeNanoseconds &- lastLossNanos < healWindowNanos
    }

    // MARK: - DON reorder (dejitter) buffer
    //
    // Apple round-robins ONE HEVC reference chain across the SSRCs and stamps
    // the global decode order in each NAL's DONL. On a fast link packets arrive
    // in decode order, but over Wi-Fi they reorder, and feeding the decoder
    // out of order corrupts every referencing frame (the "constant pulsing").
    // Buffer decoded NAL units keyed by DON and release them in strict DON
    // order, holding back a few frames to absorb reordering and skipping a DON
    // only once it is `window` frames stale (presumed lost).
    private var reorderPending: [UInt16: [RTPDemuxer.DemuxedNAL]] = [:]
    private var reorderNextDON: UInt16?
    private var reorderHighestDON: UInt16?
    private var reorderLossDetected = false
    // Settable (internal) so tests can exercise reorder on/off; default from env.
    // Default OFF: real Wi-Fi captures show ZERO cross-frame reordering, so the
    // buffer only adds holdback latency, and under an unrecovered loss (this is
    // a single-IDR long-GOP stream) it stalls for `window` frames and scans a
    // growing buffer. Enable only for links that genuinely reorder.
    var reorderEnabled = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_ENABLE_REORDER"] == "1"
    var reorderHoldback = UInt16(ProcessInfo.processInfo.environment["ROOTSHELL_VNC_REORDER_HOLDBACK"].flatMap(Int.init) ?? 2)
    var reorderWindow = UInt16(ProcessInfo.processInfo.environment["ROOTSHELL_VNC_REORDER_WINDOW"].flatMap(Int.init) ?? 48)
    private let reorderMaxBuffered = 600

    public init() {
        self.demuxer = RTPDemuxer()
    }

    // MARK: - Stream Lifecycle

    public func startStream(
        streamID: UInt32,
        width: Int,
        height: Int,
        frameCallback: @escaping FrameCallback
    ) {
        lock.lock()
        defer { lock.unlock() }

        _stopStream()
        self.streamID = streamID
        self.frameCallback = frameCallback
        self.frameCounter = 0
        self.droppedPacketLogCount = 0
        self._isActive = true
        demuxer = RTPDemuxer()

        // VideoToolbox's HARDWARE decoder, in asynchronous mode, may deliver
        // output callbacks out of submission order (the software decoder is
        // serial, which is why the simulator looked fine while Catalyst
        // flickered: adjacent frames swapped on screen, worst under motion).
        // Every frame is stamped with a strictly increasing PTS at submission,
        // so release decoded frames to the renderer in exact PTS order.
        let orderer = DecodedFrameOrderer(callback: frameCallback)
        decoder = HEVCDecoder { pixelBuffer, pts, ssrc in
            orderer.submit(pixelBuffer: pixelBuffer, pts: pts, ssrc: ssrc)
        }
    }

    @discardableResult
    public func feedUDPData(_ data: Data) -> VideoStreamFeedResult {
        feedRTPData(data)
    }

    /// Feed an RTP-shaped media packet (UDP or Apple's encrypted TCP fallback).
    @discardableResult
    public func feedRTPData(_ data: Data) -> VideoStreamFeedResult {
        lock.lock()
        guard _isActive, let decoder = decoder else {
            lock.unlock()
            return VideoStreamFeedResult(byteCount: data.count, isActive: false)
        }
        let demuxerRef = demuxer
        lock.unlock()

        guard !RTPDemuxer.isRTCPPacket(data) else {
            return VideoStreamFeedResult(byteCount: data.count, isActive: true, isRTCP: true)
        }

        do {
            let packet = try demuxerRef.parsePacket(data)
            // Only the video payload type is HEVC; audio (101) must not reach
            // the decoder.
            guard packet.payloadType == 100 else {
                return VideoStreamFeedResult(
                    byteCount: data.count, isActive: true,
                    sequenceNumber: packet.sequenceNumber, payloadType: packet.payloadType,
                    timestamp: packet.timestamp)
            }

            // Loss detection: a per-SSRC sequence gap means ≥1 video packet
            // died (whole frame, FU fragment, or parameter-set AP). Latch all
            // bands broken before feeding the demuxer, so nothing decoded from
            // this packet onward can render against a stale reference.
            let freshLoss = noteVideoPacketAndDetectGap(ssrc: packet.ssrc, sequence: packet.sequenceNumber)
            if freshLoss {
                onLossDetected?()
            }

            let demuxed = demuxerRef.feedPacket(packet)
            // Reorder into decode (DON) order before touching the decoder. On a
            // clean link this releases immediately; only reordered/lost DONs are
            // held or skipped.
            let ordered = reorderEnabled ? enqueueAndDrainReorder(demuxed) : demuxed
            guard !ordered.isEmpty else {
                return VideoStreamFeedResult(
                    byteCount: data.count, isActive: true,
                    sequenceNumber: packet.sequenceNumber, payloadType: packet.payloadType,
                    timestamp: packet.timestamp)
            }

            var nalUnitTypes: [UInt8] = []
            var decodedCount = 0
            for unit in ordered {
                let nalUnit = unit.nal
                guard nalUnit.count >= 2 else { continue }
                let nalType = (nalUnit[nalUnit.startIndex] >> 1) & 0x3F
                nalUnitTypes.append(nalType)
                switch nalType {
                case 32: handleParameterSet(nalUnit: nalUnit, type: .vps)
                case 33: handleParameterSet(nalUnit: nalUnit, type: .sps)
                case 34: handleParameterSet(nalUnit: nalUnit, type: .pps)
                case 35, 36, 37, 38, 39, 40: continue // AUD/EOS/EOB/filler/SEI
                default:
                    // One VCL NAL == one access unit (Apple uses single-slice
                    // frames). Decode it in DON order, tagged with its source
                    // SSRC so the renderer routes it to the right screen band.
                    // IRAP NAL units (16-21) heal their band; non-IRAP VCL from
                    // a gated band is dropped (its reference chain is broken —
                    // decoding it would render macroblocks, not fail).
                    guard shouldDecodeVCL(nalType: nalType, ssrc: unit.ssrc) else { continue }
                    // A VCL NAL can beat its parameter sets to the decoder in
                    // the startup burst (each band's ONLY IRAP is in there —
                    // dropping one leaves the band dead all session). Buffer
                    // until the format description exists, then drain in order.
                    guard decoder.isReady else {
                        bufferEarlyVCL(nal: nalUnit, ssrc: unit.ssrc)
                        continue
                    }
                    // RTP timestamps are all 0; synthesize a strictly increasing
                    // PTS so VideoToolbox treats each as a distinct frame.
                    let pts = CMTime(value: nextPresentationTimeValue(), timescale: 90000)
                    try decoder.decode(nalUnits: [nalUnit], presentationTime: pts, frameTag: unit.ssrc)
                    decodedCount += 1
                }
            }

            return VideoStreamFeedResult(
                byteCount: data.count, isActive: true,
                sequenceNumber: packet.sequenceNumber, payloadType: packet.payloadType,
                timestamp: packet.timestamp, nalUnitTypes: nalUnitTypes,
                decodedNALUnitCount: decodedCount)
        } catch {
            // A packet we couldn't parse/decode is as gone as one that never
            // arrived — latch the gate so the broken chain isn't rendered.
            let freshLoss = gateAllBands()
            if freshLoss { onLossDetected?() }
            logDroppedPacket(error: error, byteCount: data.count)
            return VideoStreamFeedResult(
                byteCount: data.count, isActive: true,
                errorDescription: error.localizedDescription)
        }
    }

    /// Track per-SSRC video sequence numbers; on a gap, mark the stream
    /// recovering. Returns true when this is a FRESH loss (no recovery already
    /// in flight), so callers kick off recovery once per loss burst.
    private func noteVideoPacketAndDetectGap(ssrc: UInt32, sequence: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        seenVideoSSRCs.insert(ssrc)
        let last = lastVideoSeq[ssrc]
        lastVideoSeq[ssrc] = sequence
        guard let last, sequence != last &+ 1 else { return false }
        // A duplicate/late packet (seq <= last) is not a new hole in the chain;
        // only a forward jump means data was lost.
        let forward = sequence &- last
        guard forward != 0 && forward < 0x8000 else { return false }
        lossStats.gapsDetected += 1
        guard lossRecoveryEnabled else { return false }
        return markLossLocked()
    }

    /// Mark a loss (used directly for losses whose SSRC is unknown: parse
    /// errors, DON skips). Returns true when this loss STARTED a recovery.
    @discardableResult
    private func gateAllBands() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lossStats.gapsDetected += 1
        guard lossRecoveryEnabled else { return false }
        return markLossLocked()
    }

    /// Record a loss under `lock`; returns true when no recovery was in flight.
    private func markLossLocked() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let fresh: Bool
        if irapGateEnabled {
            fresh = awaitingIRAP.isEmpty
            awaitingIRAP.formUnion(seenVideoSSRCs)
        } else {
            fresh = lastLossNanos == 0 || now &- lastLossNanos > healWindowNanos
        }
        lastLossNanos = now
        return fresh
    }

    /// Whether a VCL NAL should reach the decoder, updating recovery state.
    /// Default (intra-refresh) mode decodes EVERYTHING — the rolling intra
    /// sweep can only heal if the decoder consumes it. With the experimental
    /// IRAP gate on, non-IRAP VCL from a gated band is dropped until that
    /// band's next IRAP (BLA 16-18, IDR 19-20, CRA 21).
    private func shouldDecodeVCL(nalType: UInt8, ssrc: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if (16...21).contains(nalType) {
            lossStats.irapsDecoded += 1
            awaitingIRAP.remove(ssrc)
            return true
        }
        guard irapGateEnabled, awaitingIRAP.contains(ssrc) else { return true }
        lossStats.framesDroppedWhileGated += 1
        return false
    }

    public func stopStream() {
        lock.lock()
        defer { lock.unlock() }
        _stopStream()
    }

    public var isStreamActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    // MARK: - Private

    private func nextPresentationTimeValue() -> CMTimeValue {
        lock.lock()
        defer { lock.unlock() }
        let value = frameCounter * 3000
        frameCounter += 1
        return CMTimeValue(value)
    }

    private func _stopStream() {
        decoder?.flush()
        decoder?.reset()
        decoder = nil
        demuxer.reset()
        frameCallback = nil
        _isActive = false
        frameCounter = 0
        droppedPacketLogCount = 0
        pendingVPS = nil
        pendingSPS = nil
        pendingPPS = nil
        seenVideoSSRCs.removeAll()
        awaitingIRAP.removeAll()
        lastVideoSeq.removeAll()
        lastLossNanos = 0
        earlyVCLBuffer.removeAll()
        lossStats = LossStats()
        resetReorderBuffer()
    }

    private func logDroppedPacket(error: Error, byteCount: Int) {
        lock.lock()
        let shouldLog = droppedPacketLogCount < 8
        droppedPacketLogCount += 1
        lock.unlock()
        if shouldLog {
            log.warning("Dropped media packet (\(byteCount) bytes): \(error.localizedDescription)")
        }
    }

    private enum ParameterSetType { case vps, sps, pps }

    /// VCL NAL units that arrived before the decoder had its parameter sets
    /// (startup burst ordering). Drained the moment the format description is
    /// configured; bounded so a broken stream can't grow it unboundedly.
    private var earlyVCLBuffer: [(nal: Data, ssrc: UInt32)] = []

    private func bufferEarlyVCL(nal: Data, ssrc: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if earlyVCLBuffer.count < 256 {
            earlyVCLBuffer.append((nal, ssrc))
        }
    }

    private func handleParameterSet(nalUnit: Data, type: ParameterSetType) {
        lock.lock()
        switch type {
        case .vps: pendingVPS = nalUnit
        case .sps: pendingSPS = nalUnit
        case .pps: pendingPPS = nalUnit
        }
        guard let sps = pendingSPS, let pps = pendingPPS else {
            lock.unlock()
            return
        }
        let decoderRef = decoder
        let vps = pendingVPS
        lock.unlock()

        try? decoderRef?.updateFormatDescription(sps: sps, pps: pps, vps: vps)
        drainEarlyVCLIfReady()
    }

    /// Decode, in arrival order, any VCL NAL units that beat their parameter
    /// sets to the pipeline (they include the bands' only IRAPs).
    private func drainEarlyVCLIfReady() {
        lock.lock()
        guard let decoderRef = decoder, decoderRef.isReady, !earlyVCLBuffer.isEmpty else {
            lock.unlock()
            return
        }
        let buffered = earlyVCLBuffer
        earlyVCLBuffer.removeAll()
        lock.unlock()

        for item in buffered {
            let pts = CMTime(value: nextPresentationTimeValue(), timescale: 90000)
            try? decoderRef.decode(nalUnits: [item.nal], presentationTime: pts, frameTag: item.ssrc)
        }
    }

    // MARK: - DON reorder buffer

    /// Insert freshly demuxed NAL units into the DON reorder buffer and return
    /// every unit that is now ready to decode, in strict decoding order.
    private func enqueueAndDrainReorder(_ nals: [RTPDemuxer.DemuxedNAL]) -> [RTPDemuxer.DemuxedNAL] {
        lock.lock()
        defer { lock.unlock() }

        for n in nals {
            // Drop units whose DON is behind what we've already released.
            if let next = reorderNextDON {
                let behind = Int(next &- n.don)
                if behind != 0 && behind < 0x8000 { continue }
            }
            reorderPending[n.don, default: []].append(n)
            if let hi = reorderHighestDON {
                let ahead = Int(n.don &- hi)
                if ahead != 0 && ahead < 0x8000 { reorderHighestDON = n.don }
            } else {
                reorderHighestDON = n.don
            }
        }

        guard let hi = reorderHighestDON else { return [] }
        if reorderNextDON == nil {
            reorderNextDON = smallestPendingDON(reference: hi &- reorderWindow)
        }

        var out: [RTPDemuxer.DemuxedNAL] = []
        while let next = reorderNextDON {
            let ahead = Int(hi &- next)
            if ahead >= 0x8000 { break } // nothing newer than `next` yet
            if let group = reorderPending[next] {
                // Hold back a couple of frames so a DON that shares fragments
                // across packets (e.g. an AP of parameter sets plus the IDR FU
                // that carry the same DON) is fully collected before release.
                guard ahead >= Int(reorderHoldback) else { break }
                out.append(contentsOf: group)
                reorderPending.removeValue(forKey: next)
                reorderNextDON = next &+ 1
            } else {
                // Gap at `next`. Skip it once it is `window` frames stale (or the
                // buffer is overfull) — the frame is presumed lost.
                if ahead >= Int(reorderWindow) || reorderPending.count > reorderMaxBuffered {
                    reorderLossDetected = true
                    // A skipped DON is a lost frame: mark the stream recovering
                    // (inline — this method already holds `lock`).
                    if lossRecoveryEnabled { _ = markLossLocked() }
                    if let skip = smallestPendingDON(reference: next &+ 1), skip != next {
                        reorderNextDON = skip
                    } else {
                        reorderNextDON = next &+ 1
                    }
                } else {
                    break
                }
            }
        }
        return out
    }

    /// Releases decoded frames in strict presentation (submission) order.
    ///
    /// PTS values are synthesized at decode submission as consecutive multiples
    /// of 3000 (90 kHz ticks), so the expected sequence is exactly 0, 1, 2, …
    /// in frame indices. Out-of-order hardware-decoder callbacks are held until
    /// their turn; a frame the decoder swallowed (decode error, corrupt slice)
    /// is skipped once a few newer frames have queued behind it, so one loss
    /// can never stall the display.
    final class DecodedFrameOrderer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int64: (CVPixelBuffer, UInt32)] = [:]
        private var nextIndex: Int64 = 0
        private let callback: FrameCallback
        private let maxHeld = 6

        init(callback: @escaping FrameCallback) {
            self.callback = callback
        }

        func submit(pixelBuffer: CVPixelBuffer, pts: CMTime, ssrc: UInt32) {
            let index = Int64(pts.value) / 3000
            var ready: [(CVPixelBuffer, UInt32)] = []

            lock.lock()
            if index < nextIndex {
                // Stale duplicate (shouldn't happen) — drop.
                lock.unlock()
                return
            }
            pending[index] = (pixelBuffer, ssrc)
            while true {
                if let frame = pending.removeValue(forKey: nextIndex) {
                    ready.append(frame)
                    nextIndex += 1
                } else if pending.count > maxHeld, let smallest = pending.keys.min() {
                    // The frame at nextIndex never came out of the decoder;
                    // skip forward rather than stalling the stream.
                    nextIndex = smallest
                } else {
                    break
                }
            }
            lock.unlock()

            for (buffer, source) in ready {
                callback(buffer, source)
            }
        }
    }

    /// The buffered DON with the smallest forward distance from `reference`
    /// (i.e. the next one to release), honoring 16-bit wraparound.
    private func smallestPendingDON(reference: UInt16) -> UInt16? {
        var best: UInt16?
        var bestDistance = Int.max
        for key in reorderPending.keys {
            let distance = Int(key &- reference)
            if distance < bestDistance {
                bestDistance = distance
                best = key
            }
        }
        return best
    }

    private func resetReorderBuffer() {
        reorderPending.removeAll()
        reorderNextDON = nil
        reorderHighestDON = nil
        reorderLossDetected = false
    }
}
