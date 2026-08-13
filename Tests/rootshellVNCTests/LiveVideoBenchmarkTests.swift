import XCTest
import Foundation
import CoreVideo
import RFBProtocol
@testable import RFBTransport
@testable import RFBRendering
@testable import rootshellVNC

/// Live end-to-end video/audio pipeline benchmark against a real Apple
/// high-performance Screen Sharing server. Quantifies each stage's frame rate
/// so a "not 60 fps" report can be attributed to the exact bottleneck:
///
///   server-sent band access units/s   (what the encoder actually emitted)
///   → decoded band frames/s           (VideoToolbox output, per SSRC)
///   → synchronized full-set rate      (what the GUI renderer could commit)
///   plus decode submit→output latency, RTP throughput, and audio cadence.
///
/// Motion is generated through the client's own input path (pointer sweeps).
/// If the remote is already playing a video, the idle phase captures it.
///
///   VNC_TEST_HOST=... VNC_TEST_USERNAME=... VNC_TEST_PASSWORD='...' \
///   swift test --filter LiveVideoBenchmarkTests
///
/// Optional: VNC_BENCH_SECONDS=45  VNC_BENCH_IDLE_SECONDS=6
final class LiveVideoBenchmarkTests: XCTestCase {

    func testAdaptiveVideoPipelineBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900
        let benchSeconds = Int(env["VNC_BENCH_SECONDS"] ?? "45") ?? 45
        let idleSeconds = Int(env["VNC_BENCH_IDLE_SECONDS"] ?? "6") ?? 6
        let targetFrameRate = Int(env["VNC_BENCH_TARGET_FPS"] ?? "60") ?? 60

        let hp: [Encoding] = [
            .appleH264, .appleMultiVariantScreenshare, .zlib, .zrle,
            .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer,
        ]
        let session = TransportSession(
            host: host, port: port, password: pass, username: user,
            preferredEncodings: hp,
            targetFrameRate: targetFrameRate)
        let manager = VideoStreamManager()
        let bench = BenchState()

        // Ask once per manager loss episode, mirroring VNCSession. An older
        // version of this probe launched a 30-second FIR loop per loss, which
        // turned the measurement itself into a keyframe stress test.
        manager.onLossDetected = { [weak session] ssrc in
            bench.note("LOSS detected ssrc=\(ssrc.map { String($0 & 0xffff) } ?? "nil"); requesting keyframe")
            guard let session else { return }
            Task {
                let ready = await session.isReadyForVideoKeyframeRecovery()
                bench.note("keyframe request ready=\(ready)")
                await session.requestVideoKeyframe(ssrc: ssrc)
            }
        }

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .mediaStreamOffer(let offer):
                    bench.note("mediaStreamOffer stream=\(offer.streamID)")
                    guard !bench.streamStarted else {
                        bench.note("RE-OFFER while stream active")
                        continue
                    }
                    bench.streamStarted = true
                    let tileCount = await session.currentAppleMediaTilesPerFrame
                    manager.startStream(
                        streamID: offer.streamID,
                        width: 2976,
                        height: 1860,
                        usesDecodingOrderNumbers: tileCount > 1,
                        numberOfTiles: tileCount
                    ) { _, ssrc in
                        bench.recordDecodedFrame(ssrc: ssrc)
                    }
                    await session.setAppleMediaRTPSink { packet in
                        bench.recordPacket(packet)
                        guard !BenchState.isAudioPacket(packet) else { return }
                        let result = manager.feedRTPData(packet)
                        bench.recordNALTypes(result.nalUnitTypes)
                        if result.decodedNALUnitCount > 0,
                           let ssrc = BenchState.ssrc(of: packet) {
                            bench.recordSubmissions(
                                ssrc: ssrc, count: result.decodedNALUnitCount)
                        }
                    }
                case .appleMediaRTPPacket, .framebufferUpdate, .udpDatagram:
                    break
                default:
                    bench.note("EVENT \(String(describing: event).prefix(120))")
                }
            }
        }

        try? await session.connect()
        bench.note("connected; idle observation \(idleSeconds)s")

        // Optional: reproduce the GUI's Match Client virtual-display request
        // (VNC_BENCH_RESIZE=2976x1875). The fps comparison before/after this
        // renegotiation isolates the virtual display's effect on the encoder.
        var resizeSize: (w: UInt16, h: UInt16)?
        if let spec = env["VNC_BENCH_RESIZE"], !spec.isEmpty {
            let parts = spec.split(separator: "x").compactMap { UInt16($0) }
            if parts.count == 2 { resizeSize = (parts[0], parts[1]) }
            // Keep decode alive across the media renegotiation, mirroring
            // VNCSession's generation sink.
            await session.setAppleMediaGenerationSink { generation, tiles in
                bench.note("media generation \(generation) tiles=\(tiles)")
                manager.prepareForStreamReconfiguration(
                    mediaGeneration: generation,
                    numberOfTiles: tiles)
            }
        }

        let statsTask = Task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                bench.emitTick(tick, lossStats: manager.lossStatsSnapshot)
            }
        }

        try await Task.sleep(for: .seconds(idleSeconds))

        if let resizeSize {
            bench.beginPhase("resized")
            let disposition = try? await session.requestRemoteDisplaySize(
                pixelWidth: resizeSize.w,
                pixelHeight: resizeSize.h,
                pointWidth: resizeSize.w / 2,
                pointHeight: resizeSize.h / 2)
            bench.note("resize disposition: \(String(describing: disposition))")
            try await Task.sleep(for: .seconds(12))
        }

        // Transport-level one-shot loss injection: set
        // ROOTSHELL_VNC_TEST_DROP_VIDEO_AFTER_PACKETS=N on the process; this
        // phase only extends the observation window around the drop.
        if env["ROOTSHELL_VNC_TEST_DROP_VIDEO_AFTER_PACKETS"] != nil {
            bench.beginPhase("loss-inject")
            try await Task.sleep(for: .seconds(12))
        }

        // Bootstrap-recovery experiment: the media-stream request acts as a
        // stop while a stream is live, so send it twice — stop, then solicit
        // a fresh offer — and observe whether a new IRAP bootstraps decode.
        if env["VNC_BENCH_MEDIA_RESTART"] == "1" {
            bench.beginPhase("media-restart")
            await session.restartAppleMediaStream()
            try await Task.sleep(for: .seconds(3))
            bench.note(">>> second media stream request")
            await session.restartAppleMediaStream()
            try await Task.sleep(for: .seconds(12))
        }

        bench.beginPhase("motion")

        // Sustained motion through the client's own input path: a smooth
        // pointer sweep across the Dock (magnification/tooltip animation) at
        // ~60 events/s. VNC_BENCH_MOTION_Y overrides the hover row so the
        // sweep can be aimed at the Dock regardless of negotiated height.
        let motionY = UInt16(env["VNC_BENCH_MOTION_Y"] ?? "1852") ?? 1852
        let motionDeadline = ContinuousClock.now + .seconds(benchSeconds)
        var step = 0
        while ContinuousClock.now < motionDeadline {
            let phase = Double(step) / 240.0
            let x = UInt16(1488 + Int(1000 * sin(phase * 2 * .pi)))
            try? await session.sendPointerEvent(buttonMask: 0, x: x, y: motionY)
            step += 1
            try? await Task.sleep(for: .milliseconds(16))
        }

        bench.beginPhase("cooldown")
        try await Task.sleep(for: .seconds(2))

        statsTask.cancel()
        eventTask.cancel()
        await session.disconnect()
        manager.stopStream()
        bench.emitSummary()
    }

    /// Lock-guarded counters; every hot-path touch is a few integer ops.
    private final class BenchState: @unchecked Sendable {
        private let lock = NSLock()
        var streamStarted = false

        // Cumulative counters (read/reset by the ticker).
        private var decodedBySSRC: [UInt32: Int] = [:]
        private var submittedBySSRC: [UInt32: Int] = [:]
        private var videoPackets = 0
        private var videoBytes = 0
        private var audioPackets = 0
        private var audioBytes = 0
        private var lastAudioTimestamp: UInt32?
        private var audioTimestampFrames: UInt64 = 0

        // Full-set (compound frame) tracking: a "set" completes when every
        // band seen this second has advanced at least once.
        private var pendingSet: Set<UInt32> = []
        private var setCount = 0
        private var setIntervalsNanos: [UInt64] = []
        private var lastSetNanos: UInt64 = 0

        // Decode latency: per-SSRC FIFO of submission times matched to
        // decoder output callbacks (both sides are FIFO per band).
        private var submitTimesBySSRC: [UInt32: [UInt64]] = [:]
        private var decodeLatenciesNanos: [UInt64] = []

        // Per-band worst inter-frame gap within the current phase.
        private var lastFrameNanosBySSRC: [UInt32: UInt64] = [:]
        private var maxGapNanosBySSRC: [UInt32: UInt64] = [:]

        // Tick history for the summary, keyed by phase.
        private var phase = "idle"
        private var history: [(phase: String, decoded: [UInt32: Int],
                               submitted: [UInt32: Int], sets: Int,
                               videoKB: Int, audioPkts: Int)] = []
        private var lastTickDecoded: [UInt32: Int] = [:]
        private var lastTickSubmitted: [UInt32: Int] = [:]
        private var lastTickSets = 0
        private var lastTickVideoBytes = 0
        private var lastTickAudioPackets = 0

        static func isAudioPacket(_ data: Data) -> Bool {
            AppleRemoteAudioPlayer.canHandleRTPPacket(data)
        }


        static func ssrc(of packet: Data) -> UInt32? {
            guard packet.count >= 12 else { return nil }
            let b = packet.startIndex
            return UInt32(packet[b + 8]) << 24 | UInt32(packet[b + 9]) << 16
                | UInt32(packet[b + 10]) << 8 | UInt32(packet[b + 11])
        }

        static func rtpTimestamp(of packet: Data) -> UInt32? {
            guard packet.count >= 12 else { return nil }
            let b = packet.startIndex
            return UInt32(packet[b + 4]) << 24 | UInt32(packet[b + 5]) << 16
                | UInt32(packet[b + 6]) << 8 | UInt32(packet[b + 7])
        }

        func recordPacket(_ data: Data) {
            let isAudio = Self.isAudioPacket(data)
            lock.lock()
            if isAudio {
                audioPackets += 1
                audioBytes += data.count
                if let ts = Self.rtpTimestamp(of: data) {
                    if let last = lastAudioTimestamp {
                        let delta = ts &- last
                        if delta < 48_000 { audioTimestampFrames += UInt64(delta) }
                    }
                    lastAudioTimestamp = ts
                }
            } else {
                videoPackets += 1
                videoBytes += data.count
            }
            lock.unlock()
        }

        private var nalTypeCounts: [UInt8: Int] = [:]

        func recordNALTypes(_ types: [UInt8]) {
            guard !types.isEmpty else { return }
            lock.lock()
            for type in types { nalTypeCounts[type, default: 0] += 1 }
            lock.unlock()
        }

        func recordSubmissions(ssrc: UInt32, count: Int) {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            submittedBySSRC[ssrc, default: 0] += count
            var queue = submitTimesBySSRC[ssrc, default: []]
            if queue.count < 128 {
                for _ in 0..<count { queue.append(now) }
            }
            submitTimesBySSRC[ssrc] = queue
            lock.unlock()
        }

        func recordDecodedFrame(ssrc: UInt32) {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            decodedBySSRC[ssrc, default: 0] += 1

            if var queue = submitTimesBySSRC[ssrc], !queue.isEmpty {
                let submitted = queue.removeFirst()
                submitTimesBySSRC[ssrc] = queue
                if decodeLatenciesNanos.count < 100_000 {
                    decodeLatenciesNanos.append(now &- submitted)
                }
            }

            if let last = lastFrameNanosBySSRC[ssrc] {
                let gap = now &- last
                if gap > maxGapNanosBySSRC[ssrc, default: 0] {
                    maxGapNanosBySSRC[ssrc] = gap
                }
            }
            lastFrameNanosBySSRC[ssrc] = now

            pendingSet.insert(ssrc)
            if pendingSet.count >= decodedBySSRC.count, decodedBySSRC.count > 1 {
                setCount += 1
                if lastSetNanos != 0 {
                    setIntervalsNanos.append(now &- lastSetNanos)
                }
                lastSetNanos = now
                pendingSet.removeAll(keepingCapacity: true)
            }
            lock.unlock()
        }

        // Samples frozen when the motion phase ends, so teardown/cooldown
        // noise cannot pollute the summary.
        private var frozenLatencies: [UInt64] = []
        private var frozenIntervals: [UInt64] = []
        private var frozenGaps: [UInt32: UInt64] = [:]

        func beginPhase(_ name: String) {
            lock.lock()
            if phase == "motion" {
                frozenLatencies = decodeLatenciesNanos
                frozenIntervals = setIntervalsNanos
                frozenGaps = maxGapNanosBySSRC
            }
            phase = name
            lastFrameNanosBySSRC.removeAll()
            maxGapNanosBySSRC.removeAll()
            setIntervalsNanos.removeAll()
            decodeLatenciesNanos.removeAll()
            lock.unlock()
            note(">>> phase \(name)")
        }

        func note(_ s: String) { print("BENCH: \(s)") }

        func emitTick(_ tick: Int, lossStats: VideoStreamManager.LossStats) {
            lock.lock()
            var decodedDelta: [UInt32: Int] = [:]
            for (ssrc, n) in decodedBySSRC {
                decodedDelta[ssrc] = n - lastTickDecoded[ssrc, default: 0]
            }
            var submittedDelta: [UInt32: Int] = [:]
            for (ssrc, n) in submittedBySSRC {
                submittedDelta[ssrc] = n - lastTickSubmitted[ssrc, default: 0]
            }
            let setsDelta = setCount - lastTickSets
            let videoKB = (videoBytes - lastTickVideoBytes) / 1024
            let audioDelta = audioPackets - lastTickAudioPackets
            let nalTypes = nalTypeCounts
            nalTypeCounts.removeAll(keepingCapacity: true)
            lastTickDecoded = decodedBySSRC
            lastTickSubmitted = submittedBySSRC
            lastTickSets = setCount
            lastTickVideoBytes = videoBytes
            lastTickAudioPackets = audioPackets
            history.append((phase, decodedDelta, submittedDelta, setsDelta,
                            videoKB, audioDelta))
            let currentPhase = phase
            lock.unlock()

            var bands = ""
            for (ssrc, n) in decodedDelta.sorted(by: { $0.key < $1.key }) {
                let sub = submittedDelta[ssrc, default: 0]
                bands += "b\(ssrc & 0xffff)=\(sub)/\(n) "
            }
            let nalStr = nalTypes.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }.joined(separator: ",")
            note(String(format: "t=%02d [%@] sub/dec %@ sets=%d %.1fMbps audio=%d/s gaps=%d nal=[%@]",
                        tick, currentPhase, bands, setsDelta,
                        Double(videoKB) * 8.0 / 1000.0, audioDelta,
                        lossStats.gapsDetected, nalStr))
        }

        func emitSummary() {
            lock.lock()
            let motion = history.filter { $0.phase == "motion" }
            // Drop the first motion tick (ramp) for steady-state numbers.
            let steady = motion.count > 3 ? Array(motion.dropFirst(2)) : motion
            let latencies = (frozenLatencies.isEmpty
                ? decodeLatenciesNanos : frozenLatencies).sorted()
            let intervals = (frozenIntervals.isEmpty
                ? setIntervalsNanos : frozenIntervals).sorted()
            let gaps = frozenGaps.isEmpty ? maxGapNanosBySSRC : frozenGaps
            lock.unlock()

            func avg(_ values: [Int]) -> Double {
                values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
            }
            func pct(_ sorted: [UInt64], _ p: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
                return Double(sorted[idx]) / 1_000_000
            }

            note("================ BENCH SUMMARY ================")
            guard !steady.isEmpty else {
                note("no steady-state motion ticks captured")
                return
            }
            let allSSRCs = Set(steady.flatMap { $0.decoded.keys }).sorted()
            for ssrc in allSSRCs {
                let dec = avg(steady.map { $0.decoded[ssrc, default: 0] })
                let sub = avg(steady.map { $0.submitted[ssrc, default: 0] })
                let gapMs = Double(gaps[ssrc, default: 0]) / 1_000_000
                note(String(format: "band %5d: submitted %.1f AU/s, decoded %.1f fps, worst gap %.0f ms",
                            ssrc & 0xffff, sub, dec, gapMs))
            }
            note(String(format: "full-set rate: %.1f sets/s (interval p50=%.1fms p95=%.1fms max=%.1fms)",
                        avg(steady.map(\.sets)), pct(intervals, 0.5),
                        pct(intervals, 0.95), pct(intervals, 1.0)))
            note(String(format: "decode latency: p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms (n=%d)",
                        pct(latencies, 0.5), pct(latencies, 0.95),
                        pct(latencies, 0.99), pct(latencies, 1.0), latencies.count))
            note(String(format: "video throughput: %.1f Mbps avg, %.1f Mbps peak",
                        avg(steady.map(\.videoKB)) * 8 / 1000,
                        Double(steady.map(\.videoKB).max() ?? 0) * 8 / 1000))
            note(String(format: "audio: %.1f pkts/s avg", avg(steady.map(\.audioPkts))))
            note("===============================================")
        }
    }
}
