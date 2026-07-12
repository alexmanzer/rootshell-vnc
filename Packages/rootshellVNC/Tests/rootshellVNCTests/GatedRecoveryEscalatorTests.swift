import XCTest
@testable import rootshellVNC

/// The escalator is pure timing policy: seconds are expressed directly in
/// nanoseconds so each test reads as a wall-clock schedule.
final class GatedRecoveryEscalatorTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    private func makeEscalator() -> GatedRecoveryEscalator {
        GatedRecoveryEscalator()
    }

    func testUngatedTicksProduceNoAction() {
        var escalator = makeEscalator()
        XCTAssertEqual(
            escalator.observe(gated: false, readyForKeyframe: true, nowNanos: second),
            .none)
        XCTAssertEqual(
            escalator.observe(gated: false, readyForKeyframe: false, nowNanos: 10 * second),
            .none)
    }

    func testGraceWindowSuppressesFIRWhileRetransmissionWorks() {
        var escalator = makeEscalator()
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 0),
            .none)
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: true, nowNanos: second),
            .none)
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 2 * second),
            .requestFIR)
    }

    func testUnsettledControllerIsBoundedByAbsoluteFirstFIRDeadline() {
        var escalator = makeEscalator()
        _ = escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 0)
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 3 * second),
            .none)
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 4 * second),
            .requestFIR)
    }

    func testUncommittedActionIsReofferedUntilNoted() {
        var escalator = makeEscalator()
        _ = escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 0)
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 2 * second),
            .requestFIR)
        // The recovery coordinator was busy: nothing was committed, so the
        // same action must be offered again on the next tick.
        XCTAssertEqual(
            escalator.observe(
                gated: true,
                readyForKeyframe: true,
                nowNanos: 2 * second + 250_000_000),
            .requestFIR)
        escalator.noteFIRRequested(nowNanos: 2 * second + 250_000_000)
        XCTAssertEqual(
            escalator.observe(
                gated: true,
                readyForKeyframe: true,
                nowNanos: 2 * second + 500_000_000),
            .none)
    }

    func testRetriesEscalateWithBitrateBackoffAndIgnoreReadiness() {
        var escalator = makeEscalator()
        _ = escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 0)
        _ = escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 2 * second)
        escalator.noteFIRRequested(nowNanos: 2 * second)

        // First retry after 1.5 s, and it must not wait for readiness.
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 3 * second),
            .none)
        XCTAssertEqual(
            escalator.observe(
                gated: true,
                readyForKeyframe: false,
                nowNanos: 3 * second + 500_000_000),
            .backoffThenFIR)
        escalator.noteFIRRequested(nowNanos: 3 * second + 500_000_000)

        // Second retry widens to 2 s.
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 5 * second),
            .none)
        XCTAssertEqual(
            escalator.observe(
                gated: true,
                readyForKeyframe: false,
                nowNanos: 5 * second + 500_000_000),
            .backoffThenFIR)
    }

    func testGateAgeEscalatesToDecoderRebuildAndReentersLadder() {
        var escalator = makeEscalator()
        _ = escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 0)
        _ = escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 4 * second)
        escalator.noteFIRRequested(nowNanos: 4 * second)

        // Past the 12 s gate-age bound, the next due retry becomes a rebuild.
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 13 * second),
            .rebuildDecoderAndFIR)
        escalator.noteDecoderRebuilt(nowNanos: 13 * second)
        escalator.noteFIRRequested(nowNanos: 13 * second)

        // Rebuild is cooldown-limited: the ladder resumes with plain retries.
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 15 * second),
            .backoffThenFIR)
        escalator.noteFIRRequested(nowNanos: 15 * second)

        // After the 10 s cooldown a still-latched gate may rebuild again.
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: false, nowNanos: 24 * second),
            .rebuildDecoderAndFIR)
    }

    func testFiveFailedAttemptsEscalateToRebuildBeforeGateAgeBound() {
        // Widen the age bound so only the attempt threshold can trigger.
        var escalator = GatedRecoveryEscalator(rebuildGateAgeNanos: 1_000 * second)
        _ = escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 0)
        var now = 2 * second
        for _ in 1...5 {
            let action = escalator.observe(gated: true, readyForKeyframe: true, nowNanos: now)
            XCTAssertNotEqual(action, .none)
            XCTAssertNotEqual(action, .rebuildDecoderAndFIR)
            escalator.noteFIRRequested(nowNanos: now)
            now += 3 * second
        }
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: true, nowNanos: now),
            .rebuildDecoderAndFIR)
    }

    func testGateClearingResetsTheLadderForTheNextDragBurst() {
        var escalator = makeEscalator()
        _ = escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 0)
        _ = escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 2 * second)
        escalator.noteFIRRequested(nowNanos: 2 * second)

        // Gate clears, then re-latches one tick later (continued rapid drag).
        XCTAssertEqual(
            escalator.observe(gated: false, readyForKeyframe: true, nowNanos: 3 * second),
            .none)
        XCTAssertEqual(
            escalator.observe(gated: true, readyForKeyframe: true, nowNanos: 3 * second + 250_000_000),
            .none)
        // A fresh episode gets its own full grace window and first-FIR path.
        XCTAssertEqual(
            escalator.observe(
                gated: true,
                readyForKeyframe: true,
                nowNanos: 5 * second + 250_000_000),
            .requestFIR)
        XCTAssertEqual(escalator.firAttempts, 0)
    }
}
