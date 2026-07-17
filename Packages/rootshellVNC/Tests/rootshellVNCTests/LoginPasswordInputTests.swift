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
}
