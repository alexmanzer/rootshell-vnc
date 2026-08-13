import XCTest
import Foundation
@testable import RFBTransport

/// Regression tests for Apple's AVC media SRTP (cipher suite 5 =
/// AES_256_CM_HMAC_SHA1_80). These vectors were generated from deterministic
/// byte sequences and contain no captured keys, packets, or media.
final class AppleSRTPContextTests: XCTestCase {

    // Synthetic 32-byte AES-256 master key + 14-byte master salt: 0x00...0x2d.
    private let keyB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLQ=="

    // Synthetic RTP packet with sequence 0x1234, SSRC 0x11223344, a four-byte
    // header extension, and a 48-byte plaintext payload containing 0x00...0x2f.
    private let packetB64 = "kGASNAECAwQRIjNEvt4AAaChoqP5uBi2sP75CY69L33Z/+U/WzaVmrZS0yJWMzsBZefJem06t3Hqh9pN49XoRfBwPuON97n+31NigxWW"
    private let expectedB64 = "kGASNAECAwQRIjNEvt4AAaChoqMAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8="

    func testUnprotectDecryptsSyntheticPayloadFromCipherSuite5() throws {
        let key = Data(base64Encoded: keyB64)!
        let packet = Data(base64Encoded: packetB64)!
        let expected = Data(base64Encoded: expectedB64)!

        XCTAssertEqual(key.count, 46, "cipher suite 5 media key is 32-byte AES-256 key + 14-byte salt")

        let context = try AppleSRTPContext(mediaKey: key)
        let unprotected = try context.unprotect(packet)

        XCTAssertEqual(unprotected, expected)
        XCTAssertEqual(Array(unprotected.dropFirst(20)), Array(0x00...0x2f))
    }

    func testRejectsShortKey() {
        XCTAssertThrowsError(try AppleSRTPContext(mediaKey: Data(count: 30)))
    }

    func testCachedCTRCryptorResetsForEveryPacket() throws {
        let key = Data(base64Encoded: keyB64)!
        let packet = Data(base64Encoded: packetB64)!
        let expected = Data(base64Encoded: expectedB64)!
        let context = try AppleSRTPContext(mediaKey: key)

        for _ in 0..<128 {
            XCTAssertEqual(try context.unprotect(packet), expected)
        }
    }

    func testAuthenticationRejectsModifiedTagWithCachedContext() throws {
        let key = Data(base64Encoded: keyB64)!
        let packet = Data(base64Encoded: packetB64)!
        let context = try AppleSRTPContext(mediaKey: key)
        _ = try context.unprotect(packet)

        var modified = packet
        modified[modified.index(before: modified.endIndex)] ^= 0x01
        XCTAssertThrowsError(try context.unprotect(modified))
    }
}
