import XCTest
@testable import RFBTransport

final class AppleClipboardProtocolTests: XCTestCase {
    func testRemoteClipboardRequestWireFormat() {
        XCTAssertEqual(
            AppleClipboardProtocol.requestMessage(requestID: 0x0102_0304),
            Data([11, 0, 0, 0, 1, 2, 3, 4]))
    }

    func testAutomaticPasteboardWireFormat() {
        XCTAssertEqual(
            AppleClipboardProtocol.autoPasteboardMessage(enabled: true),
            Data([21, 0, 0, 1, 0, 0, 0, 0]))
        XCTAssertEqual(
            AppleClipboardProtocol.autoPasteboardMessage(enabled: false),
            Data([21, 0, 0, 2, 0, 0, 0, 0]))
    }

    func testUnpacksUTF8TextFlavor() throws {
        // A complete zlib stream containing one Apple packed-scrap item with
        // one public.utf8-plain-text flavor whose contents are "hello".
        let compressed = Data([
            120, 156, 99, 96, 96, 96, 100, 96, 96, 16, 43, 40, 77, 202,
            201, 76, 214, 43, 45, 73, 179, 208, 45, 200, 73, 204, 204,
            211, 45, 73, 173, 40, 97, 64, 0, 214, 140, 212, 156, 156, 124,
            0, 249, 124, 10, 152,
        ])

        XCTAssertEqual(
            try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: 47),
            "hello")
    }
}
