import XCTest
@testable import RFBTransport

final class DisplayCountTests: XCTestCase {
    func testAppleDisplayInfo2DecodesPhysicalPixelRegions() {
        var payload = Data(repeating: 0, count: 134)
        func write(_ value: UInt16, at offset: Int) {
            payload[offset] = UInt8(value >> 8)
            payload[offset + 1] = UInt8(value & 0xff)
        }
        write(132, at: 0)
        write(2, at: 20)

        write(3, at: 40)
        write(0, at: 50)
        write(0, at: 52)
        write(2_880, at: 54)
        write(5_120, at: 56)

        write(1, at: 96)
        write(2_880, at: 106)
        write(1_125, at: 108)
        write(4_844, at: 110)
        write(4_149, at: 112)

        let displays = appleDisplayInfo2Records(payload)
        XCTAssertEqual(displays.count, 2)
        XCTAssertEqual(displays[0].displayIndex, 3)
        XCTAssertEqual(displays[0].originX, 0)
        XCTAssertEqual(displays[0].originY, 0)
        XCTAssertEqual(displays[0].width, 5_120)
        XCTAssertEqual(displays[0].height, 2_880)
        XCTAssertEqual(displays[1].displayIndex, 1)
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
