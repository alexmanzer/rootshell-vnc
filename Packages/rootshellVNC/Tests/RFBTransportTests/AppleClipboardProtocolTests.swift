import XCTest
import RFBProtocol
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

    func testPackedTextMessageHeaderAndRoundTrip() throws {
        let text = "hello, 🌎"
        let message = try AppleClipboardProtocol.packedTextMessage(text)

        XCTAssertEqual(message[0], AppleClipboardProtocol.packedScrapMessageType)
        XCTAssertEqual(message[2], 0, "Full clipboard data is not a promise")
        XCTAssertEqual(message.count, AppleClipboardProtocol.packedScrapHeaderSize
            + Int(AppleClipboardProtocol.uint32BE(message, at: 12)!))

        let uncompressedSize = Int(
            AppleClipboardProtocol.uint32BE(message, at: 8)!)
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))
        XCTAssertEqual(
            try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: uncompressedSize),
            text)
    }

    func testPackedTextMessageRoundTripsEmptyText() throws {
        let message = try AppleClipboardProtocol.packedTextMessage("")
        let uncompressedSize = Int(
            AppleClipboardProtocol.uint32BE(message, at: 8)!)
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))

        XCTAssertEqual(
            try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: uncompressedSize),
            "")
    }

    func testPackedTextMessageUsesNativeSyncFlushBoundary() throws {
        let message = try AppleClipboardProtocol.packedTextMessage("abcdef")
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))

        // Apple's CopyPackedScrapData leaves its zlib stream open at a
        // Z_SYNC_FLUSH boundary instead of emitting Z_STREAM_END + Adler-32.
        // Block selection and total compressed length are implementation
        // details; only the empty stored-block marker is guaranteed.
        XCTAssertEqual(
            compressed.suffix(4),
            Data([0x00, 0x00, 0xFF, 0xFF]))
    }

    func testPackedTextMessageDrainsMultipleCompressionBuffers() throws {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        var bytes = [UInt8]()
        bytes.reserveCapacity(128 * 1024)
        for _ in 0..<(128 * 1024) {
            state = state &* 6_364_136_223_846_793_005
                &+ 1_442_695_040_888_963_407
            bytes.append(UInt8((state >> 32) % 95) + 32)
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let message = try AppleClipboardProtocol.packedTextMessage(text)
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))
        let uncompressedSize = Int(
            AppleClipboardProtocol.uint32BE(message, at: 8)!)

        XCTAssertGreaterThan(
            compressed.count,
            AppleClipboardProtocol.compressionChunkSize)
        XCTAssertEqual(
            try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: uncompressedSize),
            text)
    }

    func testPackedClipboardSelectionUsesServerCommandBitmap() {
        var packedBitmap = Data(repeating: 0, count: 16)
        packedBitmap[3] = 0x01 // command 31, MSB-first numbering
        let packedCapabilities = capabilities(bitmap: packedBitmap)

        var legacyBitmap = Data(repeating: 0, count: 16)
        legacyBitmap[0] = 0x02 // command 6 only
        let legacyCapabilities = capabilities(bitmap: legacyBitmap)

        XCTAssertTrue(TransportSession.shouldUseApplePackedClipboard(
            capabilities: packedCapabilities))
        XCTAssertFalse(TransportSession.shouldUseApplePackedClipboard(
            capabilities: legacyCapabilities))
        XCTAssertFalse(TransportSession.shouldUseApplePackedClipboard(
            capabilities: nil))
    }

    private func capabilities(bitmap: Data) -> AppleServerCapabilities {
        var field = Data([0, 0, 0, 0, 0, 0])
        field.append(bitmap)
        return AppleServerCapabilities(serverInitNameField: field)!
    }
}
