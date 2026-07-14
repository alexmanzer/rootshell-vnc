import XCTest
import Foundation
@testable import RFBTransport

/// Regression test for Apple's SRTCP (cipher suite 5 = AES-256-CM / HMAC-SHA1-80,
/// SRTCP variant with labels 3/4/5). The interoperability vector contains a
/// 46-byte server-to-viewer media key and one protected
/// Sender Report (SSRC 0x11812aa6).
final class AppleSRTCPContextTests: XCTestCase {

    private let keyB64 = "HHaIVDCPzAyi04iw/piEeO3LR2K0LYtbynsgwnfmBGOIeR7JCvdy2JWwBPnnQg=="
    private let srtcpB64 = "gcgADBGBKqYS5tQnMkrW6BLr0ApANZwXLefHrCAXWEMZ0M1dztueZYRw2vrEbXNQv8TDWbDaZ4/auStfRLy2roAAAAEwHmd9h6rpbzlR"

    func testUnprotectsServerSenderReport() throws {
        let key = Data(base64Encoded: keyB64)!
        let srtcp = Data(base64Encoded: srtcpB64)!
        XCTAssertEqual(key.count, 46)
        XCTAssertEqual(srtcp.count, 78)

        let context = try AppleSRTCPContext(mediaKey: key)
        // If the auth tag verifies and decryption runs, the crypto is correct.
        let rtcp = try context.unprotect(srtcp)

        // First 8 bytes (header + sender SSRC) are unchanged.
        XCTAssertEqual(Array(rtcp.prefix(4)), [0x81, 0xc8, 0x00, 0x0c])
        XCTAssertEqual(rtcp.count, 64) // SR(52) + SDES(12), index word + tag stripped
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
