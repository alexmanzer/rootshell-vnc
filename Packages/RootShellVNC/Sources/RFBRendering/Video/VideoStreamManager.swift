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

/// Generates synthetic monotonic PTS values. Conventional video has one
/// timeline; Apple's screen tiles have independent reference timelines, so a
/// quiet tile must not consume or block another tile's presentation sequence.
struct HEVCPresentationTimeline {
    private var sequentialCounter: Int64 = 0
    private var tileCounters: [UInt32: Int64] = [:]

    mutating func next(source: UInt32, independentTiles: Bool) -> CMTimeValue {
        if independentTiles {
            let counter = tileCounters[source, default: 0]
            tileCounters[source] = counter + 1
            return CMTimeValue(counter * 3000)
        }
        defer { sequentialCounter += 1 }
        return CMTimeValue(sequentialCounter * 3000)
    }

    mutating func reset() {
        sequentialCounter = 0
        tileCounters.removeAll(keepingCapacity: false)
    }
}

/// Manages the accelerated HEVC video stream for high-performance VNC mode.
///
/// Supports both Apple HEVC RTP modes. The native multi-tile mode round-robins
/// a DON timeline across several SSRCs; each SSRC is an independently
/// referenced horizontal tile and therefore owns a public VideoToolbox
/// session. The one-tile mode is a normal sequential RTP stream without DONL
/// metadata and uses one session. This mirrors the state isolation performed
/// by Apple's private `NumberOfTiles`/`TileID` decoder path without calling it.
public final class VideoStreamManager: @unchecked Sendable {

    /// Delivers a decoded frame and the source SSRC (which screen band it is).
    public typealias FrameCallback = @Sendable (CVPixelBuffer, UInt32) -> Void

    private let lock = NSLock()
    private var decoder: HEVCDecoder?
    private var tileDecoders: [UInt32: HEVCDecoder] = [:]
    private var demuxer: RTPDemuxer
    private var frameCallback: FrameCallback?
    private var _isActive: Bool = false
    private var usesDecodingOrderNumbers = true
    private var streamID: UInt32 = 0
    private var streamGeneration: UInt64 = 0
    private var fullFrameHeight = 0
    private var presentationTimeline = HEVCPresentationTimeline()
    private var submittedFrameCount: UInt64 = 0
    private var decoderOutputCount: UInt64 = 0
    private var lastSubmissionNanos: UInt64 = 0
    private var lastDecoderOutputNanos: UInt64 = 0
    private var droppedPacketLogCount = 0
    private var multiNALAccessUnitLogCount = 0
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
    public var onLossDetected: (@Sendable (UInt32?) -> Void)?

    /// Counters for tests/diagnostics.
    public struct LossStats: Sendable, Equatable {
        public var gapsDetected = 0
        public var framesDroppedWhileGated = 0
        public var irapsDecoded = 0
        public var gatedBandCount = 0
        public init() {}
    }
    private var lossStats = LossStats()

    // MARK: - Compound-frame decode ordering

    /// Parameter sets bypass this scheduler and configure the decoder
    /// immediately; only completed VCL pictures participate in global DON order.
    private var donReorderBuffer = CompoundHEVCDONReorderBuffer()
    private var sequentialAccessUnitAssembler = SequentialHEVCAccessUnitAssembler()

    /// Monotonic decode-pipeline progress for liveness monitoring. A screen can
    /// legitimately be static, so callers distinguish an idle stream from a
    /// wedged decoder by checking whether submissions continue without output.
    public struct DecodeProgress: Sendable, Equatable {
        public let streamGeneration: UInt64
        public let submittedFrameCount: UInt64
        public let decoderOutputCount: UInt64
        public let lastSubmissionNanos: UInt64
        public let lastDecoderOutputNanos: UInt64
    }

    public var decodeProgress: DecodeProgress {
        lock.lock()
        defer { lock.unlock() }
        return DecodeProgress(
            streamGeneration: streamGeneration,
            submittedFrameCount: submittedFrameCount,
            decoderOutputCount: decoderOutputCount,
            lastSubmissionNanos: lastSubmissionNanos,
            lastDecoderOutputNanos: lastDecoderOutputNanos)
    }

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

    public init() {
        self.demuxer = RTPDemuxer()
    }

    // MARK: - Stream Lifecycle

    public func startStream(
        streamID: UInt32,
        width: Int,
        height: Int,
        usesDecodingOrderNumbers: Bool = true,
        frameCallback: @escaping FrameCallback
    ) {
        lock.lock()
        let retiredDecoders = _stopStreamLocked()
        self.streamID = streamID
        self.fullFrameHeight = height
        self.usesDecodingOrderNumbers = usesDecodingOrderNumbers
        self.frameCallback = frameCallback
        self.presentationTimeline.reset()
        self.submittedFrameCount = 0
        self.decoderOutputCount = 0
        self.lastSubmissionNanos = 0
        self.lastDecoderOutputNanos = 0
        self.droppedPacketLogCount = 0
        self.multiNALAccessUnitLogCount = 0
        self._isActive = true
        demuxer = RTPDemuxer(
            usesDecodingOrderNumbers: usesDecodingOrderNumbers)

        // Hardware callbacks can arrive out of submission order. The one-tile
        // stream has one orderer. Multi-tile streams create one orderer and one
        // decoder per SSRC lazily, because their reference/PTS timelines are
        // independent (Apple's private decoder performs the same isolation).
        if !usesDecodingOrderNumbers {
            decoder = makeDecoder(
                source: nil,
                generation: streamGeneration,
                frameCallback: frameCallback)
        }
        lock.unlock()
        retireDecoders(retiredDecoders)
    }

    @discardableResult
    public func feedUDPData(_ data: Data) -> VideoStreamFeedResult {
        feedRTPData(data)
    }

    /// Feed an RTP-shaped media packet (UDP or Apple's encrypted TCP fallback).
    @discardableResult
    public func feedRTPData(_ data: Data) -> VideoStreamFeedResult {
        lock.lock()
        guard _isActive else {
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
            let gap = noteVideoPacketAndDetectGap(
                ssrc: packet.ssrc,
                sequence: packet.sequenceNumber)
            if gap.detected, !usesDecodingOrderNumbers {
                discardPartialSequentialAccessUnit()
            }
            if gap.shouldRequestRecovery {
                onLossDetected?(packet.ssrc)
            }

            let demuxed = demuxerRef.feedPacket(packet)
            guard !demuxed.isEmpty else {
                return VideoStreamFeedResult(
                    byteCount: data.count, isActive: true,
                    sequenceNumber: packet.sequenceNumber, payloadType: packet.payloadType,
                    timestamp: packet.timestamp)
            }

            // Parameter sets are not pictures and may share a DON with a later
            // IRAP, so apply them immediately. Buffer only VCL units by DON.
            var orderedVCL: [CompoundHEVCDONReorderBuffer.AccessUnit] = []
            for unit in demuxed {
                guard unit.nal.count >= 2 else { continue }
                let type = (unit.nal[unit.nal.startIndex] >> 1) & 0x3f
                switch type {
                case 32: handleParameterSet(nalUnit: unit.nal, type: .vps)
                case 33: handleParameterSet(nalUnit: unit.nal, type: .sps)
                case 34: handleParameterSet(nalUnit: unit.nal, type: .pps)
                case 0...31:
                    if usesDecodingOrderNumbers {
                        orderedVCL.append(contentsOf:
                            enqueueAndDrainReorder([unit]).orderedAccessUnits)
                    } else {
                        appendSequentialVCL(unit)
                    }
                default: break
                }
                if !usesDecodingOrderNumbers, unit.endOfAccessUnit,
                   let complete = finishSequentialAccessUnit(ssrc: unit.ssrc) {
                    orderedVCL.append(complete)
                }
            }

            let nalUnitTypes: [UInt8] = demuxed.compactMap { unit in
                guard unit.nal.count >= 2 else { return nil }
                return (unit.nal[unit.nal.startIndex] >> 1) & 0x3f
            }
            var decodedCount = 0
            for accessUnit in orderedVCL {
                let nalUnits = accessUnit.nals.map(\.nal)
                guard let firstNAL = nalUnits.first, firstNAL.count >= 2 else { continue }
                let nalType = (firstNAL[firstNAL.startIndex] >> 1) & 0x3F
                switch nalType {
                case 32...40: continue
                default:
                    // One DON is one band access unit. Preserve all of its VCL
                    // NALs/slices in a single VideoToolbox sample; submitting
                    // slices separately renders partial pictures.
                    // IRAP NAL units (16-21) heal their band; non-IRAP VCL from
                    // a gated band is dropped (its reference chain is broken —
                    // decoding it would render macroblocks, not fail).
                    guard shouldDecodeVCL(nalType: nalType, ssrc: accessUnit.ssrc) else { continue }
                    logMultiNALAccessUnitIfNeeded(
                        don: accessUnit.don,
                        count: nalUnits.count)
                    // A VCL NAL can beat its parameter sets to the decoder in
                    // the startup burst (each band's ONLY IRAP is in there —
                    // dropping one leaves the band dead all session). Buffer
                    // until the format description exists, then drain in order.
                    guard let decoderRef = decoderForSource(accessUnit.ssrc) else {
                        continue
                    }
                    guard decoderRef.isReady else {
                        bufferEarlyVCL(nals: nalUnits, ssrc: accessUnit.ssrc)
                        continue
                    }
                    let pts = CMTime(
                        value: nextPresentationTimeValue(for: accessUnit.ssrc),
                        timescale: 90000)
                    try decoderRef.decode(
                        nalUnits: nalUnits,
                        presentationTime: pts,
                        frameTag: accessUnit.ssrc)
                    recordDecodeSubmission()
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
            if freshLoss { onLossDetected?(nil) }
            logDroppedPacket(error: error, byteCount: data.count)
            return VideoStreamFeedResult(
                byteCount: data.count, isActive: true,
                errorDescription: error.localizedDescription)
        }
    }

    /// Track per-SSRC video sequence numbers; on a gap, mark the stream
    /// recovering. Returns true when this is a FRESH loss (no recovery already
    /// in flight), so callers kick off recovery once per loss burst.
    private func noteVideoPacketAndDetectGap(
        ssrc: UInt32,
        sequence: UInt16
    ) -> (detected: Bool, shouldRequestRecovery: Bool) {
        lock.lock()
        defer { lock.unlock() }
        seenVideoSSRCs.insert(ssrc)
        let last = lastVideoSeq[ssrc]
        lastVideoSeq[ssrc] = sequence
        guard let last, sequence != last &+ 1 else { return (false, false) }
        // A duplicate/late packet (seq <= last) is not a new hole in the chain;
        // only a forward jump means data was lost.
        let forward = sequence &- last
        guard forward != 0 && forward < 0x8000 else { return (false, false) }
        lossStats.gapsDetected += 1
        guard lossRecoveryEnabled else { return (true, false) }
        return (true, markLossLocked(affectedSSRC: ssrc))
    }

    /// Mark a loss (used directly for losses whose SSRC is unknown: parse
    /// errors, DON skips). Returns true when this loss STARTED a recovery.
    @discardableResult
    private func gateAllBands() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lossStats.gapsDetected += 1
        guard lossRecoveryEnabled else { return false }
        return markLossLocked(affectedSSRC: nil)
    }

    /// Record a loss under `lock`; returns true when no recovery was in flight.
    private func markLossLocked(affectedSSRC: UInt32?) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let fresh: Bool
        if irapGateEnabled {
            fresh = awaitingIRAP.isEmpty
            if let affectedSSRC {
                awaitingIRAP.insert(affectedSSRC)
            } else {
                awaitingIRAP.formUnion(seenVideoSSRCs)
            }
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
        let retiredDecoders = _stopStreamLocked()
        lock.unlock()
        retireDecoders(retiredDecoders)
    }

    public var isStreamActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    // MARK: - Private

    private func nextPresentationTimeValue(for ssrc: UInt32) -> CMTimeValue {
        lock.lock()
        defer { lock.unlock() }
        return presentationTimeline.next(
            source: ssrc,
            independentTiles: usesDecodingOrderNumbers)
    }

    /// Detach decoder callbacks while holding `lock`, but never wait for
    /// VideoToolbox under that lock: an in-flight output callback records its
    /// progress through the same lock and would otherwise deadlock shutdown.
    private func _stopStreamLocked() -> [HEVCDecoder] {
        streamGeneration &+= 1
        var retiredDecoders = [decoder].compactMap { $0 }
        decoder = nil
        retiredDecoders.append(contentsOf: tileDecoders.values)
        tileDecoders.removeAll()
        demuxer.reset()
        frameCallback = nil
        _isActive = false
        presentationTimeline.reset()
        submittedFrameCount = 0
        decoderOutputCount = 0
        lastSubmissionNanos = 0
        lastDecoderOutputNanos = 0
        droppedPacketLogCount = 0
        multiNALAccessUnitLogCount = 0
        pendingVPS = nil
        pendingSPS = nil
        pendingPPS = nil
        fullFrameHeight = 0
        seenVideoSSRCs.removeAll()
        awaitingIRAP.removeAll()
        lastVideoSeq.removeAll()
        lastLossNanos = 0
        earlyVCLBuffer.removeAll()
        lossStats = LossStats()
        donReorderBuffer.reset()
        sequentialAccessUnitAssembler.reset()
        return retiredDecoders
    }

    private func retireDecoders(_ decoders: [HEVCDecoder]) {
        for decoder in decoders {
            decoder.reset()
        }
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
    private var earlyVCLBuffer: [(nals: [Data], ssrc: UInt32)] = []

    private func bufferEarlyVCL(nals: [Data], ssrc: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if earlyVCLBuffer.count < 256 {
            earlyVCLBuffer.append((nals, ssrc))
        }
    }

    private func recordDecodeSubmission() {
        lock.lock()
        submittedFrameCount &+= 1
        lastSubmissionNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    @discardableResult
    private func recordDecoderOutput(generation: UInt64) -> Bool {
        lock.lock()
        guard generation == streamGeneration, _isActive else {
            lock.unlock()
            return false
        }
        decoderOutputCount &+= 1
        lastDecoderOutputNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        return true
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
        let decoderRefs = [decoder].compactMap { $0 } + Array(tileDecoders.values)
        let vps = pendingVPS
        lock.unlock()

        var codedHeight: Int32?
        for decoderRef in decoderRefs {
            do {
                try decoderRef.updateFormatDescription(sps: sps, pps: pps, vps: vps)
                codedHeight = codedHeight ?? decoderRef.formatDimensions?.height
            } catch {
                log.warning("Failed to configure HEVC format: \(error.localizedDescription)")
            }
        }
        if codedHeight == nil {
            do {
                codedHeight = try HEVCDecoder.codedDimensions(
                    sps: sps,
                    pps: pps,
                    vps: vps).height
            } catch {
                log.warning("Failed to inspect HEVC format: \(error.localizedDescription)")
            }
        }
        if let codedHeight, codedHeight > 0 {
            lock.lock()
            let expectedBands = max(
                1,
                (fullFrameHeight + Int(codedHeight) - 1) / Int(codedHeight))
            donReorderBuffer.setExpectedSourceCount(expectedBands)
            lock.unlock()
        }
        drainEarlyVCLIfReady()
    }

    /// Decode, in arrival order, any VCL NAL units that beat their parameter
    /// sets to the pipeline (they include the bands' only IRAPs).
    private func drainEarlyVCLIfReady() {
        lock.lock()
        guard !earlyVCLBuffer.isEmpty else {
            lock.unlock()
            return
        }
        let buffered = earlyVCLBuffer
        earlyVCLBuffer.removeAll()
        lock.unlock()

        for item in buffered {
            guard let decoderRef = decoderForSource(item.ssrc), decoderRef.isReady else {
                bufferEarlyVCL(nals: item.nals, ssrc: item.ssrc)
                continue
            }
            let pts = CMTime(
                value: nextPresentationTimeValue(for: item.ssrc),
                timescale: 90000)
            do {
                try decoderRef.decode(
                    nalUnits: item.nals,
                    presentationTime: pts,
                    frameTag: item.ssrc)
                recordDecodeSubmission()
            } catch {
                log.warning("Failed to decode buffered startup frame: \(error.localizedDescription)")
            }
        }
    }

    /// Return the conventional one-tile decoder or lazily create the public
    /// decoder that owns one multi-tile SSRC's reference-picture state.
    private func decoderForSource(_ ssrc: UInt32) -> HEVCDecoder? {
        lock.lock()
        if !usesDecodingOrderNumbers {
            let decoderRef = decoder
            lock.unlock()
            return decoderRef
        }
        if let decoderRef = tileDecoders[ssrc] {
            lock.unlock()
            return decoderRef
        }
        guard let callback = frameCallback else {
            lock.unlock()
            return nil
        }

        let decoderRef = makeDecoder(
            source: ssrc,
            generation: streamGeneration,
            frameCallback: callback)
        tileDecoders[ssrc] = decoderRef
        let tileDecoderCount = tileDecoders.count
        let sps = pendingSPS
        let pps = pendingPPS
        let vps = pendingVPS
        lock.unlock()

        log.info(
            "Creating independent HEVC tile decoder "
                + "SSRC=\(ssrc) tileCount=\(tileDecoderCount)")

        if let sps, let pps {
            do {
                try decoderRef.updateFormatDescription(sps: sps, pps: pps, vps: vps)
            } catch {
                log.warning("Failed to configure HEVC tile \(ssrc): \(error.localizedDescription)")
            }
        }
        return decoderRef
    }

    private func makeDecoder(
        source: UInt32?,
        generation: UInt64,
        frameCallback: @escaping FrameCallback
    ) -> HEVCDecoder {
        let orderer = DecodedFrameOrderer(callback: frameCallback)
        return HEVCDecoder { [weak self] pixelBuffer, pts, frameTag in
            guard self?.recordDecoderOutput(generation: generation) == true else {
                return
            }
            orderer.submit(
                pixelBuffer: pixelBuffer,
                pts: pts,
                ssrc: source ?? frameTag)
        }
    }

    private func logMultiNALAccessUnitIfNeeded(don: UInt16, count: Int) {
        guard count > 1 else { return }
        lock.lock()
        let shouldLog = multiNALAccessUnitLogCount < 8
        multiNALAccessUnitLogCount += 1
        lock.unlock()
        if shouldLog {
            log.info("Submitting complete multi-NAL HEVC access unit DON=\(don) nals=\(count)")
        }
    }

    private func appendSequentialVCL(_ unit: RTPDemuxer.DemuxedNAL) {
        lock.lock()
        sequentialAccessUnitAssembler.appendVCL(unit)
        lock.unlock()
    }

    private func finishSequentialAccessUnit(
        ssrc: UInt32
    ) -> CompoundHEVCDONReorderBuffer.AccessUnit? {
        lock.lock()
        defer { lock.unlock() }
        return sequentialAccessUnitAssembler.finish(ssrc: ssrc)
    }

    private func discardPartialSequentialAccessUnit() {
        lock.lock()
        sequentialAccessUnitAssembler.discardPartialAccessUnit()
        lock.unlock()
    }

    /// Restore completed VCL units to the single cross-SSRC HEVC timeline.
    /// Startup waits for the first compound pass so a late first band cannot be
    /// discarded. Once started, one future picture is enough to release the
    /// current DON; a bounded gap is skipped rather than freezing forever.
    private func enqueueAndDrainReorder(
        _ nals: [RTPDemuxer.DemuxedNAL]
    ) -> CompoundHEVCDONReorderBuffer.Result {
        lock.lock()
        defer { lock.unlock() }
        let result = donReorderBuffer.enqueue(nals)
        if let startupOrder = result.startupOrder {
            let values = startupOrder.map(String.init).joined(separator: ",")
            log.info("Starting compound HEVC decode at DONs [\(values)] across \(seenVideoSSRCs.count) SSRCs")
        }
        for gap in result.skippedGaps {
            log.warning("Skipping missing compound HEVC DON \(gap.missingDON); "
                + "next=\(gap.nextDON) buffered=\(gap.bufferedFrameCount)")
            if lossRecoveryEnabled { _ = markLossLocked(affectedSSRC: nil) }
        }
        return result
    }

    /// Releases decoded frames in strict presentation (submission) order.
    ///
    /// PTS values are synthesized at decode submission as consecutive multiples
    /// of 3000 (90 kHz ticks), so the expected sequence is exactly 0, 1, 2, …
    /// in frame indices. Out-of-order hardware-decoder callbacks are held until
    /// their turn; a frame the decoder swallowed is skipped once a few newer
    /// frames have queued behind it, so one loss cannot stall the display.
    final class DecodedFrameOrderer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int64: (CVPixelBuffer, UInt32)] = [:]
        private var nextIndex: Int64 = 0
        private let callback: FrameCallback
        private let maxHeld = 6
        private let maxHoldNanos: UInt64 = 100_000_000
        private var gapTimerGeneration: UInt64 = 0
        private var gapTimerScheduled = false

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
            drainLocked(allowGapSkip: pending.count > maxHeld, into: &ready)
            scheduleGapTimerLockedIfNeeded()
            lock.unlock()

            for (buffer, source) in ready {
                callback(buffer, source)
            }
        }

        /// A screen stream can be change-gated: if VideoToolbox swallows one
        /// damaged picture and only one newer picture arrives, a count-only
        /// reorder window would hold that newer picture forever. Bound the hold
        /// by time as well as depth so sparse desktop updates cannot freeze.
        private func scheduleGapTimerLockedIfNeeded() {
            guard !pending.isEmpty, pending[nextIndex] == nil else {
                if gapTimerScheduled {
                    gapTimerGeneration &+= 1
                    gapTimerScheduled = false
                }
                return
            }
            guard !gapTimerScheduled else { return }
            gapTimerScheduled = true
            gapTimerGeneration &+= 1
            let generation = gapTimerGeneration
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + .nanoseconds(Int(maxHoldNanos))) { [weak self] in
                    self?.expireGap(generation: generation)
                }
        }

        private func expireGap(generation: UInt64) {
            var ready: [(CVPixelBuffer, UInt32)] = []
            lock.lock()
            guard gapTimerScheduled, gapTimerGeneration == generation else {
                lock.unlock()
                return
            }
            gapTimerScheduled = false
            drainLocked(allowGapSkip: true, into: &ready)
            scheduleGapTimerLockedIfNeeded()
            lock.unlock()

            for (buffer, source) in ready {
                callback(buffer, source)
            }
        }

        private func drainLocked(
            allowGapSkip: Bool,
            into ready: inout [(CVPixelBuffer, UInt32)]
        ) {
            while true {
                if let frame = pending.removeValue(forKey: nextIndex) {
                    ready.append(frame)
                    nextIndex += 1
                } else if allowGapSkip, let smallest = pending.keys.min() {
                    nextIndex = smallest
                } else {
                    break
                }
            }
        }
    }

}
