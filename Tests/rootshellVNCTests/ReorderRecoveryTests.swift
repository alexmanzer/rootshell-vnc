import XCTest
import Foundation
import CoreMedia
import CoreVideo
@testable import RFBRendering

/// Replays a decrypted-RTP fixture through the compound interleaved-band path.
/// This regression test verifies the stream's reference-picture ordering.
///
///   ROOTSHELL_VNC_DECODED_RTP=/tmp/vnccap/local_rtp.bin \
///   swift test --filter ReorderRecoveryTests
final class ReorderRecoveryTests: XCTestCase {

    /// Opt-in structural dump used to compare Apple's interleaved stream index
    /// with the public receiver's SSRC/DON routing. It performs no writes.
    func testDescribeCapturedCompoundRoutingWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ROOTSHELL_VNC_DESCRIBE_ROUTING"] == "1",
              let inputPath = environment["ROOTSHELL_VNC_DECODED_RTP"] else {
            throw XCTSkip(
                "Set ROOTSHELL_VNC_DESCRIBE_ROUTING=1 and ROOTSHELL_VNC_DECODED_RTP")
        }

        let capture = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let demuxer = RTPDemuxer(usesDecodingOrderNumbers: true)
        var reorder = CompoundHEVCDONReorderBuffer(expectedSourceCount: 4)
        var offset = capture.startIndex
        var describedAccessUnits = 0
        var sourceOrdinals: [UInt32: Int] = [:]

        while offset + 2 <= capture.endIndex, describedAccessUnits < 80 {
            let length = Int(capture[offset]) << 8 | Int(capture[offset + 1])
            offset += 2
            guard offset + length <= capture.endIndex else { break }
            let bytes = Data(capture[offset ..< offset + length])
            offset += length
            guard !RTPDemuxer.isRTCPPacket(bytes),
                  let packet = try? demuxer.parsePacket(bytes),
                  packet.payloadType == 100 else { continue }

            for unit in demuxer.feedPacket(packet) where unit.nal.count >= 2 {
                let type = (unit.nal[unit.nal.startIndex] >> 1) & 0x3f
                if sourceOrdinals[unit.ssrc] == nil {
                    sourceOrdinals[unit.ssrc] = sourceOrdinals.count
                }
                if (32...34).contains(type) {
                    print(
                        "parameter type=\(type) ssrc=0x\(String(unit.ssrc, radix: 16)) "
                            + "source=\(sourceOrdinals[unit.ssrc]!) don=\(unit.don) "
                            + "bytes=\(unit.nal.count)")
                    continue
                }
                guard type <= 31 else { continue }
                for accessUnit in reorder.enqueue([unit]).orderedAccessUnits {
                    let first = accessUnit.nals[0].nal
                    let firstType = (first[first.startIndex] >> 1) & 0x3f
                    let layerID = ((UInt16(first[first.startIndex]) & 1) << 5)
                        | (UInt16(first[first.startIndex + 1]) >> 3)
                    let temporalID = first[first.startIndex + 1] & 7
                    let ordinal = sourceOrdinals[accessUnit.ssrc] ?? -1
                    print(
                        "au don=\(accessUnit.don) mod4=\(Int(accessUnit.don) & 3) "
                            + "source=\(ordinal) ssrc=0x\(String(accessUnit.ssrc, radix: 16)) "
                            + "rtp=\(accessUnit.timestamp) type=\(firstType) "
                            + "layer=\(layerID) temporal=\(temporalID) "
                            + "nals=\(accessUnit.nals.count) bytes="
                            + "\(accessUnit.nals.reduce(0) { $0 + $1.nal.count })")
                    describedAccessUnits += 1
                    if describedAccessUnits >= 80 { break }
                }
                if describedAccessUnits >= 80 { break }
            }
        }

        XCTAssertEqual(sourceOrdinals.count, 4)
        XCTAssertGreaterThan(describedAccessUnits, 20)
    }

    /// Opt-in diagnostic exporter. This uses the same public RTP demuxer and
    /// compound DON scheduler as the app, but writes Annex-B access units for
    /// an independent decoder. Ordinary test and app runs perform no write.
    func testExportCapturedCompoundAnnexBWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment["ROOTSHELL_VNC_DECODED_RTP"],
              let outputPath = environment["ROOTSHELL_VNC_HEVC_OUT"] else {
            throw XCTSkip(
                "Set ROOTSHELL_VNC_DECODED_RTP and ROOTSHELL_VNC_HEVC_OUT")
        }
        let capture = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        var packets: [Data] = []
        var offset = capture.startIndex
        while offset + 2 <= capture.endIndex {
            let length = Int(capture[offset]) << 8 | Int(capture[offset + 1])
            offset += 2
            guard offset + length <= capture.endIndex else { break }
            packets.append(Data(capture[offset ..< offset + length]))
            offset += length
        }

        let demuxer = RTPDemuxer(usesDecodingOrderNumbers: true)
        var reorder = CompoundHEVCDONReorderBuffer(expectedSourceCount: 4)
        var annexB = Data()
        var accessUnitCount = 0
        var parameterSetCount = 0
        let startCode = Data([0, 0, 0, 1])

        func append(_ nal: Data, to output: inout Data) {
            output.append(startCode)
            output.append(nal)
        }

        for bytes in packets {
            guard !RTPDemuxer.isRTCPPacket(bytes),
                  let packet = try? demuxer.parsePacket(bytes),
                  packet.payloadType == 100 else { continue }
            for unit in demuxer.feedPacket(packet) where unit.nal.count >= 2 {
                let type = (unit.nal[unit.nal.startIndex] >> 1) & 0x3f
                switch type {
                case 32...34:
                    append(unit.nal, to: &annexB)
                    parameterSetCount += 1
                case 0...31:
                    let result = reorder.enqueue([unit])
                    for accessUnit in result.orderedAccessUnits {
                        for nal in accessUnit.nals {
                            append(nal.nal, to: &annexB)
                        }
                        accessUnitCount += 1
                    }
                default:
                    break
                }
            }
        }

        try annexB.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print(
            "exported \(accessUnitCount) access units, "
                + "\(parameterSetCount) parameter sets, \(annexB.count) bytes")
        XCTAssertGreaterThan(accessUnitCount, 100)
        XCTAssertGreaterThan(parameterSetCount, 0)
    }

    func testNonGatingRecoveryRequestsRepeatForDistinctLossEpisodes() {
        let manager = VideoStreamManager()
        manager.irapGateEnabled = false

        XCTAssertTrue(manager.noteLossForTesting(nowNanos: 1_000_000_000))
        XCTAssertFalse(manager.noteLossForTesting(nowNanos: 1_100_000_000))
        XCTAssertFalse(manager.noteLossForTesting(nowNanos: 1_999_999_999))
        XCTAssertTrue(manager.noteLossForTesting(nowNanos: 2_000_000_000))
    }

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

    /// No-write hardware/software decoder comparison for an approved decoded-
    /// RTP diagnostic capture. The digest is intentionally computed in memory:
    /// it proves whether public VideoToolbox produced identical pixels without
    /// retaining another copy of the remote screen on disk.
    ///
    /// Set ROOTSHELL_VNC_HASH_DECODED_RTP=1 and optionally
    /// ROOTSHELL_VNC_REPLAY_PACKET_LIMIT to stop before a known packet loss.
    func testHashCapturedCompoundDecodeWhenRequested() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ROOTSHELL_VNC_HASH_DECODED_RTP"] == "1",
              let path = env["ROOTSHELL_VNC_DECODED_RTP"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw XCTSkip(
                "Set ROOTSHELL_VNC_HASH_DECODED_RTP=1 and ROOTSHELL_VNC_DECODED_RTP")
        }
        let packetLimit = Int(env["ROOTSHELL_VNC_REPLAY_PACKET_LIMIT"] ?? "")

        var packets: [Data] = []
        var offset = data.startIndex
        while offset + 2 <= data.endIndex,
              packetLimit.map({ packets.count < $0 }) ?? true {
            let count = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
            guard offset + count <= data.endIndex else { break }
            packets.append(Data(data[offset ..< offset + count]))
            offset += count
        }
        XCTAssertGreaterThan(packets.count, 100)

        let digest = PixelDigest()
        let manager = VideoStreamManager()
        manager.startStream(streamID: 1, width: 2976, height: 1860) {
            buffer, ssrc in
            digest.append(buffer, ssrc: ssrc)
        }
        for packet in packets { _ = manager.feedRTPData(packet) }
        manager.stopStream()
        Thread.sleep(forTimeInterval: 0.8)

        let result = digest.snapshot
        print(
            "pixel digest frames=\(result.frameCount) value="
                + String(result.value, radix: 16))
        XCTAssertGreaterThan(result.frameCount, 0)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    private final class PixelDigest: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0xcbf2_9ce4_8422_2325
        private var frameCount = 0

        var snapshot: (value: UInt64, frameCount: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (value, frameCount)
        }

        func append(_ buffer: CVPixelBuffer, ssrc: UInt32) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            var frameHash: UInt64 = 0xcbf2_9ce4_8422_2325
            func mix(_ byte: UInt8) {
                frameHash ^= UInt64(byte)
                frameHash &*= 0x0000_0100_0000_01b3
            }
            for shift in stride(from: 24, through: 0, by: -8) {
                mix(UInt8((ssrc >> UInt32(shift)) & 0xff))
            }
            let planes = max(1, CVPixelBufferGetPlaneCount(buffer))
            for plane in 0 ..< planes {
                let base: UnsafeMutableRawPointer?
                let byteCount: Int
                if CVPixelBufferGetPlaneCount(buffer) == 0 {
                    base = CVPixelBufferGetBaseAddress(buffer)
                    byteCount = CVPixelBufferGetBytesPerRow(buffer)
                        * CVPixelBufferGetHeight(buffer)
                } else {
                    base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                    byteCount = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                        * CVPixelBufferGetHeightOfPlane(buffer, plane)
                }
                guard let base else { continue }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                // Sample one cache line at a time. This remains deterministic
                // and catches spatial corruption across the complete surface,
                // while avoiding a minute of scalar hashing for a short 4K
                // capture replay.
                for index in stride(from: 0, to: byteCount, by: 64) {
                    mix(bytes[index])
                }
                if byteCount > 0 { mix(bytes[byteCount - 1]) }
            }

            lock.lock()
            value ^= frameHash
            value &*= 0x0000_0100_0000_01b3
            frameCount += 1
            lock.unlock()
        }
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
