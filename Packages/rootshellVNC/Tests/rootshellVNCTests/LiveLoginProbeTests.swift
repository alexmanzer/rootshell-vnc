import XCTest
import Foundation
import CoreVideo
import CoreImage
#if canImport(AppKit)
import AppKit
#endif
import RFBProtocol
@testable import RFBTransport
@testable import RFBRendering

/// Live diagnostic probe: connects to a real server, captures the idle login
/// view, then TYPES THE PASSWORD remotely (motion + session switch — the two
/// conditions the macroblocks/freeze are reported under), while logging:
///   - per-band decoded frame deltas each second (a stall shows as 0s)
///   - RTP packet/byte deltas each second (distinguishes transport death from
///     decode death)
///   - loss-gating stats (gaps detected / frames gated / IRAPs decoded)
///   - every non-media event from the transport (a mid-session re-offer!)
/// and dumping each band's latest frame as PNG every 2 s for visual macroblock
/// inspection.
///
///   VNC_TEST_HOST=... VNC_TEST_USERNAME=... VNC_TEST_PASSWORD='...' \
///   VNC_PROBE_LOGIN=1 ROOTSHELL_VNC_FRAME_OUT_DIR=/tmp/probe \
///   swift test --filter LiveLoginProbeTests
final class LiveLoginProbeTests: XCTestCase {

    func testLoginMotionAndFreezeProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900
        let doLogin = env["VNC_PROBE_LOGIN"] == "1"
        let outDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"] ?? NSTemporaryDirectory() + "/login_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let resizeSize: (width: UInt16, height: UInt16)? = {
            guard let spec = env["VNC_PROBE_RESIZE"] else { return nil }
            let parts = spec.split(separator: "x").compactMap { UInt16($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }()

        let hp: [Encoding] = [
            .appleH264, .appleMultiVariantScreenshare, .appleSubZlibThousands, .zlib, .zrle,
            .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer,
        ]
        let session = TransportSession(host: host, port: port, password: pass, username: user, preferredEncodings: hp)
        let manager = VideoStreamManager()
        let probe = ProbeState()

        // One immediate FIR per manager loss episode, matching VNCSession.
        manager.onLossDetected = { [weak session] ssrc in
            probe.note("LOSS DETECTED -> requesting keyframe")
            Task {
                await session?.requestVideoKeyframe(ssrc: ssrc)
            }
        }

        if resizeSize != nil {
            await session.setAppleMediaGenerationSink { generation, tiles in
                probe.note("media generation \(generation) tiles=\(tiles)")
                manager.prepareForStreamReconfiguration(
                    mediaGeneration: generation,
                    numberOfTiles: tiles)
            }
        }

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .mediaStreamOffer(let offer):
                    probe.note("EVENT mediaStreamOffer stream=\(offer.streamID) payloadBytes=\(offer.rawPayload.count)")
                    if !probe.streamStarted {
                        probe.streamStarted = true
                        manager.startStream(
                            streamID: offer.streamID,
                            width: 2976,
                            height: 1860,
                            numberOfTiles: Int(AppleMediaVideoMode.negotiatedTilesPerFrame)
                        ) { pb, ssrc in
                            probe.recordFrame(ssrc: ssrc, pixelBuffer: pb)
                        }
                        await session.setAppleMediaRTPSink { packet in
                            probe.recordPacket(bytes: packet.count)
                            let result = manager.feedRTPData(packet)
                            // Log the first few video packets' RTP timestamps to
                            // characterize the send cadence (constant vs advancing).
                            if result.payloadType == 100, probe.tsSamplesRemaining() > 0,
                               let ts = result.timestamp, let seq = result.sequenceNumber {
                                probe.note("RTP ts sample: seq=\(seq) ts=\(ts)")
                            }
                        }
                    } else {
                        probe.note("SECOND OFFER while stream active (login re-offer?)")
                    }
                case .appleMediaRTPPacket:
                    break // fast-path sink installed; shouldn't appear
                case .udpDatagram:
                    // RTP-shaped packets that failed SRTP unprotect fall out
                    // here — a burst of these means the server re-keyed.
                    probe.recordRawDatagram()
                case .framebufferUpdate:
                    break
                case .displayInfo(let display):
                    manager.updateFrameGeometry(
                        width: Int(display.width),
                        height: Int(display.height))
                    probe.note("EVENT displayInfo \(display.width)x\(display.height)")
                default:
                    probe.note("EVENT \(String(describing: event).prefix(120))")
                }
            }
        }

        try? await session.connect()
        probe.note("connected; observing idle login view")

        // Per-second stats reporter + per-2s frame dumper.
        let statsTask = Task {
            var lastFrames: [UInt32: Int] = [:]
            var lastPackets = (count: 0, bytes: 0)
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                let frames = probe.frameCounts()
                let packets = probe.packetTotals()
                let stats = manager.lossStatsSnapshot
                var bandStr = ""
                for (ssrc, n) in frames.sorted(by: { $0.key < $1.key }) {
                    bandStr += "b\(ssrc & 0xffff)=+\(n - lastFrames[ssrc, default: 0]) "
                }
                probe.note(String(format: "t=%02d %@ pkts=+%d kB=+%d raw=%d gaps=%d gated=%d dropped=%d iraps=%d",
                                  tick, bandStr, packets.count - lastPackets.count,
                                  (packets.bytes - lastPackets.bytes) / 1024,
                                  probe.rawDatagramTotal(),
                                  stats.gapsDetected, stats.gatedBandCount,
                                  stats.framesDroppedWhileGated, stats.irapsDecoded))
                lastFrames = frames
                lastPackets = packets
                if tick % 2 == 0 { probe.dumpLatestFrames(to: outDir, tag: "t\(String(format: "%02d", tick))") }
            }
        }

        try await Task.sleep(for: .seconds(6))

        if let resizeSize {
            probe.note("requesting virtual display \(resizeSize.width)x\(resizeSize.height)")
            _ = try await session.requestRemoteDisplaySize(
                pixelWidth: resizeSize.width,
                pixelHeight: resizeSize.height,
                pointWidth: resizeSize.width / 2,
                pointHeight: resizeSize.height / 2)
            try await Task.sleep(for: .seconds(5))
        }

        if env["VNC_PROBE_FORCE_RECOVERY"] == "1" {
            let sources = Set(probe.frameCounts().keys)
            probe.note("forcing recovery gate for \(sources.count) live sources")
            // The IRAP gate is off by default; enable it to exercise the
            // gate-clear path this probe validates.
            manager.irapGateEnabled = true
            manager.installCompoundRecoveryGateForTesting(sources: sources)
            await session.requestVideoKeyframe()
            try await Task.sleep(for: .seconds(2))
            XCTAssertFalse(
                manager.hasGatedBands,
                "a decoded live recovery IDR must release the compound gate")
        }

        if doLogin {
            probe.note("typing password remotely to log in")
            // Wake the screen / focus the password field first.
            try? await session.sendPointerEvent(buttonMask: 0, x: 1488, y: 930)
            try? await session.sendPointerEvent(buttonMask: 1, x: 1488, y: 930)
            try? await session.sendPointerEvent(buttonMask: 0, x: 1488, y: 930)
            try? await Task.sleep(for: .seconds(2))
            for scalar in pass.unicodeScalars {
                let keysym = UInt32(scalar.value) // ASCII == keysym for printable chars
                try? await session.sendKeyEvent(downFlag: true, key: keysym)
                try? await session.sendKeyEvent(downFlag: false, key: keysym)
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await session.sendKeyEvent(downFlag: true, key: 0xFF0D) // Return
            try? await session.sendKeyEvent(downFlag: false, key: 0xFF0D)
            probe.note("password submitted; watching login transition")
        }

        // Sweep the pointer along the Dock: magnification animation = real
        // full-band motion, the condition macroblocks/tearing show under.
        let sweeps = Int(env["VNC_PROBE_SWEEPS"] ?? "24") ?? 24
        let motionDelayMS = max(
            1, Int(env["VNC_PROBE_MOTION_DELAY_MS"] ?? "1000") ?? 1000)
        let motionY = UInt16(env["VNC_PROBE_MOTION_Y"] ?? "1780") ?? 1780
        for i in 0..<sweeps {
            let x = UInt16(400 + (i % 12) * 180)
            try? await session.sendPointerEvent(buttonMask: 0, x: x, y: motionY)
            try? await Task.sleep(for: .milliseconds(motionDelayMS))
        }

        statsTask.cancel()
        eventTask.cancel()
        await session.disconnect()
        manager.stopStream()
        try await Task.sleep(for: .seconds(0.3))
        probe.dumpLatestFrames(to: outDir, tag: "final")
        probe.flushLog()
    }

    /// Locks the remote screen (Ctrl+Cmd+Q), watches the stream across the
    /// session switch to loginwindow, then types the password to unlock and
    /// watches the switch back. This is the transition the "video freezes when
    /// I log into the remote computer" report describes. Opt-in:
    ///
    ///   VNC_PROBE_LOCK=1 (plus the usual VNC_TEST_* vars)
    func testLockUnlockTransitionProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VNC_PROBE_LOCK"] == "1" else {
            throw XCTSkip("Set VNC_PROBE_LOCK=1 to run the lock/unlock probe")
        }
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900
        let outDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"] ?? NSTemporaryDirectory() + "/lock_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let hp: [Encoding] = [
            .appleH264, .appleMultiVariantScreenshare, .appleSubZlibThousands, .zlib, .zrle,
            .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer,
        ]
        let session = TransportSession(host: host, port: port, password: pass, username: user, preferredEncodings: hp)
        let manager = VideoStreamManager()
        let probe = ProbeState()

        manager.onLossDetected = { [weak session, weak manager] _ in
            Task {
                var attempts = 0
                while let m = manager, let s = session, m.hasGatedBands, attempts < 40 {
                    await s.requestVideoKeyframe()
                    attempts += 1
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .mediaStreamOffer(let offer):
                    probe.note("EVENT mediaStreamOffer stream=\(offer.streamID) payloadBytes=\(offer.rawPayload.count)")
                    if !probe.streamStarted {
                        probe.streamStarted = true
                        manager.startStream(streamID: offer.streamID, width: 2976, height: 1860) { pb, ssrc in
                            probe.recordFrame(ssrc: ssrc, pixelBuffer: pb)
                        }
                        await session.setAppleMediaRTPSink { packet in
                            probe.recordPacket(bytes: packet.count)
                            _ = manager.feedRTPData(packet)
                        }
                    } else {
                        probe.note("RE-OFFER while stream active — server restarted media stream")
                    }
                case .appleMediaRTPPacket, .framebufferUpdate:
                    break
                case .udpDatagram:
                    probe.recordRawDatagram()
                default:
                    probe.note("EVENT \(String(describing: event).prefix(140))")
                }
            }
        }

        try? await session.connect()

        let statsTask = Task {
            var lastFrames: [UInt32: Int] = [:]
            var lastPackets = (count: 0, bytes: 0)
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                let frames = probe.frameCounts()
                let packets = probe.packetTotals()
                let stats = manager.lossStatsSnapshot
                var bandStr = ""
                for (ssrc, n) in frames.sorted(by: { $0.key < $1.key }) {
                    bandStr += "b\(ssrc & 0xffff)=+\(n - lastFrames[ssrc, default: 0]) "
                }
                probe.note(String(format: "t=%02d %@ pkts=+%d kB=+%d raw=%d gaps=%d",
                                  tick, bandStr, packets.count - lastPackets.count,
                                  (packets.bytes - lastPackets.bytes) / 1024,
                                  probe.rawDatagramTotal(), stats.gapsDetected))
                lastFrames = frames
                lastPackets = packets
                if tick % 2 == 0 { probe.dumpLatestFrames(to: outDir, tag: "t\(String(format: "%02d", tick))") }
            }
        }

        try await Task.sleep(for: .seconds(5))

        probe.note(">>> sending Ctrl+Cmd+Q (lock screen)")
        try? await session.sendKeyEvent(downFlag: true, key: 0xFFE3)  // Control_L
        try? await session.sendKeyEvent(downFlag: true, key: 0xFFEB)  // Super_L (Command)
        try? await session.sendKeyEvent(downFlag: true, key: 0x71)    // q
        try? await session.sendKeyEvent(downFlag: false, key: 0x71)
        try? await session.sendKeyEvent(downFlag: false, key: 0xFFEB)
        try? await session.sendKeyEvent(downFlag: false, key: 0xFFE3)

        try await Task.sleep(for: .seconds(10))

        probe.note(">>> typing password to unlock")
        try? await session.sendPointerEvent(buttonMask: 0, x: 1488, y: 930) // wake
        try? await Task.sleep(for: .seconds(2))
        for scalar in pass.unicodeScalars {
            try? await session.sendKeyEvent(downFlag: true, key: UInt32(scalar.value))
            try? await session.sendKeyEvent(downFlag: false, key: UInt32(scalar.value))
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await session.sendKeyEvent(downFlag: true, key: 0xFF0D)
        try? await session.sendKeyEvent(downFlag: false, key: 0xFF0D)
        probe.note(">>> password submitted")

        try await Task.sleep(for: .seconds(15))

        statsTask.cancel()
        eventTask.cancel()
        await session.disconnect()
        manager.stopStream()
        try await Task.sleep(for: .seconds(0.3))
        probe.dumpLatestFrames(to: outDir, tag: "final")
    }

    /// Thread-safe probe bookkeeping + frame retention for PNG dumps.
    private final class ProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [UInt32: Int] = [:]
        private var latest: [UInt32: CVPixelBuffer] = [:]
        private var packetCount = 0
        private var packetBytes = 0
        private var lines: [String] = []
        private let ciContext = CIContext()
        var streamStarted = false

        func recordFrame(ssrc: UInt32, pixelBuffer: CVPixelBuffer) {
            lock.lock(); defer { lock.unlock() }
            frames[ssrc, default: 0] += 1
            latest[ssrc] = pixelBuffer
        }
        func recordPacket(bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            packetCount += 1
            packetBytes += bytes
        }
        private var rawDatagrams = 0
        func recordRawDatagram() {
            lock.lock(); defer { lock.unlock() }
            rawDatagrams += 1
        }
        func rawDatagramTotal() -> Int { lock.lock(); defer { lock.unlock() }; return rawDatagrams }
        private var tsSamples = 12
        func tsSamplesRemaining() -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = tsSamples
            if n > 0 { tsSamples -= 1 }
            return n
        }
        func frameCounts() -> [UInt32: Int] { lock.lock(); defer { lock.unlock() }; return frames }
        func packetTotals() -> (count: Int, bytes: Int) {
            lock.lock(); defer { lock.unlock() }; return (packetCount, packetBytes)
        }
        func note(_ s: String) {
            lock.lock(); lines.append(s); lock.unlock()
            print("PROBE: \(s)")
        }
        func flushLog() { lock.lock(); defer { lock.unlock() }; lines.removeAll() }

        func dumpLatestFrames(to dir: String, tag: String) {
            let snapshot: [UInt32: CVPixelBuffer] = { lock.lock(); defer { lock.unlock() }; return latest }()
            #if canImport(AppKit)
            for (ssrc, pb) in snapshot {
                let ci = CIImage(cvPixelBuffer: pb)
                guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(tag)_band\(ssrc & 0xffff).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            #endif
        }
    }
}
