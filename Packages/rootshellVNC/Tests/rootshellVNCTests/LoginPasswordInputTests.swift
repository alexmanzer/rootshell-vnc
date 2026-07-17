import XCTest
@testable import rootshellVNC

final class LoginPasswordInputTests: XCTestCase {
    func testSequenceClearsModifiersAndPacesKeyTaps() {
        let events = VNCSession.loginPasswordInputEvents(password: "Aé")

        XCTAssertEqual(Array(events.prefix(9)), [
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymCapsLock),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymShiftL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymSuperL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymAltL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymControlL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymControlR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymSuperR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymAltR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymShiftR),
        ])
        XCTAssertEqual(Array(events.dropFirst(9)), [
            .key(downFlag: true, keysym: 0x41),
            .key(downFlag: false, keysym: 0x41),
            .pause(nanoseconds: 5_000_000),
            .key(downFlag: true, keysym: 0xE9),
            .key(downFlag: false, keysym: 0xE9),
            .pause(nanoseconds: 5_000_000),
            .key(downFlag: true, keysym: KeyboardInputHandler.keysymReturn),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymReturn),
            .pause(nanoseconds: 5_000_000),
        ])
    }

    func testPasswordFocusClickPrecedesTypingBarrier() {
        XCTAssertEqual(
            VNCSession.loginPasswordFocusInputEvents(x: 800, y: 600),
            [
                .pointer(buttonMask: 0, x: 800, y: 600),
                .pointer(buttonMask: 1, x: 800, y: 600),
                .pointer(buttonMask: 0, x: 800, y: 600),
                .pause(nanoseconds: 150_000_000),
            ])
    }

    func testStabilityGatePreservesSendAcrossDisplayChanges() {
        var gate = LoginPasswordSendStabilityGate()

        XCTAssertNil(gate.requestSend())
        gate.transportSettled(true)
        let retired = gate.noteEligibleFrame(mediaGeneration: 4)
        XCTAssertNotNil(retired)

        gate.displayTargetChanged()
        XCTAssertFalse(gate.consume(retired!))
        XCTAssertTrue(gate.isPending)

        gate.transportSettled(true)
        let replacement = gate.noteEligibleFrame(mediaGeneration: 5)
        XCTAssertNotNil(replacement)
        XCTAssertTrue(gate.consume(replacement!))
        XCTAssertFalse(gate.isPending)
    }

    func testStabilityGateCanUseAnAlreadyCommittedFrame() {
        var gate = LoginPasswordSendStabilityGate()

        gate.transportSettled(true)
        XCTAssertNil(gate.noteEligibleFrame(mediaGeneration: 7))
        let token = gate.requestSend()

        XCTAssertNotNil(token)
        XCTAssertTrue(gate.consume(token!))
    }

    func testStabilityGateRejectsRetiredMediaGeneration() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()
        gate.transportSettled(true)
        let retired = gate.noteEligibleFrame(mediaGeneration: 10)!
        let current = gate.noteEligibleFrame(mediaGeneration: 11)!

        XCTAssertFalse(gate.consume(retired))
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.consume(current))
    }

    func testStabilityGateRequiresFrameAfterTransportSettles() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()

        XCTAssertNil(gate.noteEligibleFrame(mediaGeneration: 20))
        gate.transportSettled(true)
        XCTAssertTrue(gate.isPending)
        XCTAssertNil(gate.stableCandidate)

        let finalFrame = gate.noteEligibleFrame(mediaGeneration: 21)
        XCTAssertNotNil(finalFrame)
        XCTAssertTrue(gate.consume(finalFrame!))
    }

    func testTransportReconfigurationInvalidatesScheduledFrame() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()
        gate.transportSettled(true)
        let beforeQueuedResize = gate.noteEligibleFrame(mediaGeneration: 30)!

        gate.transportSettled(false)

        XCTAssertFalse(gate.consume(beforeQueuedResize))
        XCTAssertTrue(gate.isPending)
        XCTAssertNil(gate.stableCandidate)
    }
}
