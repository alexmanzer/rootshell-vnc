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

/// Connects to a live server over the network and runs the REAL-TIME media
/// pipeline exactly like the app (transport → RTP sink → VideoStreamManager →
/// HEVCDecoder), then reports per-band frame counts and detects "green" frames
/// (decoder concealment output with no valid reference). This reproduces the
/// connect-time green garbage that offline decode of a full capture cannot.
///
///   VNC_TEST_HOST=192.168.46.111 VNC_TEST_USERNAME=kknox VNC_TEST_PASSWORD='...' \
///   swift test --filter WiFiRealtimeBandTests
final class WiFiRealtimeBandTests: XCTestCase {

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

        // Optionally dump live-decoded frames over time to see drift accumulate.
        let frameOutDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"]
        if let d = frameOutDir { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let ciContext = CIContext()
        let frameCounter = BandStats.Counter()

        let eventTask = Task {
            for await event in session.events {
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

        try? await session.connect()
        let waitSeconds = Double(env["VNC_TEST_WAIT_SECONDS"] ?? "8") ?? 8
        try await Task.sleep(for: .seconds(waitSeconds))
        eventTask.cancel()
        await session.disconnect()
        manager.stopStream()
        try await Task.sleep(for: .seconds(0.3))

        stats.report()
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
        func report() {
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
