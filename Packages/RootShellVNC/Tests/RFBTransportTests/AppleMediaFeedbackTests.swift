import Foundation
import XCTest
@testable import RFBTransport

final class AppleMediaFeedbackTests: XCTestCase {
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

    func testRateControllerRampsUnderSustainedUseAndHoldsOnIdle() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        XCTAssertEqual(controller.bandwidthEstimateBps, 20_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 20_000_000)
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
        XCTAssertEqual(controller.bandwidthEstimateBps, 30_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 30_000_000)

        _ = controller.update(now: 1.1)
        XCTAssertEqual(controller.bandwidthEstimateBps, 30_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 30_000_000)
    }

    func testRateControllerCutsOnlyAfterConfirmedLoss() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)

        XCTAssertEqual(controller.bandwidthEstimateBps, 16_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 16_000_000)
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

        XCTAssertEqual(controller.bandwidthEstimateBps, 16_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 16_000_000)
    }

    func testTMMBRPackingUsesSmallestValidExponent() {
        let packed = appleMediaTMMBRMxTBR(bps: 18_000_000, overhead: 40)
        let exponent = packed >> 26
        let mantissa = (packed >> 9) & 0x1ffff
        XCTAssertLessThanOrEqual(mantissa, 0x1ffff)
        XCTAssertEqual(mantissa << exponent, (18_000_000 >> exponent) << exponent)
        XCTAssertEqual(packed & 0x1ff, 40)
    }
}
