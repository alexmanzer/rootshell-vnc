import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import RFBProtocol
@testable import RFBTransport
@testable import RFBRendering

/// Live probe for the classic (standard) RFB path against a real server.
///
/// Exercises exactly what the app's standard mode does — bgra8888 pixel
/// format, [copyRect, zrle, zlib, raw] encodings, pipelined update requests
/// with credit acknowledgement, persistent Zlib/ZRLE decode — and reports
/// per-second update cadence, payload sizes, and encoding mix. Any
/// "Zlib rectangle decoded N bytes" / "Invalid ZRLE subencoding" issue is a
/// stream-desync canary and fails the test.
///
///   VNC_TEST_HOST=... VNC_TEST_USERNAME=... VNC_TEST_PASSWORD='...' \
///     swift test --filter LiveStandardModeProbeTests
///
/// Optional: VNC_PROBE_SECONDS=N (motion phase length, default 12),
/// ROOTSHELL_VNC_FRAME_OUT_DIR=<dir> (dump decoded PNGs).
final class LiveStandardModeProbeTests: XCTestCase {

    func testStandardModeUpdateCadenceAndDecodeHealth() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900
        let motionSeconds = Int(env["VNC_PROBE_SECONDS"] ?? "12") ?? 12
        let outDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"]

        // Mirror VNCConfiguration(videoQualityMode: .standard).effectiveEncodings.
        // VNC_PROBE_ENCODING=zlib flips the preference for A/B comparison.
        let preferZlib = env["VNC_PROBE_ENCODING"] == "zlib"
        let encodings: [Encoding] = preferZlib
            ? [.copyRect, .zlib, .zrle, .raw, .desktopSize, .extendedDesktopSize, .cursor]
            : [.copyRect, .zrle, .zlib, .raw, .desktopSize, .extendedDesktopSize, .cursor]
        // VNC_PROBE_DEPTH=16 negotiates rgb555 (standard mode's default).
        let pixelFormat: PixelFormat =
            env["VNC_PROBE_DEPTH"] == "16" ? .rgb555 : .bgra8888
        let session = TransportSession(
            host: host, port: port, password: pass, username: user,
            preferredPixelFormat: pixelFormat,
            preferredEncodings: encodings)

        actor ProbeStats {
            var updates = 0
            var bytes = 0
            var rects = 0
            var encodingCounts: [String: Int] = [:]
            var payloadSizes: [Int] = []
            var issues: [String] = []
            var interUpdateGapsMs: [Double] = []
            var lastUpdateNanos: UInt64 = 0
            var sawCursor = false

            func record(rects rectsWithData: [(FramebufferRect, Data)]) {
                updates += 1
                rects += rectsWithData.count
                var updateBytes = 0
                for (rect, data) in rectsWithData {
                    updateBytes += data.count
                    encodingCounts[String(describing: rect.encoding), default: 0] += 1
                    if rect.encoding == .cursor { sawCursor = true }
                }
                bytes += updateBytes
                payloadSizes.append(updateBytes)
                let now = DispatchTime.now().uptimeNanoseconds
                if lastUpdateNanos != 0 {
                    interUpdateGapsMs.append(Double(now - lastUpdateNanos) / 1e6)
                }
                lastUpdateNanos = now
            }

            func note(issues newIssues: [String]) {
                issues.append(contentsOf: newIssues)
            }

            func summary(label: String) -> String {
                let sorted = payloadSizes.sorted()
                let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
                let maxPayload = sorted.last ?? 0
                let gaps = interUpdateGapsMs.sorted()
                let medGap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
                return """
                [\(label)] updates=\(updates) rects=\(rects) totalKB=\(bytes / 1024) \
                payload median=\(median)B p95=\(p95)B max=\(maxPayload)B \
                interUpdate median=\(String(format: "%.1f", medGap))ms \
                encodings=\(encodingCounts) cursorRect=\(sawCursor) issues=\(issues.count)
                """
            }

            func reset() {
                updates = 0; bytes = 0; rects = 0
                encodingCounts = [:]; payloadSizes = []
                interUpdateGapsMs = []; lastUpdateNanos = 0
            }
        }

        let stats = ProbeStats()
        let rendererBox = RendererBox()

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .serverInit(let si):
                    print("PROBE serverInit \(si.framebufferWidth)x\(si.framebufferHeight) name=\(si.name)")
                    rendererBox.configure(
                        width: Int(si.framebufferWidth),
                        height: Int(si.framebufferHeight),
                        pixelFormat: pixelFormat)
                case .framebufferUpdate(let rectsWithData):
                    await stats.record(rects: rectsWithData)
                    if let result = rendererBox.apply(rectsWithData) {
                        await stats.note(issues: result.issues)
                    }
                    try? await session.finishFramebufferUpdate()
                case .error(let error):
                    print("PROBE ERROR \(error)")
                case .stateChanged(let state):
                    print("PROBE state \(state)")
                default:
                    break
                }
            }
        }

        try await session.connect()

        // Phase 1: idle screen.
        try await Task.sleep(for: .seconds(4))
        let idleSummary = await stats.summary(label: "idle")
        print("PROBE \(idleSummary)")
        await stats.reset()

        // Phase 2: motion — sweep the pointer diagonally across the screen so
        // it crosses UI elements (cursor-shape changes and hover effects both
        // dirty the framebuffer).
        let deadline = Date().addingTimeInterval(TimeInterval(motionSeconds))
        var i = 0
        while Date() < deadline {
            let t = i % 40
            try? await session.sendPointerEvent(
                buttonMask: 0,
                x: UInt16(200 + t * 64),
                y: UInt16(200 + t * 36))
            try? await Task.sleep(for: .milliseconds(50))
            i += 1
        }
        let motionSummary = await stats.summary(label: "motion")
        print("PROBE \(motionSummary)")
        await stats.reset()

        // Phase 3: loop-alive + latency measurement. A static screen answers
        // incremental requests with silence (correct RFB), so force full
        // non-incremental updates and time request -> update-received. This
        // is the end-to-end number: server encode + transfer + client read.
        var fullUpdateMs: [Double] = []
        for round in 0..<5 {
            let before = await stats.updates
            let start = DispatchTime.now().uptimeNanoseconds
            try await session.requestFramebufferUpdate(incremental: false)
            var waited = 0
            while await stats.updates == before, waited < 100 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            let arrived = await stats.updates > before
            fullUpdateMs.append(elapsed)
            print("PROBE fullUpdate round=\(round) arrived=\(arrived) ms=\(String(format: "%.0f", elapsed))")
            XCTAssertTrue(arrived, "update loop is dead: non-incremental request got no response")
        }
        let fullSummary = await stats.summary(label: "full-updates")
        print("PROBE \(fullSummary)")
        print("PROBE fullUpdate median ms=\(fullUpdateMs.sorted()[fullUpdateMs.count / 2])")

        if let outDir {
            try? FileManager.default.createDirectory(
                atPath: outDir, withIntermediateDirectories: true)
            rendererBox.dumpPNG(to: outDir + "/standard_probe_final.png")
        }

        let issues = await stats.issues
        eventTask.cancel()
        await session.disconnect()

        XCTAssertTrue(issues.isEmpty, "decode issues (desync canary): \(issues.prefix(5))")
    }
}

/// Non-Sendable renderer confined to a serial queue, mirroring VNCSession's
/// framebufferRenderQueue usage.
private final class RendererBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "probe.render")
    private var renderer: FramebufferRenderer?
    private var framebuffer: Framebuffer?
    private var pixelFormat: PixelFormat = .bgra8888

    func configure(width: Int, height: Int, pixelFormat: PixelFormat) {
        queue.sync {
            self.pixelFormat = pixelFormat
            let fb = Framebuffer(width: width, height: height, pixelFormat: pixelFormat)
            framebuffer = fb
            renderer = FramebufferRenderer(framebuffer: fb, pixelFormat: pixelFormat)
        }
    }

    func apply(_ rects: [(FramebufferRect, Data)]) -> FramebufferRenderBatchResult? {
        queue.sync {
            guard let renderer else { return nil }
            if let resize = rects.first(where: { $0.0.isSuccessfulDesktopResize }) {
                let fb = Framebuffer(
                    width: Int(resize.0.width),
                    height: Int(resize.0.height),
                    pixelFormat: pixelFormat)
                framebuffer = fb
                self.renderer = FramebufferRenderer(framebuffer: fb, pixelFormat: pixelFormat)
                return self.renderer?.applyBatch(rects, snapshot: false)
            }
            return renderer.applyBatch(rects, snapshot: false)
        }
    }

    func dumpPNG(to path: String) {
        queue.sync {
            guard let image = renderer?.snapshot(),
                  let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
