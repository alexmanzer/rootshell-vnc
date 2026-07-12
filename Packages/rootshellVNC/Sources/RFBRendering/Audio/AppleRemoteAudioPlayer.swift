import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import RFBProtocol

#if os(iOS)
import AVFAudio
#endif

public enum AppleRemoteAudioPlayerError: Error, Sendable, LocalizedError {
    case formatDescriptionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .formatDescriptionCreationFailed(let status):
            return "Could not create the AAC-ELD audio format (OSStatus \(status))."
        case .blockBufferCreationFailed(let status):
            return "Could not create a remote-audio data buffer (OSStatus \(status))."
        case .sampleBufferCreationFailed(let status):
            return "Could not create a remote-audio sample buffer (OSStatus \(status))."
        }
    }
}

/// Public-framework playback for the system-audio stream negotiated by Apple
/// Remote Desktop. RTP/AAC packet parsing runs on a dedicated serial queue and
/// compressed samples are rendered by AVSampleBufferAudioRenderer, which keeps
/// decode and output hardware selection inside AVFoundation on macOS and iOS.
public final class AppleRemoteAudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.rootshell.vnc.remote-audio",
        qos: .userInitiated)
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let formatDescription: CMAudioFormatDescription
    private let log = VNCLogger(category: "Audio")

    private var reorderBuffer = AppleRemoteAudioRTPReorderBuffer()
    private var activeSSRC: UInt32?
    private var baseRTPTimestamp: UInt32?
    private var lastOrderedSequence: UInt16?
    private var lastOrderedTimestamp: UInt32?
    private var enqueuedAccessUnitCount = 0
    private var prerollAccessUnitTarget = 10
    private var playbackStartHostTime: CMTime?
    private var detectedLossCount: UInt64 = 0
    private var underrunCount: UInt64 = 0
    private var isRunning = false
    private var hasActivatedAudioSession = false
    private var hasLoggedFirstPacket = false
    private var hasLoggedRendererFailure = false
    private var malformedPacketCount: UInt64 = 0
    private var automaticFlushObserver: NSObjectProtocol?

    public static func canHandleRTPPacket(_ data: Data) -> Bool {
        AppleRemoteAudioRTPDepacketizer.canHandle(data)
    }

    public init() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(AppleRemoteAudioRTPDepacketizer.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC_ELD_SBR,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(
                AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit),
            mBytesPerFrame: 0,
            mChannelsPerFrame: AppleRemoteAudioRTPDepacketizer.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw AppleRemoteAudioPlayerError.formatDescriptionCreationFailed(status)
        }
        formatDescription = description

        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(renderer)
        automaticFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.resetPlaybackState(flushRenderer: true)
                self?.log.warning("Remote audio was flushed by the output device; restarting timeline")
            }
        }
    }

    deinit {
        if let automaticFlushObserver {
            NotificationCenter.default.removeObserver(automaticFlushObserver)
        }
    }

    /// Enqueue a decrypted RTP packet. Non-audio packets are ignored so this is
    /// safe to call directly from the transport's shared media sink.
    public func enqueueRTPPacket(_ data: Data) {
        guard Self.canHandleRTPPacket(data) else { return }
        queue.async { [weak self] in
            self?.processRTPPacket(data)
        }
    }

    /// Discard compressed samples and establish a fresh RTP/playback timeline
    /// after a media renegotiation or application suspension boundary.
    public func reset() {
        queue.async { [weak self] in
            self?.resetPlaybackState(flushRenderer: true)
        }
    }

    /// Stop playback and release the iOS audio session when the VNC connection
    /// ends or the user has disabled remote audio.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            resetPlaybackState(flushRenderer: true)
            deactivateAudioSessionIfNeeded()
        }
    }

    /// Test-only synchronous snapshot of playback health.
    struct DiagnosticsSnapshot {
        let underrunCount: UInt64
        let isRunning: Bool
        let rendererFailed: Bool
    }

    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        queue.sync {
            DiagnosticsSnapshot(
                underrunCount: underrunCount,
                isRunning: isRunning,
                rendererFailed: renderer.status == .failed)
        }
    }

    private func processRTPPacket(_ data: Data) {
        do {
            let packet = try AppleRemoteAudioRTPDepacketizer.parse(data)
            if !hasLoggedFirstPacket {
                hasLoggedFirstPacket = true
                log.info(
                    "Receiving 48 kHz stereo AAC-ELD/SBR audio: "
                        + "ssrc=0x\(String(packet.ssrc, radix: 16)) "
                        + "accessUnits=\(packet.accessUnits.count)")
            }
            if activeSSRC != packet.ssrc {
                if let activeSSRC {
                    log.info(
                        "Remote audio source changed from ssrc=0x"
                            + "\(String(activeSSRC, radix: 16)) to ssrc=0x"
                            + "\(String(packet.ssrc, radix: 16)); restarting timeline")
                    resetPlaybackState(flushRenderer: true)
                }
                activeSSRC = packet.ssrc
            }
            for orderedPacket in reorderBuffer.enqueue(packet) {
                noteOrderedPacket(orderedPacket)
                try enqueueAccessUnits(from: orderedPacket)
            }
        } catch {
            malformedPacketCount &+= 1
            if malformedPacketCount == 1 || malformedPacketCount.isMultiple(of: 256) {
                let packetDetail: String
                if let rtp = try? RTPDemuxer().parsePacket(data) {
                    let prefix = rtp.payload.prefix(16).map {
                        String(format: "%02x", $0)
                    }.joined(separator: " ")
                    packetDetail = " payloadBytes=\(rtp.payload.count) prefix=[\(prefix)]"
                } else {
                    packetDetail = " packetBytes=\(data.count)"
                }
                log.warning(
                    "Dropped malformed remote-audio packet "
                        + "(count \(malformedPacketCount)): \(error.localizedDescription)"
                        + packetDetail)
            }
        }
    }

    private func enqueueAccessUnits(
        from packet: AppleRemoteAudioRTPPacket
    ) throws {
        guard !packet.accessUnits.isEmpty else { return }
        activateAudioSessionIfNeeded()

        let base = baseRTPTimestamp ?? packet.timestamp
        if baseRTPTimestamp == nil { baseRTPTimestamp = base }
        var packetOffset = packet.timestamp &- base

        for (index, accessUnit) in packet.accessUnits.enumerated() {
            guard !accessUnit.isEmpty else { continue }
            var presentationTime = CMTime(
                value: Int64(packetOffset)
                    + Int64(index) * AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit,
                timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)
            let duration = CMTime(
                value: AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit,
                timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)

            // Once started, incoming media must remain ahead of the render
            // clock. If UDP jitter exhausts that lead, the renderer has
            // already emitted silence for the gap; the queue is empty, so
            // nothing is worth flushing. Slide the RTP timeline forward so
            // this access unit plays a jitter cushion ahead of "now" and keep
            // the synchronizer running — a stop/preroll/restart cycle would
            // only stretch a one-packet glitch into a long dropout.
            if isRunning,
               let renderTime = trustedRenderTime(),
               CMTimeCompare(CMTimeAdd(presentationTime, duration), renderTime) <= 0 {
                underrunCount &+= 1
                prerollAccessUnitTarget = min(prerollAccessUnitTarget + 4, 24)
                let lateMilliseconds = Int(
                    (CMTimeSubtract(renderTime, presentationTime).seconds * 1000)
                        .rounded())
                log.warning(
                    "Remote audio underrun (count \(underrunCount), "
                        + "late \(lateMilliseconds) ms); re-anchoring with "
                        + "\(prerollAccessUnitTarget * 10) ms cushion")
                let framesPerAccessUnit =
                    AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit
                let resumeFrames = CMTimeConvertScale(
                    renderTime,
                    timescale: AppleRemoteAudioRTPDepacketizer.sampleRate,
                    method: .roundAwayFromZero).value
                    + Int64(prerollAccessUnitTarget) * framesPerAccessUnit
                let anchorFrames = max(
                    resumeFrames - Int64(index) * framesPerAccessUnit, 0)
                packetOffset = UInt32(truncatingIfNeeded: anchorFrames)
                baseRTPTimestamp = packet.timestamp &- packetOffset
                presentationTime = CMTime(
                    value: Int64(packetOffset) + Int64(index) * framesPerAccessUnit,
                    timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)
            }
            let sampleBuffer = try makeSampleBuffer(
                accessUnit: accessUnit,
                presentationTime: presentationTime)

            // The source is real-time. If the renderer is already saturated,
            // resetting on the next packet is preferable to accumulating stale
            // audio and allowing latency to grow without bound.
            guard renderer.isReadyForMoreMediaData else {
                log.warning("Remote-audio renderer fell behind; restarting the live timeline")
                resetPlaybackState(flushRenderer: true)
                return
            }
            renderer.enqueue(sampleBuffer)
            enqueuedAccessUnitCount += 1

            if renderer.status == .failed {
                if !hasLoggedRendererFailure {
                    hasLoggedRendererFailure = true
                    log.error(
                        "Remote-audio decoder failed: "
                            + "\(renderer.error?.localizedDescription ?? "unknown AVFoundation error")")
                }
                synchronizer.setRate(0, time: .invalid)
                isRunning = false
                return
            }
        }

        // Apple's negotiated ptime is 10 ms. A 100 ms initial cushion absorbs
        // ordinary Wi-Fi scheduling bursts; after a measured underrun the
        // target grows in 40 ms steps, capped at 240 ms.
        if !isRunning, enqueuedAccessUnitCount >= prerollAccessUnitTarget {
            playbackStartHostTime = CMClockGetTime(CMClockGetHostTimeClock())
            synchronizer.setRate(1, time: .zero)
            isRunning = true
            log.info(
                "Remote audio playback started with "
                    + "\(prerollAccessUnitTarget * 10) ms preroll")
        }
    }

    /// The synchronizer's render position, or nil while the reading is
    /// unusable. setRate(_:time:) applies asynchronously, so for a few
    /// milliseconds after a restart currentTime() still reports the previous
    /// timeline — seconds ahead of the fresh zero-based one. A reading from
    /// the current timeline can never exceed the wall-clock elapsed since
    /// playback started, so anything further ahead is stale. Treating those
    /// reads as underruns is what previously locked the player in a
    /// flush/preroll/flush loop after every media renegotiation.
    private func trustedRenderTime() -> CMTime? {
        guard let playbackStartHostTime else { return nil }
        let renderTime = synchronizer.currentTime()
        guard renderTime.isValid else { return nil }
        let hostElapsed = CMTimeSubtract(
            CMClockGetTime(CMClockGetHostTimeClock()), playbackStartHostTime)
        let tolerance = CMTime(
            value: CMTimeValue(AppleRemoteAudioRTPDepacketizer.sampleRate / 10),
            timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)
        guard CMTimeCompare(renderTime, CMTimeAdd(hostElapsed, tolerance)) <= 0 else {
            return nil
        }
        return renderTime
    }

    private func noteOrderedPacket(_ packet: AppleRemoteAudioRTPPacket) {
        if let previousSequence = lastOrderedSequence {
            let sequenceDelta = packet.sequenceNumber &- previousSequence
            if sequenceDelta > 1, sequenceDelta < 0x8000 {
                let missing = UInt64(sequenceDelta - 1)
                detectedLossCount &+= missing
                if detectedLossCount == missing || detectedLossCount.isMultiple(of: 64) {
                    log.warning(
                        "Remote audio RTP loss: missing=\(missing) "
                            + "total=\(detectedLossCount) "
                            + "sequence=\(packet.sequenceNumber)")
                }
            }
        }

        if let previousTimestamp = lastOrderedTimestamp {
            let timestampDelta = packet.timestamp &- previousTimestamp
            // A normal packet advances by 480 frames. A jump of more than one
            // second is a new codec timeline even if a peer reuses its SSRC.
            if timestampDelta > UInt32(AppleRemoteAudioRTPDepacketizer.sampleRate),
               timestampDelta < 0x8000_0000 {
                log.info(
                    "Remote audio timestamp discontinuity: delta=\(timestampDelta); "
                        + "restarting timeline")
                resetRendererTimeline(flushRenderer: true)
                baseRTPTimestamp = packet.timestamp
            }
        }
        lastOrderedSequence = packet.sequenceNumber
        lastOrderedTimestamp = packet.timestamp
    }

    private func makeSampleBuffer(
        accessUnit: Data,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        let byteCount = accessUnit.count
        var blockBuffer: CMBlockBuffer?
        let blockStatus: OSStatus = accessUnit.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return OSStatus(-50) } // paramErr
            var created: CMBlockBuffer?
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &created)
            guard createStatus == kCMBlockBufferNoErr, let created else {
                return createStatus
            }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: source,
                blockBuffer: created,
                offsetIntoDestination: 0,
                dataLength: byteCount)
            guard copyStatus == kCMBlockBufferNoErr else { return copyStatus }
            blockBuffer = created
            return noErr
        }
        guard blockStatus == noErr, let blockBuffer else {
            throw AppleRemoteAudioPlayerError.blockBufferCreationFailed(blockStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit,
                timescale: AppleRemoteAudioRTPDepacketizer.sampleRate),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        var sampleSize = byteCount
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else {
            throw AppleRemoteAudioPlayerError.sampleBufferCreationFailed(sampleStatus)
        }
        return sampleBuffer
    }

    private func resetPlaybackState(flushRenderer: Bool) {
        resetRendererTimeline(flushRenderer: flushRenderer)
        reorderBuffer.reset()
        activeSSRC = nil
        lastOrderedSequence = nil
        lastOrderedTimestamp = nil
        detectedLossCount = 0
        malformedPacketCount = 0
    }

    private func resetRendererTimeline(flushRenderer: Bool) {
        synchronizer.setRate(0, time: .invalid)
        if flushRenderer { renderer.flush() }
        baseRTPTimestamp = nil
        playbackStartHostTime = nil
        enqueuedAccessUnitCount = 0
        isRunning = false
        hasLoggedRendererFailure = false
    }

    private func activateAudioSessionIfNeeded() {
        guard !hasActivatedAudioSession else { return }
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            hasActivatedAudioSession = true
        } catch {
            log.error("Could not activate the audio output session: \(error.localizedDescription)")
        }
        #else
        hasActivatedAudioSession = true
        #endif
    }

    private func deactivateAudioSessionIfNeeded() {
        guard hasActivatedAudioSession else { return }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation])
        } catch {
            log.warning("Could not deactivate the audio output session: \(error.localizedDescription)")
        }
        #endif
        hasActivatedAudioSession = false
    }
}
