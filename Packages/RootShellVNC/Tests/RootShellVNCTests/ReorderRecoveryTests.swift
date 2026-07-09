import XCTest
import Foundation
@testable import RFBRendering

/// Proves the DON reorder buffer recovers decode under frame reordering.
///
/// Apple round-robins one HEVC reference chain across SSRCs; over Wi-Fi frames
/// arrive out of order. Feeding the decoder in arrival order corrupts the
/// reference chain (few frames survive); reordering by DON restores it. This
/// replays a real decrypted-RTP capture, reorders whole frames (without
/// splitting fragmentation units), and compares decoded frame counts with the
/// reorder buffer OFF vs ON.
///
///   ROOTSHELL_VNC_DECODED_RTP=/tmp/vnccap/local_rtp.bin \
///   swift test --filter ReorderRecoveryTests
final class ReorderRecoveryTests: XCTestCase {

    func testDONReorderRecoversFramesUnderJitter() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ROOTSHELL_VNC_DECODED_RTP"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw XCTSkip("Set ROOTSHELL_VNC_DECODED_RTP to a decoded-RTP capture")
        }

        // Framed: [len:UInt16 BE][rtp packet]
        var packets: [Data] = []
        var i = data.startIndex
        while i + 2 <= data.endIndex {
            let n = Int(data[i]) << 8 | Int(data[i + 1]); i += 2
            guard i + n <= data.endIndex else { break }
            packets.append(Data(data[i..<i + n])); i += n
        }
        XCTAssertGreaterThan(packets.count, 100)

        // Group packets into frames by DON boundary (a run of equal DON is one
        // frame's fragments), then swap adjacent frame-groups to simulate
        // cross-frame reordering WITHOUT splitting any FU (which would just be
        // lost at reassembly and confound the comparison).
        let reordered = reorderWholeFrames(packets)

        let inOrder = decodeCount(reordered, reorder: true)   // DON reorder ON
        let arrival = decodeCount(reordered, reorder: false)  // arrival order

        print("reordered stream: reorder ON decoded=\(inOrder), OFF decoded=\(arrival)")
        // With the reference chain scrambled, arrival-order decode loses most
        // frames; DON reorder should recover the large majority.
        XCTAssertGreaterThan(inOrder, arrival * 2,
            "DON reorder should decode far more frames than arrival order under jitter")
    }

    private func decodeCount(_ packets: [Data], reorder: Bool) -> Int {
        let counter = Counter()
        let manager = VideoStreamManager()
        manager.reorderEnabled = reorder
        manager.startStream(streamID: 1, width: 5120, height: 720) { _, _ in
            counter.increment()
        }
        for p in packets { _ = manager.feedRTPData(p) }
        manager.stopStream()
        Thread.sleep(forTimeInterval: 0.6)
        return counter.value
    }

    /// Parse the DON from a decoded (plaintext) RTP video packet, or nil.
    private func don(of packet: Data) -> UInt16? {
        guard packet.count >= 12 else { return nil }
        let b0 = packet[packet.startIndex]
        let cc = Int(b0 & 0x0f)
        let ext = (b0 >> 4) & 1
        var off = 12 + cc * 4
        if ext == 1 {
            guard packet.count >= off + 4 else { return nil }
            let extLen = Int(packet[packet.startIndex + off + 2]) << 8 | Int(packet[packet.startIndex + off + 3])
            off += 4 + extLen * 4
        }
        let pt = packet[packet.startIndex + 1] & 0x7f
        guard pt == 100, packet.count >= off + 5 else { return nil }
        let pl = packet.startIndex + off
        let ntype = (packet[pl] >> 1) & 0x3f
        // DONL sits after the 2-byte header for AP/single-NAL, after the FU
        // header (1 extra byte) for FU.
        let donOff = ntype == 49 ? pl + 3 : pl + 2
        guard packet.count >= donOff + 2 else { return nil }
        return UInt16(packet[donOff]) << 8 | UInt16(packet[donOff + 1])
    }

    private func reorderWholeFrames(_ packets: [Data]) -> [Data] {
        // Build frame-groups: contiguous runs of equal DON.
        var groups: [[Data]] = []
        var current: [Data] = []
        var currentDON: UInt16?
        for p in packets {
            let d = don(of: p)
            if d != currentDON, !current.isEmpty {
                groups.append(current); current = []
            }
            currentDON = d
            current.append(p)
        }
        if !current.isEmpty { groups.append(current) }

        // Swap each adjacent pair of groups (deterministic reorder depth 1).
        var g = groups
        var idx = 0
        while idx + 1 < g.count {
            g.swapAt(idx, idx + 1)
            idx += 2
        }
        return g.flatMap { $0 }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
