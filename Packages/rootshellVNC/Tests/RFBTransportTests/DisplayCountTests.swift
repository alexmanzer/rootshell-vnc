import XCTest
@testable import RFBTransport

final class DisplayCountTests: XCTestCase {
    func testAppleDisplayInfo2DecodesLoginWindowFlags() throws {
        var payload = Data(repeating: 0, count: 20)
        payload[0] = 0
        payload[1] = 18
        payload[2] = 0
        payload[3] = 5

        payload[19] = 0x10
        var state = try XCTUnwrap(
            appleDisplayInfo2RemoteSessionState(payload))
        XCTAssertTrue(state.loginWindowActive)
        XCTAssertFalse(state.loginWindowLockScreenActive)
        XCTAssertTrue(state.requiresLogin)

        payload[19] = 0x08
        state = try XCTUnwrap(
            appleDisplayInfo2RemoteSessionState(payload))
        XCTAssertFalse(state.loginWindowActive)
        XCTAssertTrue(state.loginWindowLockScreenActive)
        XCTAssertTrue(state.requiresLogin)

        payload[19] = 0x18
        state = try XCTUnwrap(
            appleDisplayInfo2RemoteSessionState(payload))
        XCTAssertTrue(state.loginWindowActive)
        XCTAssertTrue(state.loginWindowLockScreenActive)
    }

    func testAppleDisplayInfo2IgnoresUnavailableSessionFlags() {
        var legacy = Data(repeating: 0, count: 20)
        legacy[2] = 0
        legacy[3] = 3
        legacy[19] = 0x18
        XCTAssertNil(appleDisplayInfo2RemoteSessionState(legacy))
        XCTAssertNil(appleDisplayInfo2RemoteSessionState(
            Data(repeating: 0, count: 19)))
    }

    func testAppleDisplayInfo2DecodesUnprefixedMediaBody() throws {
        var payload = Data(repeating: 0, count: 18)
        payload[0] = 0
        payload[1] = 5
        payload[17] = 0x10

        let state = try XCTUnwrap(
            appleDisplayInfo2RemoteSessionState(payload))
        XCTAssertTrue(state.loginWindowActive)
        XCTAssertFalse(state.loginWindowLockScreenActive)
    }

    func testAppleDisplayInfo2DecodesLittleEndianScreenFlags() throws {
        var payload = Data(repeating: 0, count: 20)
        payload[0] = 0
        payload[1] = 18
        payload[2] = 0
        payload[3] = 5
        payload[16] = 0x08

        let metadata = try XCTUnwrap(
            appleDisplayInfo2SessionMetadata(payload))
        XCTAssertEqual(metadata.version, 5)
        XCTAssertEqual(metadata.screenFlagsBigEndian, 0x0800_0000)
        XCTAssertEqual(metadata.screenFlagsLittleEndian, 0x08)
        XCTAssertTrue(metadata.state.loginWindowLockScreenActive)
    }

    func testAppleDisplayInfo2DecodesCurtainFlags() throws {
        var payload = Data(repeating: 0, count: 20)
        payload[1] = 18
        payload[3] = 5

        // Curtain offered, session still drawn on the remote console.
        payload[19] = 0x02 | 0x04
        var state = try XCTUnwrap(
            appleDisplayInfo2RemoteSessionState(payload))
        XCTAssertTrue(state.curtainToggleAvailable)
        XCTAssertTrue(state.onConsole)
        XCTAssertFalse(state.curtained)

        // Curtain offered and engaged: the session has left the console.
        payload[19] = 0x02
        state = try XCTUnwrap(appleDisplayInfo2RemoteSessionState(payload))
        XCTAssertTrue(state.curtainToggleAvailable)
        XCTAssertTrue(state.curtained)

        // A server that never offers curtain still reports console state.
        payload[19] = 0x04
        state = try XCTUnwrap(appleDisplayInfo2RemoteSessionState(payload))
        XCTAssertFalse(state.curtainToggleAvailable)
        XCTAssertFalse(state.curtained)
    }

    func testAppleDisplayInfo2DecodesCurtainFlagsInLittleEndianOrder() throws {
        var payload = Data(repeating: 0, count: 20)
        payload[1] = 18
        payload[3] = 5
        payload[16] = 0x02 | 0x04

        let state = try XCTUnwrap(
            appleDisplayInfo2RemoteSessionState(payload))
        XCTAssertTrue(state.curtainToggleAvailable)
        XCTAssertTrue(state.onConsole)
    }

    func testAppleRemoteSessionStateDefaultsHideCurtain() {
        let state = AppleRemoteSessionState(
            loginWindowActive: false,
            loginWindowLockScreenActive: false)
        XCTAssertFalse(state.curtainToggleAvailable)
        XCTAssertFalse(state.curtained)
    }

    func testAppleDisplayInfo2DecodesPhysicalPixelRegions() {
        var payload = Data(repeating: 0, count: 134)
        func write(_ value: UInt16, at offset: Int) {
            payload[offset] = UInt8(value >> 8)
            payload[offset + 1] = UInt8(value & 0xff)
        }
        func write32(_ value: UInt32, at offset: Int) {
            payload[offset] = UInt8(value >> 24)
            payload[offset + 1] = UInt8((value >> 16) & 0xff)
            payload[offset + 2] = UInt8((value >> 8) & 0xff)
            payload[offset + 3] = UInt8(value & 0xff)
        }
        write(132, at: 0)
        write(2, at: 20)

        write32(0x1234_0003, at: 38)
        write(0, at: 50)
        write(0, at: 52)
        write(2_880, at: 54)
        write(5_120, at: 56)

        write32(0x5678_0001, at: 94)
        write(2_880, at: 106)
        write(1_125, at: 108)
        write(4_844, at: 110)
        write(4_149, at: 112)

        let displays = appleDisplayInfo2Records(payload)
        XCTAssertEqual(displays.count, 2)
        XCTAssertEqual(displays[0].displayIndex, 0x1234_0003)
        XCTAssertEqual(displays[0].originX, 0)
        XCTAssertEqual(displays[0].originY, 0)
        XCTAssertEqual(displays[0].width, 5_120)
        XCTAssertEqual(displays[0].height, 2_880)
        XCTAssertEqual(displays[1].displayIndex, 0x5678_0001)
        XCTAssertEqual(displays[1].originX, 1_125)
        XCTAssertEqual(displays[1].originY, 2_880)
        XCTAssertEqual(displays[1].width, 3_024)
        XCTAssertEqual(displays[1].height, 1_964)
    }

    func testAdaptiveMediaDisplaySelectionDefaultsToOneReceiver() {
        XCTAssertEqual(
            selectedAppleMediaDisplayCount(offered: 2, requested: 1),
            1)
    }

    func testAdaptiveMediaDisplaySelectionAcceptsTwoWhenSelectedAndOffered() {
        XCTAssertEqual(
            selectedAppleMediaDisplayCount(offered: 2, requested: 2),
            2)
        XCTAssertEqual(
            selectedAppleMediaDisplayCount(offered: 1, requested: 2),
            1)
    }

}
