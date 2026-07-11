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
@testable import RootShellVNC

/// Connects to a live server over the network and runs the REAL-TIME media
/// pipeline exactly like the app (transport → RTP sink → VideoStreamManager →
/// HEVCDecoder), then reports per-band frame counts and detects "green" frames
/// (decoder concealment output with no valid reference). This reproduces the
/// connect-time green garbage that offline decode of a full capture cannot.
///
///   VNC_TEST_HOST=192.168.46.111 VNC_TEST_USERNAME=kknox VNC_TEST_PASSWORD='...' \
///   swift test --filter WiFiRealtimeBandTests
final class WiFiRealtimeBandTests: XCTestCase {

    @MainActor
    func testMatchClientRetinaSurvivesArbitraryLiveResizes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let credentials = VNCCredentials(
            host: host,
            port: UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: pass,
            username: env["VNC_TEST_USERNAME"])
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: .matchClient,
            enableRemoteAudio: false))
        let viewSizes = [
            CGSize(width: 1197, height: 837),
            CGSize(width: 1283, height: 779),
            CGSize(width: 1024, height: 1366),
        ]

        session.updateRemoteDisplaySize(viewSize: viewSizes[0], displayScale: 2)
        try await session.connect(credentials: credentials)
        defer { session.disconnect() }

        try await waitForRenderedBands(
            session,
            expectedSize: try XCTUnwrap(
                RemoteDisplaySize.matching(viewSize: viewSizes[0])),
            expectedBandCount: expectedBandCount(for: viewSizes[0]),
            afterCommit: 0,
            timeoutSeconds: 15)
        XCTAssertTrue(session.isHighPerformanceMode)
        XCTAssertEqual(
            session.videoBandRenderer.renderedBandCount,
            expectedBandCount(for: viewSizes[0]))
        try await assertContinuesAtomicRendering(
            session,
            expectedBandCount: expectedBandCount(for: viewSizes[0]))

        for viewSize in viewSizes.dropFirst() {
            let priorCommit = session.videoBandRenderer.frameCommitCount
            let priorGeneration = session.videoBandRenderer.streamGenerationCount
            session.updateRemoteDisplaySize(viewSize: viewSize, displayScale: 2)
            try await waitForRenderedBands(
                session,
                expectedSize: try XCTUnwrap(
                    RemoteDisplaySize.matching(viewSize: viewSize)),
                expectedBandCount: expectedBandCount(for: viewSize),
                afterCommit: priorCommit,
                afterGeneration: priorGeneration,
                timeoutSeconds: 15)
            XCTAssertEqual(
                session.videoBandRenderer.renderedBandCount,
                expectedBandCount(for: viewSize),
                "Match Client resize to \(viewSize) must render its negotiated Retina tiles")
            try await assertContinuesAtomicRendering(
                session,
                expectedBandCount: expectedBandCount(for: viewSize))
        }
    }

    func testRealtimeBandHealthOverNetwork() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900

        let hp: [Encoding] = [
            .appleH264, .appleMultiVariantScreenshare, .appleSubZlibThousands, .zlib, .zrle,
            .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer,
        ]
        let session = TransportSession(host: host, port: port, password: pass, username: user, preferredEncodings: hp)
        let manager = VideoStreamManager()
        let stats = BandStats()

        if env["VNC_TEST_MATCH_CLIENT"] == "1" {
            _ = try await session.requestRemoteDisplaySize(
                pixelWidth: 2400,
                pixelHeight: 1680,
                pointWidth: 1200,
                pointHeight: 840)
        }

        // Optionally dump live-decoded frames over time to see drift accumulate.
        let frameOutDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"]
        if let d = frameOutDir { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let ciContext = CIContext()
        let frameCounter = BandStats.Counter()

        let eventTask = Task {
            for await event in session.events {
                if env["VNC_TEST_MATCH_CLIENT"] == "1" {
                    switch event {
                    case .appleMediaRTPPacket, .udpDatagram, .framebufferUpdate:
                        break
                    default:
                        print("MATCH CLIENT EVENT: \(event)")
                    }
                }
                if case .mediaStreamOffer = event {
                    manager.startStream(streamID: 1, width: 2976, height: 1860) { pixelBuffer, ssrc in
                        stats.record(ssrc: ssrc, green: isGreen(pixelBuffer))
                        // Save one frame per SSRC every ~2s of frames so we can
                        // compare early vs late (live drift).
                        if let dir = frameOutDir {
                            let n = frameCounter.next()
                            if n % 96 == 0, n / 96 < 20 {
                                let ci = CIImage(cvPixelBuffer: pixelBuffer)
                                let url = URL(fileURLWithPath: dir).appendingPathComponent("live_\(n)_ssrc\(ssrc).png")
                                if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                                    let rep = NSBitmapImageRep(cgImage: cg)
                                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                                }
                            }
                        }
                    }
                    await session.setAppleMediaRTPSink { packet in
                        _ = manager.feedRTPData(packet)
                    }
                }
            }
        }

        try await session.connect()
        let waitSeconds = Double(env["VNC_TEST_WAIT_SECONDS"] ?? "8") ?? 8
        try await Task.sleep(for: .seconds(waitSeconds))
        eventTask.cancel()
        await session.disconnect()
        manager.stopStream()
        try await Task.sleep(for: .seconds(0.3))

        let snapshot = stats.report()
        let progress = manager.decodeProgress
        print(
            "decode submissions=\(progress.submittedFrameCount) "
                + "outputs=\(progress.decoderOutputCount) "
                + "videoSources=\(await session.videoSourceCount) "
                + "loss=\(manager.lossStatsSnapshot)")
        XCTAssertGreaterThan(
            snapshot.totalFrames,
            0,
            "The live Adaptive pipeline must decode at least one video frame")
    }

    @MainActor
    private func waitForRenderedBands(
        _ session: VNCSession,
        expectedSize: RemoteDisplaySize,
        expectedBandCount: Int,
        afterCommit: UInt64,
        afterGeneration: UInt64? = nil,
        timeoutSeconds: Double
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if session.videoBandRenderer.frameCommitCount > afterCommit,
               afterGeneration.map({
                   session.videoBandRenderer.streamGenerationCount > $0
               }) ?? true,
               session.videoBandRenderer.renderedBandCount == expectedBandCount,
               session.framebufferWidth == Int(expectedSize.pixelWidth),
               session.framebufferHeight == Int(expectedSize.pixelHeight),
               session.videoBandRenderer.renderedBandDimensions.allSatisfy({
                   $0.width == Int(expectedSize.pixelWidth)
               }) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(
            "Timed out waiting for Match Client tiles; commits="
                + "\(session.videoBandRenderer.frameCommitCount) bands="
                + "\(session.videoBandRenderer.renderedBandCount) generations="
                + "\(session.videoBandRenderer.streamGenerationCount) media="
                + "\(session.liveMediaDebugSnapshot) dims="
                + "\(session.videoBandRenderer.renderedBandDimensions)")
    }

    @MainActor
    private func assertContinuesAtomicRendering(
        _ session: VNCSession,
        expectedBandCount: Int
    ) async throws {
        let priorCommit = session.videoBandRenderer.frameCommitCount
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(
            session.videoBandRenderer.frameCommitCount,
            priorCommit,
            "Match Client tiles must continue rendering after the first image")
        XCTAssertEqual(
            session.videoBandRenderer.lastCommitBandCount,
            expectedBandCount)
        XCTAssertEqual(
            session.videoBandRenderer.partialCommitCount,
            0,
            "The Metal/Core Animation handoff must never publish a partial tile set")
    }

    private func expectedBandCount(for viewSize: CGSize) -> Int {
        guard let size = RemoteDisplaySize.matching(viewSize: viewSize) else { return 1 }
        return Int(size.pixelWidth) * Int(size.pixelHeight) >= 5_000_000 ? 2 : 1
    }

    private final class BandStats: @unchecked Sendable {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        private let lock = NSLock()
        private var total: [UInt32: Int] = [:]
        private var green: [UInt32: Int] = [:]
        private var firstGreenAfterGood: [UInt32: Bool] = [:]
        private var lastWasGood: [UInt32: Bool] = [:]

        func record(ssrc: UInt32, green isG: Bool) {
            lock.lock(); defer { lock.unlock() }
            total[ssrc, default: 0] += 1
            if isG { green[ssrc, default: 0] += 1 }
        }
        func report() -> (totalFrames: Int, greenFrames: Int) {
            lock.lock(); defer { lock.unlock() }
            print("=== REALTIME BAND HEALTH ===")
            print("distinct bands (SSRCs) that produced frames: \(total.count)")
            for (ssrc, n) in total.sorted(by: { $0.key < $1.key }) {
                let g = green[ssrc, default: 0]
                print(String(format: "  band ssrc=%u frames=%d green=%d (%.0f%%)",
                             ssrc & 0xffff, n, g, 100.0 * Double(g) / Double(max(1, n))))
            }
            let allGreen = green.values.reduce(0, +)
            let allTotal = total.values.reduce(0, +)
            print("TOTAL frames=\(allTotal) green=\(allGreen)")
            return (allTotal, allGreen)
        }
    }
}

/// Sample a grid of pixels; a decoder-concealment "green" frame has G strongly
/// dominant over R and B across the whole frame.
private func isGreen(_ pb: CVPixelBuffer) -> Bool {
    guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return false }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    var greenish = 0, samples = 0
    var y = 8
    while y < h { var x = 8
        while x < w {
            let p = y * stride + x * 4
            let b = Int(ptr[p]), g = Int(ptr[p + 1]), r = Int(ptr[p + 2])
            if g > 90 && g > r + 40 && g > b + 40 { greenish += 1 }
            samples += 1
            x += 64
        }
        y += 32
    }
    return samples > 0 && greenish * 100 / samples > 80
}
