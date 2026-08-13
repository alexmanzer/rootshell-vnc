import XCTest
import Foundation
import CoreVideo
import CoreImage
#if canImport(AppKit)
import AppKit
#endif
@testable import RFBRendering

#if canImport(AppKit)
private func fourCCString(_ v: OSType) -> String {
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
}


/// Feeds a capture of ALREADY-DECRYPTED, framed RTP (produced with
/// ROOTSHELL_VNC_DUMP_DECODED_RTP) through the real VideoStreamManager +
/// HEVCDecoder (VideoToolbox), and writes decoded frames to PNG so we can
/// compare the app's decode against a reference software (ffmpeg) decode of the
/// same stream. This isolates whether our VideoToolbox path degrades quality.
///
///   ROOTSHELL_VNC_DECODED_RTP=/tmp/vnccap/local_rtp.bin \
///   ROOTSHELL_VNC_FRAME_OUT_DIR=/tmp/vnccap/vt \
///   swift test --filter DecodedFrameDumpTests
final class DecodedFrameDumpTests: XCTestCase {

    func testDumpVideoToolboxDecodedFrames() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rtpPath = env["ROOTSHELL_VNC_DECODED_RTP"],
              let outDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: rtpPath)) else {
            throw XCTSkip("Set ROOTSHELL_VNC_DECODED_RTP and ROOTSHELL_VNC_FRAME_OUT_DIR")
        }
        try? FileManager.default.createDirectory(
            atPath: outDir, withIntermediateDirectories: true)

        // Framed: [len:UInt16 BE][rtp packet]
        var packets: [Data] = []
        var i = data.startIndex
        while i + 2 <= data.endIndex {
            let n = Int(data[i]) << 8 | Int(data[i + 1]); i += 2
            guard i + n <= data.endIndex else { break }
            packets.append(Data(data[i..<i + n])); i += n
        }
        XCTAssertGreaterThan(packets.count, 0)

        let ctx = CIContext()
        let saved = SavedCounter()
        let manager = VideoStreamManager()
        manager.startStream(streamID: 1, width: 5120, height: 720) { pixelBuffer, ssrc in
            // Save complete four-band groups spread across the capture.
            let n = saved.next()
            guard n % 200 < 4, n / 200 < 6 else { return }
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            let url = URL(fileURLWithPath: outDir)
                .appendingPathComponent("vt_\(n)_ssrc\(ssrc)_\(w)x\(h).png")
            if let cg = ctx.createCGImage(ci, from: ci.extent) {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    print("wrote \(url.lastPathComponent) fmt=\(fourCCString(fmt))")
                }
            }
        }
        defer { manager.stopStream() }

        for p in packets { _ = manager.feedRTPData(p) }
        manager.stopStream()
        Thread.sleep(forTimeInterval: 0.8)
        print("fed \(packets.count) packets, decoded \(saved.value) frames")
        XCTAssertGreaterThan(saved.value, 0)
    }

    private final class SavedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; let c = count; count += 1; return c }
    }
}
#endif
