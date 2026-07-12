import XCTest
import Foundation
@testable import RFBTransport

/// Regression tests for Apple's AVC media SRTP (cipher suite 5 =
/// AES_256_CM_HMAC_SHA1_80). The vector below was captured from a live macOS
/// Screen Sharing server: the 46-byte server-to-viewer media key, one protected
/// SRTP video packet, and the expected unprotected RTP (header + ext +
/// decrypted HEVC payload, with the 10-byte auth tag removed).
final class AppleSRTPContextTests: XCTestCase {

    // 46-byte AES-256 master key (32) + master salt (14).
    private let keyB64 = "glJDw6QnWToU4BiauW+5PQ3Go1GJh0vk2mVZ9zxBKTGyhxlbm2A6Bu6gwkkNHQ=="
    private let packetB64 = "kGQwnwAAAAAHDfoOkxEAAQA8d8Dv/eorsqFdtXsHneJtSup7TcSo2KR7DTumgT4YE71k+M6ySrwfzIiwEHrPE0J0U/pZXOwp7K8mR1Hfh8KyaVrEQM82EjA/ac78cpOi4rIL9JQBDUTSehnkFrkm4G+mZ+iQO7TPTp54yxnQkMu0usJcx8Gm0cWOfS2HthYF1u+uIc0XrUESAKmhA6UPVDrdevQ8bkg+vMgeQ1uqymdj34Fbapcbrs/k+o0UK2wlS1SIyZqZkRgJGOW4mwXhl+weIAzFCOMPKmIkCXWZ4vzn0Q1x6CAmyKR6dZwIMdxHuUQnAPYjLdDebkuDxxLTDpuRORche4NMKrP1sva8Ez+w9jycOA82x0fMNm7Ki3JNdnPM4Oug65OiAa7TOJMlqYCUhEuPYTl73HdOpAY0yVtwT0jTmB/tgkIMvDtKeUJOWa3xYbfAt1fQ2GiusuYQGX/2UIlbFMNPUeGuAXFLfgtzK/+9dQeMYYqCAVhA0SL/SxqDKc0zPPeAMus22i8BJsi1FEA1ebBdnEVtg8opMHifKaP88zmLsOEDQuV8hKWcepQw/gV8UrCZmvKRtw7pq3+sA14dnlGD3Kqe+U9opLdBK8yMYREOrn2+9+8xqaKYAx6kkcGee8UjvhLO9wob70t9MTIQS2DKg9B97aBOsIX3gCkvOYjq0WYAe1TETUcE4xmlhLpTVjVG9phXoN/uGRUHlnU91DXJ6I79L2ugpr8rQcEJuoUX5daQrkVK21oKNzp/saH/S3dMkt4iaceSVf5DHKj4jifA8PloXA1pN6eqbq9W/WqUEQqNem0Ewk9SqnK+nOn2i4hyVBMAMFBQuw0hc8sEwzBzhnNpJWKNOay7LJseOiH12nWSSuzCHdSLw9hAyVO2rrz2ubtDGsDnFGBnImcrp0mdbCm8uN8r6+LYu/SgutjVhYIzuK5OUPix39CvQimNd0bgujW5Teo35UdF6DC3PHqTKcdlpyuT6Zqe/h4LkEA2j0PjqruEN96GnjTq94bs0oKBedqvgeP+fb8ZmT55R8WjUviPvOLZk12yjE9m0Sf4w3K48P+UOkb/m/8RTBVa2sxzgK84amhGQQKXq6YzWfkL3H2g9Nb6ZNmTLkFLk+dE0WhQ9RS3YqxQwpwKfNtewTKgwzoKwTlkjBv5WsRsvGPsB1QC+MJyksgJauvfEkOJT9OzGQnErZB6Sky14xnD5juZnfwGVhsFcuH7dpPfo/LMdE5adaAjIItIn5WJc0f2G/VKCGRZ9OlrDCjAggbkmMskkAGyD56Imez7fdD4qsYEcXS4rW+G6cMkWhkcn8HOG90F2yNsTALb0CXbRPcfb2Sfb4toGePHOZLFkfe2iDFXlSMWY+/d9/1HsB3LQ13WElAWpu26XnfVKga/IGIq+UzRTyEi+qW9RlVS+IdusmkcwyKscgiC5NsAg2WE+lRA0+NE3fmS37USlp7z5z3ypJhbczLbttPe4Kk93u04uB+ntUGHjCriuYGTi7ga273Hn84xDBykYCrlFzbiUYp5zJuSKnIxKkhfGR1y2devhSLUJKU2uYjIkx3Ae6lw/cE41a16wT5/Fg8LF109yPDwaAJBQgKtHtfN4ZlLQD8pF3nuBLdK/7vFnvvLTkyxXdWCAZrFflumRejnGuJjIQdcKy5I860CpILC4kh/yMXK7jntYdEIIVeusZCtBkhqswnuE7dDx4pPCsWjHqTPX9HHQKZ5vrzkwaU+hMgGt315xKwQGjt6dbNDakKdUsh0Oj7/vAxggPby46aEZFWyWxtYj7cgs/qEiUWp9aLvaJ0Du3H0ZA=="
    private let expectedB64 = "kGQwnwAAAAAHDfoOkxEAAQA8d8BiAZTUEK8IWFxzCeiWg/RjOE9FM4fgaJisS52fWH35+aT5DZBdK4CytJi0W8JNJFHA8wbf4AmLaD8H8//3blL6b5RORq4PdfQLk0mvb9V70relvo1muUYqjxvDJCD5WecrK+Nc1289Y/zGS6BnNpTSFQG3QeUTQ5AceFC2m12GOkRyg4w3Xp1r27Uf2UqS+DN2cSPoMwo70WxQt0qX7oTmbJ/tQIkiG0yU/Jy1l/3zlH9Hiskg7zuhqAACnxL7tfWCYEGbLzrJ6av6Wf8+sUxandk44UpZ0iz13LjevOiDb48bRicpO7WQ4dbq7EraTEVR9mHbB5D2Lu9gLXZ2Ci1zQSqZRcbMrnXlFp5OYow6LYMXUiOmCSQf6a7gaopXzbOjpTdIV02++h8nu3cbwWK3H1A/PrDFgE26CM9yA9JSe4QmPFTR7YiRKXCQ2vSfoow5/1PO3lvqtGGkBI7+8qCbLK4yV8O1AYEp17WPrjf6PCK2qw+iJwqmyJCCOjVr0cxJpvakmmwmYEXvsSlcYcydmEVrZafMowXjJzM8NzMEokVlsXuXQ34pUs+LAZlXX+y9KNadWqysSbzRoeb7l3so7slMB5C0hQWK3HK91PsXxvV9oqfetMmSdvFeEAFE7NNMBSEsGaHjo0LFe94YzB5kOL+nfK8i05BmsvqRpAIW/5S6q00nkLUvJXz9iPnK5Dv1yT8hW465ev4LlEQDrRV6ozKS+goeyD354KOfnl0+s9Oc3fwcm22niR/3k4+vVNm2MH+r2fLVZMnyqAhv+Ea1MxkXYPwvbhi13m1AdbddKKll1ZgGXysvVInuK605jf6mD7U8tok49/lhb4kcApwcvfzYbQLW29WO6sEMNvu1ATjTMv9eP+efesCAB8cfCWSkDNibDXEUXHc61j3bQ5bNuiWFw8XjuuElCunXU/xdBRjpO6oul7Oy7Ab7/xPspUZHqVJAkqMyJglXG7FuHhch2eGe2xlFmaeRmoj+nm8gGoieXvqGrnm2puGO38e7ANMqrtNnPgVDbAOS7ha/CmBQUL18DHYym5fqM2sc71KcCRtlXfOyu/cvdMPcsV1L9zHKY/ZbCNbcumX3fZ8/SjsClfIa46Tx6+rC1wlDoxLwGwF9Jj6DPR0aiGBwzO1qpHl1VtD26q3PoF3lm9AvMdc8e1fVkGcIW+lEorCDjynQHfFSc7Gf/7ac9dLCRAgnU/vXz/KAn3qtUiNF9GEkAyQPm5yHYQKg/HUauaCNLvRIA1DF/mrEt70197sqepV7ldZ8Sgl0d8noaQu891yIaN/I2Ane8v/twy1ZdNQP/RuKRgG2Gv0yJ1i3BmPNnPKbeq+erjOYHjeUsweF/FKNg9hC5zJshhrlLPaDo4O+4UGy+Fztrm093Cum55m2wcOBQvJOlRTFOBCXbyGtM5lTrQ/dy4s4BAwZAvaCBDRXmRiQ2ENP//byEDBuOZyr6bt/5XXCI4f0J5aqw4JTT0U70dxXUQlIn9bpSLbCzE+ZUpyXGGA3x06+7SedkkgMkBvuWnc6ySH+lOrrggvtWiZvJ51ABonbVFjbOLHiDMQRCoeMKdxAD8U5eSPLUMn5+Z7fdtIjPpCWVt3cb5SPtIv4X5xft6iaNn3l/s2XbLrzORN4kl+mouXl/3is2abEBU9zFcry2W48rZghAQV8Mp+Yn5bh5pG8Qmy/XF7EFYvI/BKvRLzP+dBLrxmygU2lqXKegvCt333tHeVd6CONVAhtqv9/lju1otTOpnw3r+2fci8RB9B+YLuT5ZL0KYAl"

    func testUnprotectDecryptsHEVCVideoFromCipherSuite5() throws {
        let key = Data(base64Encoded: keyB64)!
        let packet = Data(base64Encoded: packetB64)!
        let expected = Data(base64Encoded: expectedB64)!

        XCTAssertEqual(key.count, 46, "cipher suite 5 media key is 32-byte AES-256 key + 14-byte salt")

        let context = try AppleSRTPContext(mediaKey: key)
        let unprotected = try context.unprotect(packet)

        XCTAssertEqual(unprotected, expected, "SRTP unprotect must reproduce the captured plaintext")

        // The decrypted payload begins with an HEVC fragmentation unit carrying
        // an IDR keyframe: NAL type 49 (FU), FU header 0x94 => start bit + FuType 20.
        let payload = unprotected.dropFirst(20) // 12 RTP header + 8-byte extension
        XCTAssertEqual(payload.first, 0x62, "HEVC NAL header (type 49, FU)")
        XCTAssertEqual(payload.dropFirst(2).first, 0x94, "FU header: start bit + IDR_W_RADL (20)")
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
