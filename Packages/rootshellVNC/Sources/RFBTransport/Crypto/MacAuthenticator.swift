import Foundation
import CommonCrypto
import CryptoKit
import Security
import BigInt
import RFBProtocol

/// Type 33 "Mac Authentication" — RSA key exchange plus protocol-defined
/// password modes.
///
/// Protocol flow:
///
/// **Phase 1: RSA Key Exchange**
/// 1. C→S: `[0x21] [len=10] [01 00 RSA1 00 00 00 00]` — capability request
/// 2. S→C: `[len] [version(2) + keyLen(4) + DER_RSA_key(keyLen) + trailing(1)]`
/// 3. C→S: `[len=650] [01 00 RSA1 00 02] [01 00] [256-byte RSA-encrypted AES key] [384 zero padding]`
///    The `00 02` flag requests DH+ChaCha mode.
/// 4. S→C: 4-byte auth result (0 = success)
///
/// **Phase 2: DH Key Exchange**
/// 5. S→C: DH parameters message with prime, generator, server DH pubkey, capabilities
/// 6. Client generates DH keypair, computes shared secret
/// 7. C→S: DH response with client pubkey and capabilities
/// 8. Key confirmation messages and encrypted session begins
///
/// **Key Derivation**
/// Shared secret → PBKDF2-SHA512 → ChaCha20-Poly1305 keys
public struct MacAuthenticator: Authenticator, Sendable {

    private let username: String
    private let password: String
    private let log = VNCLogger(category: "MacAuth")

    /// The capabilities string advertised in the DH exchange.
    private static let capabilitiesString =
        "mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2"

    private struct SRPClientResponse: Sendable {
        let publicKey: Data
        let proof: Data
        let expectedServerProof: Data
        let sessionKey: Data
    }

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Whether the security type byte has already been sent by the caller.
    /// If false, MacAuthenticator will prepend it to the first message.
    public var securityTypeAlreadySent = false

    public func authenticate(connection: any RFBConnection) async throws -> AuthenticationResult {
        log.info("Starting Mac Authentication (Type 33)")

        let rsaKey = try await requestRSAKey(connection: connection)
        if ProcessInfo.processInfo.environment["ROOTSHELL_VNC_TYPE33_DH"] == "1" {
            return try await authenticateDHMode(connection: connection, rsaKey: rsaKey)
        }
        if ProcessInfo.processInfo.environment["ROOTSHELL_VNC_TYPE33_SRP"] == "1" {
            return try await authenticateSRPMode(connection: connection, rsaKey: rsaKey)
        }

        let aesKey = try generateAESKey()
        let plainAuthBody = try buildPlainAuthenticationBody(
            rsaKey: rsaKey,
            aesKey: aesKey
        )
        try await sendLengthPrefixed(connection: connection, data: plainAuthBody)
        log.info("Sent Type 33 RSA plain authentication response (\(plainAuthBody.count) bytes)")

        // The server writes a Type-33 authentication result followed by the
        // normal RFB SecurityResult. Consume only the Type-33 result here so
        // TransportSession can keep its centralized SecurityResult handling.
        let result = try await readUInt32(connection: connection)
        guard result == 0 else {
            throw VNCProtocolError.authenticationFailed(
                "Mac Auth: plain authentication failed (result=\(result))")
        }

        return AuthenticationResult(appleSessionKey: aesKey)
    }

    private func authenticateDHMode(
        connection: any RFBConnection,
        rsaKey: RSAPublicKey
    ) async throws -> AuthenticationResult {
        let aesKey = try generateAESKey()
        let requestBody = try buildDHAuthenticationBody(rsaKey: rsaKey, aesKey: aesKey)
        try await sendLengthPrefixed(connection: connection, data: requestBody)
        log.info("Sent Type 33 RSA+DH authentication request (\(requestBody.count) bytes)")

        let (_, _, responseBody) = try await parseDHParams(connection: connection, aesKey: aesKey)
        try await sendLengthPrefixed(connection: connection, data: responseBody)
        log.info("Sent Type 33 DH client response (\(responseBody.count) bytes)")

        let confirmationLength = try await readUInt32(connection: connection)
        let confirmationBody = try await connection.read(exactly: Int(confirmationLength))
        guard confirmationLength > 6 else {
            throw VNCProtocolError.authenticationFailed(
                "Mac Auth DH: server rejected client DH response "
                    + "(\(confirmationBody.map { String(format: "%02x", $0) }.joined(separator: " ")))")
        }
        log.hexDump("Type 33 DH server confirmation", data: confirmationBody, maxBytes: 128)

        // The server sends the normal RFB SecurityResult after this confirmation.
        // Leave that four-byte result for TransportSession.readSecurityResult().
        return AuthenticationResult(appleSessionKey: aesKey)
    }

    private func authenticateSRPMode(
        connection: any RFBConnection,
        rsaKey: RSAPublicKey
    ) async throws -> AuthenticationResult {
        let requestBody = try buildSRPAuthenticationBody(rsaKey: rsaKey)
        try await sendLengthPrefixed(connection: connection, data: requestBody)
        log.info("Sent Type 33 SRP authentication request (\(requestBody.count) bytes)")

        let challengeLength = try await readUInt32(connection: connection)
        let challengeBody = try await connection.read(exactly: Int(challengeLength))
        guard challengeLength > 6 else {
            throw VNCProtocolError.authenticationFailed(
                "Mac Auth SRP: server rejected initial request (\(challengeBody.map { String(format: "%02x", $0) }.joined(separator: " ")))")
        }

        let challenge = try AppleSRPBuffer.parseServerChallenge(challengeBody)
        log.debug(
            "Type 33 SRP challenge: step=\(challenge.step), salt=\(challenge.salt.count) bytes, "
                + "iterations=\(challenge.iterations), options=\(challenge.options)")

        let client = try computeSRPResponse(challenge: challenge)
        let evidenceBuffer = try AppleSRPBuffer.clientEvidence(
            publicKey: client.publicKey,
            proof: client.proof,
            options: Self.capabilitiesString,
            clientSalt: randomBytes(count: 16)
        )
        var evidenceBody = Data()
        evidenceBody.append(contentsOf: [0x01, 0x00])
        evidenceBody.append(contentsOf: [0x52, 0x53, 0x41, 0x31])
        evidenceBody.append(contentsOf: [0x00, 0x02])
        evidenceBody.append(try AppleSRPBuffer.section(evidenceBuffer))
        if evidenceBody.count < 1076 {
            evidenceBody.append(Data(count: 1076 - evidenceBody.count))
        }
        try await sendLengthPrefixed(connection: connection, data: evidenceBody)
        log.info("Sent Type 33 SRP client proof (\(evidenceBody.count) bytes)")

        let confirmationLength = try await readUInt32(connection: connection)
        let confirmationBody = try await connection.read(exactly: Int(confirmationLength))
        guard confirmationLength > 6 else {
            throw VNCProtocolError.authenticationFailed(
                "Mac Auth SRP: server rejected client proof "
                    + "(\(confirmationBody.map { String(format: "%02x", $0) }.joined(separator: " ")))")
        }
        let confirmation = try AppleSRPBuffer.parseServerConfirmation(confirmationBody)
        guard confirmation.serverProof == client.expectedServerProof else {
            throw VNCProtocolError.authenticationFailed("Mac Auth SRP: server proof did not match")
        }

        log.info(
            "Type 33 SRP authenticated; serverIV=\(confirmation.serverIV.count) bytes, "
                + "maxBufferSize=\(confirmation.maxBufferSize)")
        return AuthenticationResult(appleSessionKey: appleSRPAESKey(from: client.sessionKey))
    }

    // MARK: - Phase 1: RSA Key Exchange

    private func requestRSAKey(connection: any RFBConnection) async throws -> RSAPublicKey {
        // Step 1: Send RSA1 capability request
        // The security type byte (0x21) and the RSA1 request MUST be in the same
        // TCP segment — the macOS server reads them as one unit.
        let capBody = Data([0x01, 0x00, 0x52, 0x53, 0x41, 0x31, 0x00, 0x00, 0x00, 0x00])
        //                   ver   00   R     S     A     1     00   00   00   00
        var capMsg = Data()
        if !securityTypeAlreadySent {
            capMsg.append(0x21) // security type 33
        }
        // Length-prefixed RSA1 request
        appendUInt32(&capMsg, UInt32(capBody.count))
        capMsg.append(capBody)
        try await connection.send(capMsg)
        log.info("Sent RSA1 capability request (\(capMsg.count) bytes)")

        // Step 2: Read server's RSA public key
        log.debug("Reading 4-byte response length...")
        let responseLen = try await readUInt32(connection: connection)
        log.info("Server RSA response length: \(responseLen)")

        let responseBody = try await connection.read(exactly: Int(responseLen))
        log.hexDump("Server RSA response", data: responseBody, maxBytes: 128)

        guard responseBody.count >= 7 else {
            throw VNCProtocolError.authenticationFailed(
                "Mac Auth: server RSA response too short (\(responseBody.count) bytes)")
        }

        let versionHigh = UInt16(responseBody[0]) << 8
        let versionLow = UInt16(responseBody[1])
        let version = versionHigh | versionLow

        let keyLen0 = UInt32(responseBody[2]) << 24
        let keyLen1 = UInt32(responseBody[3]) << 16
        let keyLen2 = UInt32(responseBody[4]) << 8
        let keyLen3 = UInt32(responseBody[5])
        let keyLen = Int(keyLen0 | keyLen1 | keyLen2 | keyLen3)

        log.debug("Server version: \(version), RSA key length: \(keyLen)")

        guard keyLen > 0, 6 + keyLen <= responseBody.count else {
            throw VNCProtocolError.authenticationFailed(
                "Mac Auth: invalid RSA key length \(keyLen)")
        }

        let derKeyData = responseBody[6..<6 + keyLen]
        // Trailing byte (usually 0x00) is ignored

        let rsaKey = try RSAPublicKey(derData: Data(derKeyData))
        log.info("Loaded server RSA public key (\(rsaKey.blockSize * 8) bits)")
        return rsaKey
    }

    private func generateAESKey() throws -> Data {
        var aesKey = Data(count: kCCKeySizeAES128)
        let randomResult = aesKey.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, kCCKeySizeAES128, ptr.baseAddress!)
        }
        guard randomResult == errSecSuccess else {
            throw VNCProtocolError.ioError("Failed to generate random AES key")
        }
        return aesKey
    }

    private func buildPlainAuthenticationBody(
        rsaKey: RSAPublicKey,
        aesKey: Data
    ) throws -> Data {
        guard aesKey.count == kCCKeySizeAES128 else {
            throw VNCProtocolError.ioError("Type 33 AES key must be \(kCCKeySizeAES128) bytes")
        }

        var encError: Unmanaged<CFError>?
        guard let encryptedBlockRef = SecKeyCreateEncryptedData(
            rsaKey.secKey,
            .rsaEncryptionPKCS1,
            aesKey as CFData,
            &encError
        ) else {
            let desc = encError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw VNCProtocolError.ioError("RSA PKCS1v15 encryption failed: \(desc)")
        }
        let encryptedBlock = encryptedBlockRef as Data

        let credentialMaterial = packCredentials(username: username, password: password)
        let encryptedCredentials = try aesECBEncrypt(data: credentialMaterial, key: aesKey)
        guard encryptedCredentials.count == 128 else {
            throw VNCProtocolError.ioError(
                "Type 33 encrypted credential block must be 128 bytes, got \(encryptedCredentials.count)")
        }

        // Plain Type-33 password authentication record:
        // [0:2]    version = 0x0100
        // [2:6]    "RSA1"
        // [6:8]    auth selector = 0x0001
        // [8:136]  AES-ECB encrypted username/password block
        // [136:138] RSA ciphertext length, little-endian UInt16
        // [138:...] RSA-PKCS1v15 encrypted 16-byte AES key
        var authBody = Data(count: 8 + encryptedCredentials.count + 2 + encryptedBlock.count)
        authBody[0] = 0x01; authBody[1] = 0x00 // version
        authBody[2] = 0x52; authBody[3] = 0x53; authBody[4] = 0x41; authBody[5] = 0x31 // "RSA1"
        authBody[6] = 0x00; authBody[7] = 0x01 // selector: RSA plain password auth
        authBody.replaceSubrange(8..<136, with: encryptedCredentials)
        let rsaLen = UInt16(encryptedBlock.count)
        authBody[136] = UInt8(rsaLen & 0xFF)
        authBody[137] = UInt8((rsaLen >> 8) & 0xFF)
        authBody.replaceSubrange(138..<138 + encryptedBlock.count, with: encryptedBlock)
        return authBody
    }

    private func buildSRPAuthenticationBody(rsaKey: RSAPublicKey) throws -> Data {
        let srpRequest = try AppleSRPBuffer.clientInitialRequest(
            username: username,
            options: Self.capabilitiesString
        )
        let encryptedBlock = try rsaEncryptPKCS1(rsaKey: rsaKey, plaintext: srpRequest)

        var authBody = Data(count: 650)
        authBody[0] = 0x01; authBody[1] = 0x00
        authBody[2] = 0x52; authBody[3] = 0x53; authBody[4] = 0x41; authBody[5] = 0x31
        authBody[6] = 0x00; authBody[7] = 0x02
        let rsaLen = UInt16(encryptedBlock.count)
        authBody[8] = UInt8((rsaLen >> 8) & 0xFF)
        authBody[9] = UInt8(rsaLen & 0xFF)
        authBody.replaceSubrange(10..<10 + encryptedBlock.count, with: encryptedBlock)
        return authBody
    }

    private func buildDHAuthenticationBody(rsaKey: RSAPublicKey, aesKey: Data) throws -> Data {
        guard aesKey.count == kCCKeySizeAES128 else {
            throw VNCProtocolError.ioError("Type 33 AES key must be \(kCCKeySizeAES128) bytes")
        }

        let rsaPlaintext: Data
        switch ProcessInfo.processInfo.environment["ROOTSHELL_VNC_TYPE33_DH_INITIAL_PAYLOAD"] {
        case "aes-padded-128":
            var padded = Data(count: 128)
            padded.replaceSubrange(0..<aesKey.count, with: aesKey)
            rsaPlaintext = padded
        case "credentials":
            rsaPlaintext = packCredentials(username: username, password: password)
        case "aes-credentials":
            var payload = aesKey
            payload.append(packCredentials(username: username, password: password))
            rsaPlaintext = payload
        default:
            rsaPlaintext = aesKey
        }

        let encryptedBlock = try rsaEncryptPKCS1(rsaKey: rsaKey, plaintext: rsaPlaintext)

        var authBody = Data(count: 650)
        authBody[0] = 0x01; authBody[1] = 0x00
        authBody[2] = 0x52; authBody[3] = 0x53; authBody[4] = 0x41; authBody[5] = 0x31
        authBody[6] = 0x00; authBody[7] = 0x02
        let rsaLen = UInt16(encryptedBlock.count)
        authBody[8] = UInt8((rsaLen >> 8) & 0xFF)
        authBody[9] = UInt8(rsaLen & 0xFF)
        authBody.replaceSubrange(10..<10 + encryptedBlock.count, with: encryptedBlock)
        return authBody
    }

    private func rsaEncryptPKCS1(rsaKey: RSAPublicKey, plaintext: Data) throws -> Data {
        var encError: Unmanaged<CFError>?
        guard let encryptedBlockRef = SecKeyCreateEncryptedData(
            rsaKey.secKey,
            .rsaEncryptionPKCS1,
            plaintext as CFData,
            &encError
        ) else {
            let desc = encError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw VNCProtocolError.ioError("RSA PKCS1v15 encryption failed: \(desc)")
        }
        return encryptedBlockRef as Data
    }

    // MARK: - Phase 2: DH Key Exchange

    /// Reads and parses server DH params, computes DH keys, builds response.
    /// Returns (sharedSecret, serverNonce, dhResponseData) — the response is NOT sent yet.
    private func parseDHParams(
        connection: any RFBConnection,
        aesKey: Data
    ) async throws -> (Data, Data, Data) {

        // Step 1: Read server DH message
        let dhLen = try await readUInt32(connection: connection)
        log.info("Server DH message length: \(dhLen)")

        let dhBody = try await connection.read(exactly: Int(dhLen))
        log.hexDump("Server DH message header", data: dhBody, maxBytes: 128)

        // Parse the server DH message
        // [0:4]   header / generator as UInt32 (e.g. 00 00 00 02 = generator 2)
        // [4:6]   UInt16 = total DH section size
        // [6:8]   00 00 = reserved
        // [8:10]  UInt16 = DH params size
        // [10:12] UInt16 = generator value again
        // [12]    00 = padding byte
        // [13:525] 512-byte prime
        // [525:1037] 512-byte server DH public key
        // [525:...]  Additional data (nonce, structured fields, capabilities string)
        let primeLen = 512
        let primeOffset = 13
        let serverPubKeyOffset = primeOffset + primeLen
        guard dhBody.count >= serverPubKeyOffset + primeLen else {
            throw VNCProtocolError.authenticationFailed(
                "Mac Auth: DH message too short (\(dhBody.count) bytes): "
                    + dhBody.map { String(format: "%02x", $0) }.joined(separator: " "))
        }

        let generatorU32 = readUInt32FromData(dhBody, offset: 0)
        let dhSectionSize = readUInt16FromData(dhBody, offset: 4)
        let dhParamsSize = readUInt16FromData(dhBody, offset: 8)
        let generatorU16 = readUInt16FromData(dhBody, offset: 10)

        log.debug("DH header: generator32=\(generatorU32), sectionSize=\(dhSectionSize), "
                 + "paramsSize=\(dhParamsSize), generator16=\(generatorU16)")

        let primeData = Data(dhBody[primeOffset..<primeOffset + primeLen])

        let serverPubKeyData = Data(dhBody[serverPubKeyOffset..<serverPubKeyOffset + primeLen])

        // Extract any remaining data after the DH pubkey (nonce, capabilities, etc.)
        let extraDataOffset = serverPubKeyOffset + primeLen
        let extraData = Data(dhBody[extraDataOffset...])
        log.hexDump("DH extra data", data: extraData, maxBytes: 256)

        // Try to find and log the capabilities string in the extra data
        if let capsRange = findCapabilitiesString(in: extraData) {
            let capsStr = String(data: Data(extraData[capsRange]), encoding: .utf8) ?? "<invalid>"
            log.info("Server capabilities: \(capsStr)")
        }

        // Extract nonce from extra data if present
        // The nonce is typically in the structured data before the capabilities string.
        // We'll use whatever extra data we can find as the server nonce.
        let serverNonce: Data
        if extraData.count >= 32 {
            // Use the first 32 bytes of extra data as a nonce seed
            serverNonce = Data(extraData.prefix(32))
        } else {
            serverNonce = extraData
        }
        log.hexDump("Server nonce material", data: serverNonce)

        // Parse big integers
        let generator = generatorU32 > 0 ? BigUInt(generatorU32) : BigUInt(2)
        let prime = BigUInt(primeData)
        let serverPublicKey = BigUInt(serverPubKeyData)

        log.debug("DH prime (\(prime.bitWidth) bits), generator=\(generator)")

        var privateKeyData = Data(count: primeLen)
        let pkResult = privateKeyData.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, primeLen, ptr.baseAddress!)
        }
        guard pkResult == errSecSuccess else {
            throw VNCProtocolError.ioError("Failed to generate DH private key")
        }
        let privateKey = BigUInt(privateKeyData)

        // clientPublicKey = generator^privateKey mod prime
        let clientPublicKey = generator.power(privateKey, modulus: prime)

        // sharedSecret = serverPublicKey^privateKey mod prime
        let sharedSecret = serverPublicKey.power(privateKey, modulus: prime)

        log.debug("Computed DH shared secret (\(sharedSecret.bitWidth) bits)")

        // Serialize client public key, padded to 256 bytes
        var clientPubKeyData = clientPublicKey.serialize()
        if clientPubKeyData.count < primeLen {
            var padded = Data(count: primeLen)
            let offset = primeLen - clientPubKeyData.count
            padded.replaceSubrange(offset..<primeLen, with: clientPubKeyData)
            clientPubKeyData = padded
        } else if clientPubKeyData.count > primeLen {
            clientPubKeyData = Data(clientPubKeyData.suffix(primeLen))
        }

        // Step 3: Build client DH response.
        // Type-33 DH response format (1076-byte body):
        // [01 00 RSA1 00 02] = 8-byte header
        // [UInt16 section_length = 682]
        // [UInt32 inner_length = 678]
        // [UInt16 flags = 0x0200]
        // [512-byte client DH public key]
        // [capabilities string]
        // [AES-encrypted credentials + random padding] = fill to 1076

        let capsData = Data(Self.capabilitiesString.utf8)

        var dhResponse = Data()
        dhResponse.append(contentsOf: [0x01, 0x00]) // version
        dhResponse.append(contentsOf: [0x52, 0x53, 0x41, 0x31]) // "RSA1"
        dhResponse.append(contentsOf: [0x00, 0x02]) // flag: DH+ChaCha mode

        dhResponse.append(contentsOf: [0x02, 0xAA]) // outer section length: 682
        appendUInt32(&dhResponse, 0x0000_02A6)      // inner section length: 678
        dhResponse.append(contentsOf: [0x02, 0x00])
        dhResponse.append(clientPubKeyData)
        dhResponse.append(capsData)

        var credentialMaterial = packCredentials(username: username, password: password)
        credentialMaterial = try aesECBEncrypt(data: credentialMaterial, key: aesKey)

        let targetSize = 1076
        if dhResponse.count + credentialMaterial.count <= targetSize {
            dhResponse.append(credentialMaterial)
        }
        if dhResponse.count < targetSize {
            let paddingCount = targetSize - dhResponse.count
            var padding = Data(count: paddingCount)
            padding.withUnsafeMutableBytes { ptr in
                _ = SecRandomCopyBytes(kSecRandomDefault, paddingCount, ptr.baseAddress!)
            }
            dhResponse.append(padding)
        }

        log.hexDump("Client DH response header", data: dhResponse.prefix(16))
        log.debug("Client DH response total: \(dhResponse.count) bytes")

        // Serialize shared secret, padded to prime length
        var sharedSecretData = sharedSecret.serialize()
        if sharedSecretData.count < primeLen {
            var padded = Data(count: primeLen)
            let offset = primeLen - sharedSecretData.count
            padded.replaceSubrange(offset..<primeLen, with: sharedSecretData)
            sharedSecretData = padded
        }

        log.debug("Client DH response prepared: \(dhResponse.count) bytes")
        return (sharedSecretData, serverNonce, dhResponse)
    }

    // Phase 3 (key confirmation) is handled inline in authenticate()

    // MARK: - Credential packing

    /// Pack credentials: username(64 bytes, null-terminated, random-padded) + password(64 bytes, same)
    private func packCredentials(username: String, password: String) -> Data {
        var creds = Data(count: 128)
        // Fill with random data first
        creds.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, 128, ptr.baseAddress!)
        }

        // Write null-terminated username (max 63 chars)
        let uBytes = Data(username.utf8)
        let uLen = min(uBytes.count, 63)
        creds.replaceSubrange(0..<uLen, with: uBytes.prefix(uLen))
        creds[uLen] = 0

        // Write null-terminated password (max 63 chars)
        let pBytes = Data(password.utf8)
        let pLen = min(pBytes.count, 63)
        creds.replaceSubrange(64..<64 + pLen, with: pBytes.prefix(pLen))
        creds[64 + pLen] = 0

        return creds
    }

    // MARK: - Crypto helpers

    /// AES-ECB encrypt data (for credential encryption). Data length must be a multiple of 16.
    private func aesECBEncrypt(data: Data, key: Data) throws -> Data {
        var outBuffer = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outLength = 0

        let status = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, kCCKeySizeAES128,
                    nil,
                    dataPtr.baseAddress, data.count,
                    &outBuffer, outBuffer.count, &outLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw VNCProtocolError.ioError("AES-ECB encryption failed: \(status)")
        }

        return Data(outBuffer[0..<outLength])
    }

    /// PBKDF2 with HMAC-SHA512, using raw key bytes (not a password string).
    private func pbkdf2HMACSHA512(
        key: Data,
        salt: Data,
        iterations: UInt32,
        keyLength: Int
    ) throws -> Data {
        var derivedKey = Data(count: keyLength)

        let result = derivedKey.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                key.withUnsafeBytes { keyPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        keyPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        key.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw VNCProtocolError.ioError("PBKDF2-SHA512 failed with status \(result)")
        }

        return derivedKey
    }

    private func computeSRPResponse(challenge: AppleSRPServerChallenge) throws -> SRPClientResponse {
        let primeLength = challenge.prime.count
        let N = BigUInt(challenge.prime)
        let g = BigUInt(challenge.generator)
        let B = BigUInt(challenge.serverPublicKey)

        guard N > 0, g > 1, g < N, B % N != 0 else {
            throw VNCProtocolError.authenticationFailed("Mac Auth SRP: invalid server public key")
        }
        guard challenge.iterations <= UInt64(UInt32.max) else {
            throw VNCProtocolError.authenticationFailed(
                "Mac Auth SRP: unsupported PBKDF2 iteration count \(challenge.iterations)")
        }

        let iterations = UInt32(challenge.iterations)
        let xCandidates = try srpXCandidates(salt: challenge.salt, iterations: iterations)
        var selected = xCandidates.first { $0.name == "Apple ScreenSharing SRP KDF (empty username)" }
        if let selectedIndexString = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_TYPE33_SRP_KDF_INDEX"],
           let selectedIndex = Int(selectedIndexString),
           xCandidates.indices.contains(selectedIndex) {
            selected = xCandidates[selectedIndex]
        }

        guard let selected else {
            throw VNCProtocolError.authenticationFailed("Mac Auth SRP: no KDF variant selected")
        }
        let x = selected.value
        log.debug("Mac Auth SRP selected KDF variant: \(selected.name)")

        if ProcessInfo.processInfo.environment["ROOTSHELL_VNC_TYPE33_SRP_VERIFY_B_AS_VERIFIER"] == "1" {
            for candidate in xCandidates {
                if g.power(candidate.value, modulus: N) == B {
                    log.debug("Mac Auth SRP B matched verifier-style candidate: \(candidate.name)")
                    break
                }
            }
        }

        let privateKey = BigUInt(try randomBytes(count: 64))
        let A = g.power(privateKey, modulus: N)
        guard A % N != 0 else {
            throw VNCProtocolError.authenticationFailed("Mac Auth SRP: computed A is zero")
        }

        let paddedN = pad(A: N.serialize(), length: primeLength)
        let paddedG = pad(A: g.serialize(), length: primeLength)
        let paddedA = pad(A: A.serialize(), length: primeLength)
        let paddedB = pad(A: B.serialize(), length: primeLength)

        let k = BigUInt(sha512(paddedN + paddedG))
        let u = BigUInt(sha512(paddedA + paddedB))
        guard u != 0 else {
            throw VNCProtocolError.authenticationFailed("Mac Auth SRP: computed u is zero")
        }

        let gx = g.power(x, modulus: N)
        let base = (B + N - ((k * gx) % N)) % N
        let exponent = privateKey + (u * x)
        let S = base.power(exponent, modulus: N)
        let paddedS = pad(A: S.serialize(), length: primeLength)
        let K = sha512(paddedS)

        let hashN = sha512(paddedN)
        let hashG = sha512(paddedG)
        var xor = Data(count: hashN.count)
        for i in 0..<hashN.count {
            xor[i] = hashN[i] ^ hashG[i]
        }

        let proofUsername: Data
        if ProcessInfo.processInfo.environment["ROOTSHELL_VNC_TYPE33_SRP_PROOF_USERNAME"] == "1" {
            proofUsername = Data(username.utf8)
        } else {
            // This mechanism defines the SRP proof with an empty username.
            proofUsername = Data()
        }
        let userHash = sha512(proofUsername)
        let proof = sha512(xor + userHash + challenge.salt + paddedA + paddedB + K)
        let serverProof = sha512(paddedA + proof + K)
        return SRPClientResponse(
            publicKey: paddedA,
            proof: proof,
            expectedServerProof: serverProof,
            sessionKey: K
        )
    }

    private func srpXCandidates(
        salt: Data,
        iterations: UInt32
    ) throws -> [(name: String, value: BigUInt)] {
        let passwordBytes = Data(password.utf8)
        let usernameBytes = Data(username.utf8)
        var candidates: [(String, Data)] = []

        let userColonPassword = usernameBytes + Data([0x3A]) + passwordBytes
        let colonPassword = Data([0x3A]) + passwordBytes
        let stockUserHash = sha512(userColonPassword)
        let stockNoUserHash = sha512(colonPassword)
        // This SRP profile first derives a 128-byte password with
        // PBKDF2-HMAC-SHA512, then uses it as the SRP password input.
        let appleSRPPassword = try pbkdf2HMACSHA512(
            key: passwordBytes, salt: salt, iterations: iterations, keyLength: 128)
        let saltedPassword64 = try pbkdf2HMACSHA512(
            key: passwordBytes, salt: salt, iterations: iterations, keyLength: 64)
        let saltedUserPassword64 = try pbkdf2HMACSHA512(
            key: userColonPassword, salt: salt, iterations: iterations, keyLength: 64)
        let saltedNoUserPassword64 = try pbkdf2HMACSHA512(
            key: colonPassword, salt: salt, iterations: iterations, keyLength: 64)

        candidates.append(("Apple ScreenSharing SRP KDF", sha512(
            salt + sha512(usernameBytes + Data([0x3A]) + appleSRPPassword))))
        candidates.append(("Apple ScreenSharing SRP KDF (empty username)", sha512(
            salt + sha512(Data([0x3A]) + appleSRPPassword))))
        candidates.append(("pbkdf2(password)", saltedPassword64))
        candidates.append(("pbkdf2(password,128)", appleSRPPassword))
        candidates.append(("pbkdf2(username:password)", saltedUserPassword64))
        candidates.append(("pbkdf2(:password)", saltedNoUserPassword64))
        candidates.append(("pbkdf2(H(username:password))", try pbkdf2HMACSHA512(
            key: stockUserHash, salt: salt, iterations: iterations, keyLength: 64)))
        candidates.append(("pbkdf2(H(:password))", try pbkdf2HMACSHA512(
            key: stockNoUserHash, salt: salt, iterations: iterations, keyLength: 64)))
        candidates.append(("H(salt || H(username:password))", sha512(salt + stockUserHash)))
        candidates.append(("H(salt || H(:password))", sha512(salt + stockNoUserHash)))
        candidates.append(("H(salt || pbkdf2(password))", sha512(salt + saltedPassword64)))
        candidates.append(("H(salt || pbkdf2(password,128))", sha512(salt + appleSRPPassword)))
        candidates.append(("H(salt || H(:pbkdf2(password)))", sha512(
            salt + sha512(Data([0x3A]) + saltedPassword64))))
        candidates.append(("H(salt || H(:pbkdf2(password,128)))", sha512(
            salt + sha512(Data([0x3A]) + appleSRPPassword))))
        candidates.append(("H(salt || H(username:pbkdf2(password)))", sha512(
            salt + sha512(usernameBytes + Data([0x3A]) + saltedPassword64))))
        candidates.append(("H(salt || H(username:pbkdf2(password,128)))", sha512(
            salt + sha512(usernameBytes + Data([0x3A]) + appleSRPPassword))))
        candidates.append(("H(salt || pbkdf2(username:password))", sha512(salt + saltedUserPassword64)))
        candidates.append(("H(salt || pbkdf2(:password))", sha512(salt + saltedNoUserPassword64)))

        return candidates.map { name, bytes in (name, BigUInt(bytes)) }
    }

    private func sha512(_ data: Data) -> Data {
        Data(SHA512.hash(data: data))
    }

    private func appleSRPAESKey(from sessionKey: Data) -> Data {
        Data(SHA256.hash(data: sessionKey).prefix(kCCKeySizeAES128))
    }

    private func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw VNCProtocolError.ioError("Failed to generate \(count) random bytes")
        }
        return data
    }

    private func pad(A data: Data, length: Int) -> Data {
        if data.count >= length {
            return Data(data.suffix(length))
        }
        var padded = Data(count: length - data.count)
        padded.append(data)
        return padded
    }

    // MARK: - Wire helpers

    /// Send data prefixed with a 4-byte big-endian length.
    private func sendLengthPrefixed(connection: any RFBConnection, data: Data) async throws {
        var msg = Data(count: 4)
        let len = UInt32(data.count)
        msg[0] = UInt8((len >> 24) & 0xFF)
        msg[1] = UInt8((len >> 16) & 0xFF)
        msg[2] = UInt8((len >> 8) & 0xFF)
        msg[3] = UInt8(len & 0xFF)
        msg.append(data)
        try await connection.send(msg)
    }

    /// Read a big-endian UInt32 from the connection.
    private func readUInt32(connection: any RFBConnection) async throws -> UInt32 {
        let data = try await connection.read(exactly: 4)
        return UInt32(data[0]) << 24 | UInt32(data[1]) << 16
             | UInt32(data[2]) << 8 | UInt32(data[3])
    }

    /// Append a big-endian UInt32 to a Data buffer.
    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    /// Read a big-endian UInt32 from a Data buffer at the given offset.
    private func readUInt32FromData(_ data: Data, offset: Int) -> UInt32 {
        return UInt32(data[offset]) << 24
             | UInt32(data[offset + 1]) << 16
             | UInt32(data[offset + 2]) << 8
             | UInt32(data[offset + 3])
    }

    /// Read a big-endian UInt16 from a Data buffer at the given offset.
    private func readUInt16FromData(_ data: Data, offset: Int) -> UInt16 {
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    /// Search for a capabilities string in a data buffer.
    /// Returns the range of the string if found, or nil.
    private func findCapabilitiesString(in data: Data) -> Range<Int>? {
        let marker = Data("mda=".utf8)
        guard let startIdx = data.firstRange(of: marker)?.lowerBound else {
            return nil
        }
        // Find the end (null byte or end of data)
        let relativeStart = startIdx - data.startIndex
        var endIdx = relativeStart
        while endIdx < data.count {
            if data[data.startIndex + endIdx] == 0x00 {
                break
            }
            endIdx += 1
        }
        return relativeStart..<endIdx
    }
}
