import CommonCrypto
import CryptoKit
import Foundation
import RFBProtocol

/// Receive-side SRTP unprotect for Apple's AVC media stream packets.
///
/// AVConference stores media keys as 46-byte blobs and native Screen Sharing
/// configures SRTP/SRTCP cipher suite `5`. Confirmed empirically against a live
/// server: suite 5 is **AES_256_CM_HMAC_SHA1_80** — a 32-byte AES-256 master
/// key followed by a 14-byte master salt (32 + 14 = 46), with an 80-bit
/// (10-byte) HMAC-SHA1 authentication tag. The server-to-viewer key
/// (`...EncryptionKeyServerToViewer`) is the one used to decrypt inbound video.
public final class AppleSRTPContext: @unchecked Sendable {
    private struct SSRCState {
        var roc: UInt32 = 0
        var highestSequence: UInt16?
    }

    private static let masterKeyLength = 32
    private static let masterSaltLength = 14

    private let encryptionKey: Data
    private let authenticationKey: Data
    private let saltKey: Data
    private let tagLength = 10
    private let lock = NSLock()
    private var states: [UInt32: SSRCState] = [:]

    public init(mediaKey: Data) throws {
        let required = Self.masterKeyLength + Self.masterSaltLength
        guard mediaKey.count >= required else {
            throw VNCProtocolError.protocolViolation(
                "Apple SRTP media key must be at least \(required) bytes, got \(mediaKey.count)")
        }

        let masterKey = Data(mediaKey.prefix(Self.masterKeyLength))
        let masterSalt = Data(mediaKey.dropFirst(Self.masterKeyLength).prefix(Self.masterSaltLength))
        self.encryptionKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x00, length: Self.masterKeyLength)
        self.authenticationKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x01, length: 20)
        self.saltKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x02, length: 14)
    }

    public func unprotect(_ packet: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard packet.count >= 12 + tagLength else {
            throw VNCProtocolError.protocolViolation("SRTP packet too short: \(packet.count)")
        }

        let base = packet.startIndex
        guard (packet[base] >> 6) == 2 else {
            throw VNCProtocolError.protocolViolation("SRTP packet has invalid RTP version")
        }

        let sequence = UInt16(packet[base + 2]) << 8 | UInt16(packet[base + 3])
        let ssrc = UInt32(packet[base + 8]) << 24
            | UInt32(packet[base + 9]) << 16
            | UInt32(packet[base + 10]) << 8
            | UInt32(packet[base + 11])

        var state = states[ssrc] ?? SSRCState()
        let roc = estimatedROC(for: sequence, state: state)
        try verifyAuthentication(packet: packet, roc: roc)

        let payloadOffset = try Self.payloadOffset(in: packet)
        let encryptedEnd = packet.endIndex - tagLength
        guard payloadOffset <= encryptedEnd else {
            throw VNCProtocolError.protocolViolation("SRTP packet has invalid payload bounds")
        }

        let header = Data(packet[base..<payloadOffset])
        let encryptedPayload = Data(packet[payloadOffset..<encryptedEnd])
        let packetIndex = (UInt64(roc) << 16) | UInt64(sequence)
        let payload = try decryptPayload(encryptedPayload, ssrc: ssrc, packetIndex: packetIndex)

        updateState(&state, sequence: sequence, roc: roc)
        states[ssrc] = state

        var rtp = Data(capacity: header.count + payload.count)
        rtp.append(header)
        rtp.append(payload)
        return rtp
    }

    private func verifyAuthentication(packet: Data, roc: UInt32) throws {
        let authenticatedEnd = packet.endIndex - tagLength
        let tag = Data(packet[authenticatedEnd..<packet.endIndex])
        var input = Data(packet[packet.startIndex..<authenticatedEnd])
        input.append(UInt8((roc >> 24) & 0xff))
        input.append(UInt8((roc >> 16) & 0xff))
        input.append(UInt8((roc >> 8) & 0xff))
        input.append(UInt8(roc & 0xff))

        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: input,
            using: SymmetricKey(data: authenticationKey)
        )
        let expected = Data(mac.prefix(tagLength))
        guard expected == tag else {
            throw VNCProtocolError.protocolViolation("SRTP authentication failed")
        }
    }

    private func decryptPayload(_ payload: Data, ssrc: UInt32, packetIndex: UInt64) throws -> Data {
        guard !payload.isEmpty else { return Data() }

        // AES-CM is AES-CTR with a big-endian counter whose low 16 bits are the
        // per-block counter. RTP payloads are well under 2^16 blocks, so a
        // single hardware AES-CTR pass (initial counter = block 0) produces the
        // same keystream as stepping the counter block by block — but with one
        // CommonCrypto call instead of ~90, which matters at thousands of
        // packets per second.
        let iv = counterBlock(ssrc: ssrc, packetIndex: packetIndex, blockCounter: 0)

        var cryptorRef: CCCryptorRef?
        let createStatus = iv.withUnsafeBytes { ivPtr in
            encryptionKey.withUnsafeBytes { keyPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivPtr.baseAddress, keyPtr.baseAddress, encryptionKey.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptorRef)
            }
        }
        guard createStatus == kCCSuccess, let cryptor = cryptorRef else {
            throw VNCProtocolError.ioError("AES-CTR init failed: \(createStatus)")
        }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: payload.count)
        var moved = 0
        let updateStatus = output.withUnsafeMutableBytes { outPtr in
            payload.withUnsafeBytes { inPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, payload.count,
                                outPtr.baseAddress, outPtr.count, &moved)
            }
        }
        guard updateStatus == kCCSuccess else {
            throw VNCProtocolError.ioError("AES-CTR update failed: \(updateStatus)")
        }
        if moved < output.count { output.removeSubrange(moved..<output.count) }
        return output
    }

    private func counterBlock(ssrc: UInt32, packetIndex: UInt64, blockCounter: UInt16) -> Data {
        var block = Data(count: 16)
        block.replaceSubrange(0..<saltKey.count, with: saltKey)

        block[4] ^= UInt8((ssrc >> 24) & 0xff)
        block[5] ^= UInt8((ssrc >> 16) & 0xff)
        block[6] ^= UInt8((ssrc >> 8) & 0xff)
        block[7] ^= UInt8(ssrc & 0xff)

        let indexBytes = [
            UInt8((packetIndex >> 40) & 0xff),
            UInt8((packetIndex >> 32) & 0xff),
            UInt8((packetIndex >> 24) & 0xff),
            UInt8((packetIndex >> 16) & 0xff),
            UInt8((packetIndex >> 8) & 0xff),
            UInt8(packetIndex & 0xff),
        ]
        for i in 0..<6 {
            block[8 + i] ^= indexBytes[i]
        }

        block[14] = UInt8((blockCounter >> 8) & 0xff)
        block[15] = UInt8(blockCounter & 0xff)
        return block
    }

    private func estimatedROC(for sequence: UInt16, state: SSRCState) -> UInt32 {
        guard let highestSequence = state.highestSequence else { return state.roc }
        // RFC 3711 Appendix A ROC guess. Use signed arithmetic so the
        // wraparound comparisons never underflow UInt32.
        let maxSeq = Int64(highestSequence)
        let seq = Int64(sequence)
        let roc = Int64(state.roc)
        if maxSeq < 0x8000 {
            if seq - maxSeq > 0x8000, roc > 0 {
                return UInt32(roc - 1)
            }
            return state.roc
        }
        if maxSeq - seq > 0x8000 {
            return UInt32(min(roc + 1, Int64(UInt32.max)))
        }
        return state.roc
    }

    private func updateState(_ state: inout SSRCState, sequence: UInt16, roc: UInt32) {
        if let highest = state.highestSequence,
           highest > 0xf000,
           sequence < 0x0fff,
           roc == state.roc + 1 {
            state.roc = roc
        }
        if state.highestSequence == nil || sequenceIsNewer(sequence, than: state.highestSequence!) {
            state.highestSequence = sequence
        }
    }

    private func sequenceIsNewer(_ sequence: UInt16, than previous: UInt16) -> Bool {
        let distance = sequence &- previous
        return distance != 0 && distance < 0x8000
    }

    private static func payloadOffset(in packet: Data) throws -> Data.Index {
        let base = packet.startIndex
        let csrcCount = Int(packet[base] & 0x0f)
        let hasExtension = (packet[base] & 0x10) != 0
        var offset = base + 12 + csrcCount * 4
        guard offset <= packet.endIndex else {
            throw VNCProtocolError.protocolViolation("RTP CSRC header exceeds packet length")
        }

        if hasExtension {
            guard offset + 4 <= packet.endIndex else {
                throw VNCProtocolError.protocolViolation("RTP extension header exceeds packet length")
            }
            let extensionLength = Int(UInt16(packet[offset + 2]) << 8 | UInt16(packet[offset + 3]))
            offset += 4 + extensionLength * 4
            guard offset <= packet.endIndex else {
                throw VNCProtocolError.protocolViolation("RTP extension payload exceeds packet length")
            }
        }

        return offset
    }

    private static func deriveSessionKey(masterKey: Data, masterSalt: Data, label: UInt8, length: Int) throws -> Data {
        guard masterSalt.count == 14 else {
            throw VNCProtocolError.protocolViolation("SRTP master salt must be 14 bytes")
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

    private func aesEncryptBlock(_ block: Data) throws -> Data {
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
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputPtr in
            key.withUnsafeBytes { keyPtr in
                block.withUnsafeBytes { blockPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        key.count,
                        nil,
                        blockPtr.baseAddress,
                        block.count,
                        outputPtr.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess, outputLength == kCCBlockSizeAES128 else {
            throw VNCProtocolError.ioError("AES block encrypt failed: \(status)")
        }
        return output
    }
}
