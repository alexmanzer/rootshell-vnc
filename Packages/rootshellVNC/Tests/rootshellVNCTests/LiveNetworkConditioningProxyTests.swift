import XCTest

final class LiveNetworkConditioningProxyTests: XCTestCase {
    func testPropagationDelayDoesNotAccumulatePerPacket() {
        let conditions = makeConditions(oneWayDelayMilliseconds: 40)
        var scheduler = LiveImpairmentScheduler(seed: conditions.seed)

        let first = scheduler.schedule(nowNanos: 1_000_000, conditions: conditions)
        let second = scheduler.schedule(nowNanos: 2_000_000, conditions: conditions)

        XCTAssertEqual(first.readyNanos, 41_000_000)
        XCTAssertEqual(second.readyNanos, 42_000_000)
        XCTAssertFalse(first.simulatedLoss)
        XCTAssertFalse(second.simulatedLoss)
    }

    func testLossCreatesTCPHeadOfLineRecoveryFence() {
        var conditions = makeConditions(
            oneWayDelayMilliseconds: 40,
            lossPercent: 100,
            lossRecoveryMilliseconds: 200)
        var scheduler = LiveImpairmentScheduler(seed: conditions.seed)

        let lost = scheduler.schedule(nowNanos: 0, conditions: conditions)
        conditions.lossPercent = 0
        let following = scheduler.schedule(
            nowNanos: 10_000_000,
            conditions: conditions)

        XCTAssertTrue(lost.simulatedLoss)
        XCTAssertEqual(lost.readyNanos, 240_000_000)
        XCTAssertEqual(following.readyNanos, lost.readyNanos)
    }

    func testJitterSequenceIsSeededAndBounded() {
        let conditions = makeConditions(
            oneWayDelayMilliseconds: 30,
            jitterMilliseconds: 10)
        var first = LiveImpairmentScheduler(seed: 7)
        var second = LiveImpairmentScheduler(seed: 7)

        let firstSequence = (0..<20).map { index in
            first.schedule(
                nowNanos: UInt64(index) * 100_000_000,
                conditions: conditions)
        }
        let secondSequence = (0..<20).map { index in
            second.schedule(
                nowNanos: UInt64(index) * 100_000_000,
                conditions: conditions)
        }

        XCTAssertEqual(firstSequence, secondSequence)
        for (index, packet) in firstSequence.enumerated() {
            let delay = packet.readyNanos - UInt64(index) * 100_000_000
            XCTAssertGreaterThanOrEqual(delay, 20_000_000)
            XCTAssertLessThanOrEqual(delay, 40_000_000)
        }
    }

    func testUnconfiguredConditionsDoNotStartAProxy() {
        XCTAssertFalse(makeConditions().isImpaired)
        XCTAssertTrue(makeConditions(lossPercent: 0.1).isImpaired)
        XCTAssertTrue(makeConditions(oneWayDelayMilliseconds: 1).isImpaired)
    }

    private func makeConditions(
        oneWayDelayMilliseconds: Int = 0,
        jitterMilliseconds: Int = 0,
        lossPercent: Double = 0,
        lossRecoveryMilliseconds: Int = 200
    ) -> LiveNetworkConditions {
        LiveNetworkConditions(
            downstreamBytesPerSecond: nil,
            upstreamBytesPerSecond: nil,
            oneWayDelayMilliseconds: oneWayDelayMilliseconds,
            jitterMilliseconds: jitterMilliseconds,
            lossPercent: lossPercent,
            lossRecoveryMilliseconds: lossRecoveryMilliseconds,
            seed: 42)
    }
}
