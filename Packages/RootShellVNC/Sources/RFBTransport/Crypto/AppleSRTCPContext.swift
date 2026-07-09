import CommonCrypto
import CryptoKit
import Foundation
import RFBProtocol

/// SRTCP protect/unprotect for Apple's AVC media control channel.
///
/// Apple's Screen Sharing RTCP is SRTCP with the same suite as its SRTP media
/// (cipher suite 5 = AES-256-CM / HMAC-SHA1-80): a 32-byte AES-256 master key
/// followed by a 14-byte master salt (the 46-byte media key). SRTCP derives its
/// own session keys with labels 3/4/5 and appends a 4-byte SRTCP index word
/// (E-flag + 31-bit index) plus a 10-byte auth tag.
///
/// Validated on the wire: unprotecting a captured server Sender Report with the
/// server-to-viewer key authenticates and decrypts to sane counters.
public final class AppleSRTCPContext: @unchecked Sendable {

    private static let masterKeyLength = 32
    private static let masterSaltLength = 14

    private let encryptionKey: Data // 32-byte AES-256 session key (label 3)
    private let authenticationKey: Data // 20-byte HMAC-SHA1 key (label 4)
    private let saltKey: Data // 14-byte session salt (label 5)
    private let tagLength = 10

    private let lock = NSLock()
    private var sendIndex: UInt32 = 0

    public init(mediaKey: Data) throws {
        let required = Self.masterKeyLength + Self.masterSaltLength
        guard mediaKey.count >= required else {
            throw VNCProtocolError.protocolViolation(
                "Apple SRTCP media key must be at least \(required) bytes, got \(mediaKey.count)")
        }
        let masterKey = Data(mediaKey.prefix(Self.masterKeyLength))
        let masterSalt = Data(mediaKey.dropFirst(Self.masterKeyLength).prefix(Self.masterSaltLength))
        self.encryptionKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x03, length: Self.masterKeyLength)
        self.authenticationKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x04, length: 20)
        self.saltKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x05, length: 14)
    }

    /// Protect a plaintext RTCP compound packet as SRTCP (E-flag set, encrypted).
    ///
    /// The first 8 bytes (header + sender SSRC) stay in the clear; the remainder
    /// is AES-256-CM encrypted, then the SRTCP index word and HMAC-SHA1-80 tag
    /// are appended. `senderSSRC` must equal the RTCP packet's sender SSRC.
    public func protect(_ rtcp: Data, senderSSRC: UInt32) throws -> Data {
        guard rtcp.count >= 8 else {
            throw VNCProtocolError.protocolViolation("RTCP packet too short: \(rtcp.count)")
        }
        lock.lock()
        defer { lock.unlock() }

        sendIndex = (sendIndex + 1) & 0x7fff_ffff
        let index = sendIndex

        let base = rtcp.startIndex
        let header = Data(rtcp[base..<base + 8])
        let plaintext = Data(rtcp[base + 8..<rtcp.endIndex])
        let encrypted = try transform(plaintext, ssrc: senderSSRC, index: index)

        var out = Data(capacity: 8 + encrypted.count + 4 + tagLength)
        out.append(header)
        out.append(encrypted)
        // SRTCP index word with E-flag set.
        let indexWord = index | 0x8000_0000
        out.append(UInt8((indexWord >> 24) & 0xff))
        out.append(UInt8((indexWord >> 16) & 0xff))
        out.append(UInt8((indexWord >> 8) & 0xff))
        out.append(UInt8(indexWord & 0xff))

        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: out, using: SymmetricKey(data: authenticationKey))
        out.append(contentsOf: mac.prefix(tagLength))
        return out
    }

    /// Unprotect a server SRTCP packet (used for crypto validation/tests).
    public func unprotect(_ srtcp: Data) throws -> Data {
        guard srtcp.count >= 8 + 4 + tagLength else {
            throw VNCProtocolError.protocolViolation("SRTCP packet too short: \(srtcp.count)")
        }
        let base = srtcp.startIndex
        let tag = Data(srtcp[srtcp.endIndex - tagLength..<srtcp.endIndex])
        let authedEnd = srtcp.endIndex - tagLength
        let authed = Data(srtcp[base..<authedEnd])
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: authed, using: SymmetricKey(data: authenticationKey))
        guard Data(mac.prefix(tagLength)) == tag else {
            throw VNCProtocolError.protocolViolation("SRTCP authentication failed")
        }

        let indexWordStart = authedEnd - 4
        let indexWord = UInt32(srtcp[indexWordStart]) << 24
            | UInt32(srtcp[indexWordStart + 1]) << 16
            | UInt32(srtcp[indexWordStart + 2]) << 8
            | UInt32(srtcp[indexWordStart + 3])
        let index = indexWord & 0x7fff_ffff
        let ssrc = UInt32(srtcp[base + 4]) << 24
            | UInt32(srtcp[base + 5]) << 16
            | UInt32(srtcp[base + 6]) << 8
            | UInt32(srtcp[base + 7])

        let header = Data(srtcp[base..<base + 8])
        let ciphertext = Data(srtcp[base + 8..<indexWordStart])
        let decrypted = try transform(ciphertext, ssrc: ssrc, index: index)
        return header + decrypted
    }

    // MARK: - AES-256-CM

    private func transform(_ data: Data, ssrc: UInt32, index: UInt32) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(capacity: data.count)
        var offset = 0
        while offset < data.count {
            let block = try aesEncrypt(counterBlock(ssrc: ssrc, index: index, blockCounter: UInt16(offset / 16)))
            let chunk = min(16, data.count - offset)
            for i in 0..<chunk {
                output.append(data[data.startIndex + offset + i] ^ block[block.startIndex + i])
            }
            offset += chunk
        }
        return output
    }

    private func counterBlock(ssrc: UInt32, index: UInt32, blockCounter: UInt16) -> Data {
        var block = Data(count: 16)
        block.replaceSubrange(0..<saltKey.count, with: saltKey)
        block[4] ^= UInt8((ssrc >> 24) & 0xff)
        block[5] ^= UInt8((ssrc >> 16) & 0xff)
        block[6] ^= UInt8((ssrc >> 8) & 0xff)
        block[7] ^= UInt8(ssrc & 0xff)
        // 48-bit packet index with the 31-bit SRTCP index in the low bytes.
        block[10] ^= UInt8((index >> 24) & 0xff)
        block[11] ^= UInt8((index >> 16) & 0xff)
        block[12] ^= UInt8((index >> 8) & 0xff)
        block[13] ^= UInt8(index & 0xff)
        block[14] = UInt8((blockCounter >> 8) & 0xff)
        block[15] = UInt8(blockCounter & 0xff)
        return block
    }

    private static func deriveSessionKey(masterKey: Data, masterSalt: Data, label: UInt8, length: Int) throws -> Data {
        guard masterSalt.count == 14 else {
            throw VNCProtocolError.protocolViolation("SRTCP master salt must be 14 bytes")
        }
        var input = Data(count: 16)
        input[7] = label
        for i in 0..<masterSalt.count {
            input[i] ^= masterSalt[masterSalt.startIndex + i]
        }
        var output = Data(capacity: length)
        var counter: UInt16 = 0
        while output.count < length {
            var block = input
            block[14] = UInt8((counter >> 8) & 0xff)
            block[15] = UInt8(counter & 0xff)
            output.append(try aesEncrypt(block: block, key: masterKey))
            counter &+= 1
        }
        return Data(output.prefix(length))
    }

    private func aesEncrypt(_ block: Data) throws -> Data {
        try Self.aesEncrypt(block: block, key: encryptionKey)
    }

    private static func aesEncrypt(block: Data, key: Data) throws -> Data {
        guard block.count == kCCBlockSizeAES128 else {
            throw VNCProtocolError.protocolViolation("AES block must be 16 bytes")
        }
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw VNCProtocolError.protocolViolation("AES key must be 16 or 32 bytes, got \(key.count)")
        }
        var output = Data(count: kCCBlockSizeAES128)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputPtr in
            key.withUnsafeBytes { keyPtr in
                block.withUnsafeBytes { blockPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count, nil,
                        blockPtr.baseAddress, block.count,
                        outputPtr.baseAddress, kCCBlockSizeAES128, &outputLength)
                }
            }
        }
        guard status == kCCSuccess, outputLength == kCCBlockSizeAES128 else {
            throw VNCProtocolError.ioError("AES block encrypt failed: \(status)")
        }
        return output
    }
}
