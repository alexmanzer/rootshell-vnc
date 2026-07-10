import Foundation
import XCTest
@testable import RFBTransport

final class AppleMediaFeedbackTests: XCTestCase {
    func testFrameLossFeedbackWireLayoutMatchesAVConferenceAFBTypeSix() {
        let packet = appleMediaFrameLossPacket(
            senderSSRC: 0x1122_3344,
            mediaSSRC: 0x5566_7788,
            feedback: AppleMediaFrameLossFeedback(
                frameRTPTimestamp: 0x99aa_bbcc,
                receivedPacketCount: 0xddee,
                framePacketCount: 0xf0,
                lostPacketCount: 0x0f))

        XCTAssertEqual(packet, Data([
            0x8f, 0xce, 0x00, 0x05,
            0x11, 0x22, 0x33, 0x44,
            0x55, 0x66, 0x77, 0x88,
            0x00, 0x00, 0x00, 0x06,
            0x99, 0xaa, 0xbb, 0xcc,
            0xdd, 0xee, 0xf0, 0x0f,
        ]))
    }

    func testGenericNACKPacksContiguousAndSparseSequenceNumbers() {
        XCTAssertEqual(
            appleMediaGenericNACKEntries(missingSequences: [100, 101, 103, 117, 118]),
            [
                .init(packetID: 100, bitmask: 0x0005),
                .init(packetID: 117, bitmask: 0x0001),
            ])
    }

    func testGenericNACKPackingHandlesSequenceWraparound() {
        XCTAssertEqual(
            appleMediaGenericNACKEntries(missingSequences: [.max, 0, 2]),
            [.init(packetID: .max, bitmask: 0x0005)])
    }

    func testRCTLWireLayoutMatchesAVConferenceFields() {
        let data = AppleMediaRCTLFeedback(
            lossPercent: 7,
            echoTimestamp: 0x1234,
            measurementAgeMilliseconds: 0x5678,
            localTimestampQ10: 0x9abc,
            owrdQ13: 0xdef0,
            burstyLoss: 5,
            jitterQueueSize: 0x234,
            bandwidthEstimateKbps: 0x3456
        ).serialized()

        XCTAssertEqual(data, Data([
            0x85, 0x07, 0x00, 0x04,
            0x12, 0x34, 0x00, 0x00,
            0x00, 0x00, 0x56, 0x78,
            0x9a, 0xbc, 0xde, 0xf0,
            0x52, 0x34, 0x34, 0x56,
        ]))
    }

    func testRCTLClampsPackedQueueFields() {
        let data = AppleMediaRCTLFeedback(
            lossPercent: 0,
            echoTimestamp: 0,
            measurementAgeMilliseconds: 0,
            localTimestampQ10: 0,
            owrdQ13: 0,
            burstyLoss: .max,
            jitterQueueSize: .max,
            bandwidthEstimateKbps: .max
        ).serialized()

        XCTAssertEqual(data[16], 0xff)
        XCTAssertEqual(data[17], 0xff)
    }

    func testRCTLPacketIsStandaloneAVConferenceAPPReport() {
        let feedback = AppleMediaRCTLFeedback(
            lossPercent: 0,
            echoTimestamp: 0,
            measurementAgeMilliseconds: 50,
            localTimestampQ10: 1,
            owrdQ13: 0,
            burstyLoss: 0,
            jitterQueueSize: 0,
            bandwidthEstimateKbps: 60_000)
        let packet = appleMediaRCTLPacket(
            senderSSRC: 0x1234_5678,
            feedback: feedback)

        XCTAssertEqual(packet.count, 32)
        XCTAssertEqual(packet.prefix(12), Data([
            0x80, 0xcc, 0x00, 0x07,
            0x12, 0x34, 0x56, 0x78,
            0x52, 0x43, 0x54, 0x4c,
        ]))
        XCTAssertEqual(packet.suffix(20), feedback.serialized())
    }

    func testAppleMediaRTPTransmitTimestampIsConvertedFromQ18ToQ10() {
        // Prefix of a decrypted Screen Sharing HEVC packet captured from the
        // native server: RTP X bit, 0x9311 profile, one extension word.
        let packet = Data([
            0x90, 0x64, 0x30, 0x9f, 0, 0, 0, 0,
            0x07, 0x0d, 0xfa, 0x0e,
            0x93, 0x11, 0x00, 0x01, 0x00, 0x3c, 0x77, 0xc0,
        ])

        XCTAssertEqual(appleMediaRTPTransmitTimestampQ10(packet), 0x3c77)
    }

    func testAppleMediaRTPTransmitTimestampRejectsOtherExtensions() {
        var packet = Data(repeating: 0, count: 20)
        packet[0] = 0x90
        packet[12] = 0xbe
        packet[13] = 0xde
        packet[15] = 1
        XCTAssertNil(appleMediaRTPTransmitTimestampQ10(packet))
    }

    func testRateControllerStartsAtAvailableCeilingAndHoldsWithoutLoss() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        XCTAssertEqual(controller.bandwidthEstimateBps, 60_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 60_000_000)
        _ = controller.update(now: 0)

        for step in 0...10 {
            controller.onVideoPacket(
                ssrc: 1,
                rtpTimestamp: 0,
                bytes: 100_000,
                endOfFrame: true,
                now: Double(step) * 0.05)
        }
        _ = controller.update(now: 0.5)
        XCTAssertEqual(controller.bandwidthEstimateBps, 60_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 60_000_000)

        _ = controller.update(now: 1.1)
        XCTAssertEqual(controller.bandwidthEstimateBps, 60_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 60_000_000)
    }

    func testRateControllerCutsOnlyAfterConfirmedLoss() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)

        XCTAssertEqual(controller.bandwidthEstimateBps, 48_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 48_000_000)
        XCTAssertEqual(controller.owrdSeconds, 0)
    }

    func testSparseScreenDoesNotTurnObservedTrafficIntoCapacityCeiling() {
        let controller = AppleMediaRateController(maxTargetBps: 100_000_000)
        _ = controller.update(now: 0)
        controller.onVideoPacket(
            ssrc: 1,
            rtpTimestamp: 0,
            bytes: 1_000,
            now: 0.05)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)

        XCTAssertEqual(controller.bandwidthEstimateBps, 80_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 80_000_000)
    }
}
