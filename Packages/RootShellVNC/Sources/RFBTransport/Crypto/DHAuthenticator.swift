import Foundation
import CommonCrypto
import BigInt
import RFBProtocol

/// Type 30 Apple Diffie-Hellman authentication.
///
/// Protocol:
/// 1. Read: generator (UInt16), keyLength (UInt16), prime (keyLength bytes), serverPublicKey (keyLength bytes)
/// 2. Generate random private key
/// 3. Compute clientPublicKey = generator^privateKey mod prime
/// 4. Compute sharedSecret = serverPublicKey^privateKey mod prime
/// 5. MD5-hash the shared secret to get a 16-byte AES key
/// 6. AES-128-ECB encrypt credentials (username + password, zero-padded to 128 bytes)
/// 7. Send: clientPublicKey (keyLength bytes) + encrypted credentials (128 bytes)
public struct DHAuthenticator: Authenticator, Sendable {

    private let password: String
    private let username: String
    private let log = VNCLogger(category: "DHAuth")

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public func authenticate(connection: TCPConnection) async throws -> AuthenticationResult {
        log.info("Starting Apple DH authentication (Type 30)")

        // Step 1: Read parameters from server
        let headerData = try await connection.read(exactly: 4)
        let generator = UInt16(headerData[0]) << 8 | UInt16(headerData[1])
        let keyLength = UInt16(headerData[2]) << 8 | UInt16(headerData[3])

        log.debug("Generator=\(generator), keyLength=\(keyLength)")

        let primeData = try await connection.read(exactly: Int(keyLength))
        let serverPubKeyData = try await connection.read(exactly: Int(keyLength))

        let prime = BigUInt(Data(primeData))
        let serverPublicKey = BigUInt(Data(serverPubKeyData))
        let g = BigUInt(generator)

        log.debug("Received server prime and public key")

        // Step 2: Generate random private key
        let privateKey = BigUInt.randomInteger(withMaximumWidth: Int(keyLength) * 8)

        // Step 3: Compute client public key = g^privateKey mod prime
        let clientPublicKey = g.power(privateKey, modulus: prime)

        // Step 4: Compute shared secret = serverPublicKey^privateKey mod prime
        let sharedSecret = serverPublicKey.power(privateKey, modulus: prime)

        // Step 5: MD5-hash the shared secret to get AES key
        let secretData = sharedSecret.serialize()
        let aesKey = md5(secretData)

        log.debug("Computed shared secret and AES key")

        // Step 6: Prepare and encrypt credentials
        // Format: username (null-terminated, 64 bytes) + password (null-terminated, 64 bytes)
        // Fill unused bytes with random data per the ARD spec to reduce predictability
        var credentials = Data(count: 128)
        // Fill with random bytes first
        credentials.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, 128, ptr.baseAddress!)
        }
        // Write null-terminated username (max 63 chars + null)
        let usernameBytes = Data(username.utf8)
        let uLen = min(usernameBytes.count, 63)
        credentials.replaceSubrange(0..<uLen, with: usernameBytes.prefix(uLen))
        credentials[uLen] = 0 // null terminator
        // Write null-terminated password (max 63 chars + null)
        let passwordBytes = Data(password.utf8)
        let pLen = min(passwordBytes.count, 63)
        credentials.replaceSubrange(64..<64 + pLen, with: passwordBytes.prefix(pLen))
        credentials[64 + pLen] = 0 // null terminator

        let encryptedCredentials = try aesECBEncrypt(data: credentials, key: aesKey)

        // Step 7: Send encrypted credentials FIRST, then client public key
        // (per Apple's wire format: rfb_apple_dh_client_msg)
        var clientPubKeyData = clientPublicKey.serialize()
        // Pad to keyLength with leading zeros if needed
        if clientPubKeyData.count < Int(keyLength) {
            var padded = Data(count: Int(keyLength))
            let offset = Int(keyLength) - clientPubKeyData.count
            padded.replaceSubrange(offset..<Int(keyLength), with: clientPubKeyData)
            clientPubKeyData = padded
        }

        var payload = Data()
        payload.append(encryptedCredentials)   // 128 bytes encrypted creds FIRST
        payload.append(clientPubKeyData)       // keyLength bytes public key SECOND

        try await connection.send(payload)
        log.info("Sent DH auth response (\(payload.count) bytes)")
        return AuthenticationResult(appleSessionKey: aesKey)
    }

    // MARK: - Private

    /// Compute MD5 hash of the given data, returning 16 bytes.
    private func md5(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    /// AES-128-ECB encrypt data. Data length must be a multiple of 16.
    private func aesECBEncrypt(data: Data, key: Data) throws -> Data {
        var outBuffer = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outLength = 0

        let status = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress,
                    kCCKeySizeAES128,
                    nil, // no IV for ECB
                    dataPtr.baseAddress,
                    data.count,
                    &outBuffer,
                    outBuffer.count,
                    &outLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw VNCProtocolError.ioError("AES-ECB encryption failed with status \(status)")
        }

        return Data(outBuffer[0..<outLength])
    }
}
