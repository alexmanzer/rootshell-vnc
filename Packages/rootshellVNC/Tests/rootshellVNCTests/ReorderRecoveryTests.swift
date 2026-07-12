import XCTest
import Foundation
import CoreMedia
@testable import RFBRendering

/// Replays a real decrypted-RTP capture through the experimental interleaved
/// tile path. This is a transport/reordering regression test; public per-SSRC
/// decoders do not reproduce Apple's private reference-picture remapping.
///
///   ROOTSHELL_VNC_DECODED_RTP=/tmp/vnccap/local_rtp.bin \
///   swift test --filter ReorderRecoveryTests
final class ReorderRecoveryTests: XCTestCase {

    func testCompoundRecoveryBaseIDRDoesNotReleaseDependentsBeforeDecoderOutput() {
        let manager = VideoStreamManager()
        // The IRAP gate is opt-in (off by default because Apple's screen stream
        // never re-sends an IDR); enable it explicitly to exercise the gate.
        manager.irapGateEnabled = true
        manager.startStream(streamID: 1, width: 1920, height: 1080) { _, _ in }
        defer { manager.stopStream() }
        manager.installCompoundRecoveryGateForTesting(sources: [10, 11])
        let recoveryPTS = CMTime(value: 12_000, timescale: 90_000)

        XCTAssertTrue(manager.shouldDecodeVCL(nalType: 20, ssrc: 10))
        XCTAssertTrue(manager.hasGatedBands)
        XCTAssertFalse(manager.shouldDecodeVCL(nalType: 1, ssrc: 11))

        XCTAssertTrue(manager.armRecoveryIDRForTesting(presentationTime: recoveryPTS))
        XCTAssertTrue(manager.completeRecoveryIDROutputForTesting(
            presentationTime: recoveryPTS))
        XCTAssertFalse(manager.hasGatedBands)
        XCTAssertTrue(manager.shouldDecodeVCL(nalType: 1, ssrc: 11))
    }

    func testRecoveryOrderResetKeepsInFlightRecoveryIDRArmed() {
        let manager = VideoStreamManager()
        manager.irapGateEnabled = true
        manager.startStream(streamID: 1, width: 1920, height: 1080) { _, _ in }
        defer { manager.stopStream() }
        manager.installCompoundRecoveryGateForTesting(sources: [10, 11])
        let recoveryPTS = CMTime(value: 12_000, timescale: 90_000)

        XCTAssertTrue(manager.armRecoveryIDRForTesting(presentationTime: recoveryPTS))
        // A FIR retry resets receiver-side assembly while the previous
        // recovery IDR is still inside VideoToolbox. Its later output must
        // still clear the gate instead of burning another full FIR cycle.
        manager.resetExpectedDecodingOrderForRecovery()
        XCTAssertTrue(manager.completeRecoveryIDROutputForTesting(
            presentationTime: recoveryPTS))
        XCTAssertFalse(manager.hasGatedBands)
        XCTAssertTrue(manager.shouldDecodeVCL(nalType: 1, ssrc: 11))
    }

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

/// Classifies asynchronous VideoToolbox failures. Frame-level errors after
/// packet loss (bad data, missing reference) must NOT trigger a session
/// rebuild: this stream never sends another IDR, so a rebuilt session fails
/// every dependent picture and the display freezes in a rebuild/FIR loop.
/// The mature session keeps its other references and heals via intra refresh.
final class DecoderFailureClassificationTests: XCTestCase {

    private func makeActiveManager(
        onFailure: @escaping @Sendable (VideoDecoderFailure) -> Void
    ) -> VideoStreamManager {
        let manager = VideoStreamManager()
        manager.startStream(streamID: 1, width: 2976, height: 1860) { _, _ in }
        manager.onDecoderFailure = onFailure
        return manager
    }

    func testMissingReferenceAndBadDataAreNonFatal() {
        let fired = expectation(description: "no rebuild callback")
        fired.isInverted = true
        let manager = makeActiveManager { _ in fired.fulfill() }
        defer { manager.stopStream() }

        manager.simulateDecoderFailureForTesting(status: -12909, ssrc: 7) // bad data
        manager.simulateDecoderFailureForTesting(status: -17694, ssrc: 7) // missing ref
        for _ in 0..<128 { // sustained post-loss error burst
            manager.simulateDecoderFailureForTesting(status: -17694, ssrc: 8)
        }

        wait(for: [fired], timeout: 0.3)
        XCTAssertFalse(
            manager.hasLatchedDecoderFailure,
            "frame-level statuses must keep the session; intra refresh heals them")
    }

    func testUnknownStatusStillLatchesAndRequestsRebuild() {
        let fired = expectation(description: "rebuild callback")
        let manager = makeActiveManager { failure in
            XCTAssertEqual(failure.status, -12903)
            fired.fulfill()
        }
        defer { manager.stopStream() }

        manager.simulateDecoderFailureForTesting(status: -12903, ssrc: 7)

        wait(for: [fired], timeout: 1.0)
        XCTAssertTrue(manager.hasLatchedDecoderFailure)
    }
}
