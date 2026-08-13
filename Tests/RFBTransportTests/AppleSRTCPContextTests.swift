import XCTest
import Foundation
@testable import RFBTransport

/// Regression tests for Apple's SRTCP (cipher suite 5 = AES-256-CM /
/// HMAC-SHA1-80, SRTCP labels 3/4/5). These vectors were generated from
/// deterministic byte sequences and contain no captured session data.
final class AppleSRTCPContextTests: XCTestCase {

    // Synthetic 32-byte AES-256 master key + 14-byte master salt: 0x00...0x2d.
    private let keyB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLQ=="
    private let srtcpB64 = "gMgABhEiM0R6CmmE9ckW/5A4cfEBYtI0A5xbwIAAAAHrkmPXe5xJQHrm"
    private let expectedB64 = "gMgABhEiM0QBAgMEBQYHCAkKCwwAAAACAAAAQA=="

    func testUnprotectsSyntheticSenderReport() throws {
        let key = Data(base64Encoded: keyB64)!
        let srtcp = Data(base64Encoded: srtcpB64)!
        let expected = Data(base64Encoded: expectedB64)!
        XCTAssertEqual(key.count, 46)
        XCTAssertEqual(srtcp.count, expected.count + 4 + 10)

        let context = try AppleSRTCPContext(mediaKey: key)
        XCTAssertEqual(try context.unprotect(srtcp), expected)
    }

    func testProtectRoundTrips() throws {
        let key = Data(base64Encoded: keyB64)!
        let context = try AppleSRTCPContext(mediaKey: key)

        // Minimal RTCP RR-like packet: header + sender SSRC + a payload word.
        var rtcp = Data([0x80, 0xc9, 0x00, 0x01])           // V2, RR, len=1
        rtcp.append(contentsOf: [0x00, 0x00, 0x00, 0x2a])   // sender SSRC = 42
        rtcp.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])

        let protected = try context.protect(rtcp, senderSSRC: 42)
        XCTAssertEqual(protected.count, rtcp.count + 4 + 10) // + index word + tag
        let recovered = try context.unprotect(protected)
        XCTAssertEqual(recovered, rtcp)
    }
}
