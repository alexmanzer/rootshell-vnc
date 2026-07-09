import XCTest
import Foundation
@testable import RFBRendering

/// Replays a real decrypted-RTP capture and verifies that the interleaved band
/// SSRCs produce output through the single compound decoder timeline.
///
///   ROOTSHELL_VNC_DECODED_RTP=/tmp/vnccap/local_rtp.bin \
///   swift test --filter ReorderRecoveryTests
final class ReorderRecoveryTests: XCTestCase {

    func testCapturedCompoundStreamDecodes() throws {
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

        let counter = Counter()
        let manager = VideoStreamManager()
        manager.startStream(streamID: 1, width: 5120, height: 720) { _, _ in
            counter.increment()
        }
        for packet in packets { _ = manager.feedRTPData(packet) }
        manager.stopStream()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(counter.value, 0)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
