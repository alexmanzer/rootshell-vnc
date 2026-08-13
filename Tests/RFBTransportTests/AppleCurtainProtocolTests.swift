import XCTest
@testable import RFBTransport

final class AppleCurtainProtocolTests: XCTestCase {
    func testCurtainOnCarriesMessageAndClearsVisibleFlag() {
        let message = AppleCurtainProtocol.sessionVisibilityMessage(
            visible: false,
            message: "Hi")

        XCTAssertEqual(
            message,
            Data([12, 0, 0, 0, 0, 2]) + Data("Hi".utf8))
    }

    func testCurtainOffSetsVisibleFlagAndSendsNoText() {
        let message = AppleCurtainProtocol.sessionVisibilityMessage(
            visible: true,
            message: "")

        XCTAssertEqual(message, Data([12, 0, 0, 1, 0, 0]))
    }

    func testMessageLengthIsBigEndian() {
        let text = String(repeating: "a", count: 300)
        let message = AppleCurtainProtocol.sessionVisibilityMessage(
            visible: false,
            message: text)

        XCTAssertEqual(message[4], 0x01)
        XCTAssertEqual(message[5], 0x2c)
        XCTAssertEqual(message.count, 6 + 300)
    }

    func testMultiByteTextIsMeasuredInBytesNotCharacters() {
        let message = AppleCurtainProtocol.sessionVisibilityMessage(
            visible: false,
            message: "é")

        XCTAssertEqual(message[4], 0)
        XCTAssertEqual(message[5], 2)
        XCTAssertEqual(message.count, 8)
    }

    func testOverlongMessageIsClampedToServerLimit() {
        let text = String(repeating: "a", count: 600)
        let message = AppleCurtainProtocol.sessionVisibilityMessage(
            visible: false,
            message: text)

        XCTAssertEqual(
            message.count,
            6 + AppleCurtainProtocol.maximumMessageByteCount)
        XCTAssertEqual(message[4], 0x02)
        XCTAssertEqual(message[5], 0x00)
    }

    func testClampingNeverSplitsAGrapheme() throws {
        // Three bytes per character, so the 512-byte limit lands mid-character
        // and a naive byte cut would emit a replacement character.
        let text = String(repeating: "あ", count: 200)
        let clamped = AppleCurtainProtocol.clampedMessageBytes(text)

        XCTAssertEqual(clamped.count, 510)
        let decoded = try XCTUnwrap(String(data: clamped, encoding: .utf8))
        XCTAssertEqual(decoded.count, 170)
        XCTAssertFalse(decoded.contains("\u{FFFD}"))
    }

    func testClampingKeepsWholeEmojiClusters() throws {
        let text = String(repeating: "🇺🇸", count: 100)
        let clamped = AppleCurtainProtocol.clampedMessageBytes(text)

        // Each flag is one Character of eight UTF-8 bytes: 64 fit exactly.
        XCTAssertEqual(clamped.count, 512)
        let decoded = try XCTUnwrap(String(data: clamped, encoding: .utf8))
        XCTAssertEqual(decoded.count, 64)
    }

    func testShortMessageIsNotClamped() {
        let clamped = AppleCurtainProtocol.clampedMessageBytes("hello")
        XCTAssertEqual(clamped, Data("hello".utf8))
    }
}
