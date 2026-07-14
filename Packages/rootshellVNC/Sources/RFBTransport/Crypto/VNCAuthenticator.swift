import Foundation
import CommonCrypto
import RFBProtocol

/// Type 2 VNC Authentication using DES challenge-response.
///
/// Protocol:
/// 1. Server sends 16-byte random challenge
/// 2. Client DES-encrypts the challenge using the password as key
/// 3. Client sends 16-byte response
///
/// VNC DES has a quirk: each byte of the password key has its bits reversed.
public struct VNCAuthenticator: Authenticator, Sendable {

    private let password: String
    private let log = VNCLogger(category: "VNCAuth")

    public init(password: String) {
        self.password = password
    }

    public func authenticate(connection: any RFBConnection) async throws -> AuthenticationResult {
        log.info("Starting VNC authentication (Type 2)")

        // Step 1: Read 16-byte challenge
        let challenge = try await connection.read(exactly: 16)
        log.debug("Received 16-byte challenge")

        // Step 2: Prepare the key — password truncated/padded to 8 bytes, bits reversed
        let key = prepareKey(from: password)

        // Step 3: DES-encrypt the challenge
        let response = try desEncrypt(challenge: challenge, key: key)
        log.debug("Computed DES response")

        // Step 4: Send the response
        try await connection.send(response)
        log.info("Sent VNC auth response")
        return AuthenticationResult()
    }

    // MARK: - Private helpers

    /// Prepare the DES key from the password.
    /// VNC uses at most 8 characters, zero-padded, with each byte's bits reversed.
    private func prepareKey(from password: String) -> Data {
        var keyBytes = [UInt8](repeating: 0, count: 8)
        let passwordBytes = Array(password.utf8.prefix(8))
        for i in 0..<passwordBytes.count {
            keyBytes[i] = reverseBits(passwordBytes[i])
        }
        return Data(keyBytes)
    }

    /// Reverse the bit order within a single byte.
    /// VNC DES requires this transformation on each key byte.
    private func reverseBits(_ byte: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var input = byte
        for _ in 0..<8 {
            result = (result << 1) | (input & 1)
            input >>= 1
        }
        return result
    }

    /// DES-ECB encrypt the 16-byte challenge with the 8-byte key.
    /// The challenge is two 8-byte blocks encrypted independently.
    private func desEncrypt(challenge: Data, key: Data) throws -> Data {
        var output = Data(count: 16)
        let keyBytes = [UInt8](key)

        // Encrypt first 8 bytes
        let block1 = try desEncryptBlock(Array(challenge[challenge.startIndex..<challenge.startIndex + 8]),
                                         key: keyBytes)
        // Encrypt second 8 bytes
        let block2 = try desEncryptBlock(Array(challenge[challenge.startIndex + 8..<challenge.startIndex + 16]),
                                         key: keyBytes)

        output.replaceSubrange(0..<8, with: block1)
        output.replaceSubrange(8..<16, with: block2)
        return output
    }

    /// DES-ECB encrypt a single 8-byte block with an 8-byte key.
    private func desEncryptBlock(_ plaintext: [UInt8], key: [UInt8]) throws -> [UInt8] {
        var outLength = 0
        var outBuffer = [UInt8](repeating: 0, count: 16) // extra space for safety

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),
            key,
            kCCKeySizeDES,
            nil, // no IV for ECB
            plaintext,
            plaintext.count,
            &outBuffer,
            outBuffer.count,
            &outLength
        )

        guard status == kCCSuccess else {
            throw VNCProtocolError.ioError("DES encryption failed with status \(status)")
        }

        return Array(outBuffer[0..<8])
    }
}
