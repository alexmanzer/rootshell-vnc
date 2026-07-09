import Foundation
import CommonCrypto
import CryptoKit
import BigInt
import RFBProtocol

/// Type 35 Apple SRP (Secure Remote Password) authentication.
///
/// Implements SRP-6a per RFC 5054, adapted for Apple's VNC variant:
/// - 4096-bit group parameters (N, g from RFC 5054 appendix A)
/// - SHA-512 for all hashing
/// - PBKDF2-HMAC-SHA512 for password hashing (Apple extension)
/// - TLV binary format for message framing
/// - RSA encryption of the client proof
///
/// Protocol flow:
/// 1. Server -> Client: TLV with B (server public key), salt, g, N, RSA public key, iterations, PBKDF key length
/// 2. Client generates random private value (a), computes A = g^a mod N
/// 3. u = SHA512(A || B)
/// 4. x = PBKDF2(password, salt, iterations, keyLength) then hashed with SHA-512
/// 5. S = (B - k*g^x)^(a + u*x) mod N, where k = SHA512(N || g)
/// 6. K = SHA512(S)
/// 7. M1 = SHA512(SHA512(N) XOR SHA512(g) || SHA512(username) || salt || A || B || K)
/// 8. Client -> Server: TLV with A and M1 (RSA-encrypted)
/// 9. Server -> Client: TLV with M2
/// 10. Verify M2 = SHA512(A || M1 || K)
public struct SRPAuthenticator: Authenticator, Sendable {

    private let username: String
    private let password: String
    private let log = VNCLogger(category: "SRPAuth")

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public func authenticate(connection: TCPConnection) async throws -> AuthenticationResult {
        log.info("Starting Apple SRP authentication (Type 35)")

        // Step 1: Read server's TLV message length and data
        let serverMsgLenData = try await connection.read(exactly: 4)
        let serverMsgLen = Int(Self.readBigEndianUInt32(serverMsgLenData))

        let serverTLVData = try await connection.read(exactly: serverMsgLen)
        let serverTLV = try SRPBinaryBuffer.parse(data: serverTLVData)

        log.debug("Received server SRP TLV with \(serverTLV.count) entries")

        // Extract server parameters
        guard let saltData = serverTLV[SRPBinaryBuffer.typeSalt] else {
            throw VNCProtocolError.authenticationFailed("SRP: missing salt")
        }
        guard let serverPubKeyData = serverTLV[SRPBinaryBuffer.typePublicKey] else {
            throw VNCProtocolError.authenticationFailed("SRP: missing server public key (B)")
        }
        guard let generatorData = serverTLV[SRPBinaryBuffer.typeGenerator] else {
            throw VNCProtocolError.authenticationFailed("SRP: missing generator (g)")
        }
        guard let primeData = serverTLV[SRPBinaryBuffer.typePrime] else {
            throw VNCProtocolError.authenticationFailed("SRP: missing prime (N)")
        }
        guard let rsaKeyData = serverTLV[SRPBinaryBuffer.typeRSAKey] else {
            throw VNCProtocolError.authenticationFailed("SRP: missing RSA public key")
        }

        // Parse iterations and PBKDF key length (with defaults)
        let iterations: UInt32
        if let iterData = serverTLV[SRPBinaryBuffer.typeIterations], iterData.count >= 4 {
            iterations = SRPBinaryBuffer.readUInt32(iterData)
        } else {
            iterations = 4096
        }

        let pbkdfKeyLength: Int
        if let lenData = serverTLV[SRPBinaryBuffer.typePBKDFLen], lenData.count >= 4 {
            pbkdfKeyLength = Int(SRPBinaryBuffer.readUInt32(lenData))
        } else {
            pbkdfKeyLength = 32
        }

        // Parse big numbers
        let N = BigUInt(primeData)
        let g = BigUInt(generatorData)
        let B = BigUInt(serverPubKeyData)

        guard B % N != 0 else {
            throw VNCProtocolError.authenticationFailed("SRP: server public key B is 0 mod N")
        }

        log.debug("SRP parameters: N=\(N.bitWidth) bits, g=\(g), iterations=\(iterations), pbkdfKeyLen=\(pbkdfKeyLength)")

        // Step 2: Generate random private value (a) and compute A = g^a mod N
        let a = BigUInt.randomInteger(withMaximumWidth: 256)
        let A = g.power(a, modulus: N)

        guard A % N != 0 else {
            throw VNCProtocolError.authenticationFailed("SRP: computed A is 0 mod N")
        }

        // Step 3: u = SHA512(pad(A) || pad(B))
        let paddedA = padToLength(A.serialize(), length: primeData.count)
        let paddedB = padToLength(B.serialize(), length: primeData.count)
        var uInput = Data()
        uInput.append(paddedA)
        uInput.append(paddedB)
        let uHash = sha512(uInput)
        let u = BigUInt(uHash)

        guard u != 0 else {
            throw VNCProtocolError.authenticationFailed("SRP: computed u is zero")
        }

        // Step 4: x = SHA512(PBKDF2(password, salt, iterations, keyLength))
        let pbkdfResult = try pbkdf2HMACSHA512(
            password: password,
            salt: saltData,
            iterations: iterations,
            keyLength: pbkdfKeyLength
        )
        let xHash = sha512(pbkdfResult)
        let x = BigUInt(xHash)

        // Step 5: k = SHA512(pad(N) || pad(g))
        let paddedN = primeData
        let paddedG = padToLength(g.serialize(), length: primeData.count)
        var kInput = Data()
        kInput.append(paddedN)
        kInput.append(paddedG)
        let kHash = sha512(kInput)
        let k = BigUInt(kHash)

        // S = (B - k * g^x mod N)^(a + u*x) mod N
        let gx = g.power(x, modulus: N)
        let kgx = (k * gx) % N

        // Handle potential underflow: if B < kgx, add N
        let diff: BigUInt
        if B >= kgx {
            let subtraction = B.subtracting(kgx)
            diff = subtraction % N
        } else {
            let sum: BigUInt = B + N
            let wrapped: BigUInt = sum - kgx
            diff = wrapped % N
        }

        let exp = (a + u * x)
        let S = diff.power(exp, modulus: N)

        // Step 6: K = SHA512(pad(S))
        let paddedS = padToLength(S.serialize(), length: primeData.count)
        let K = sha512(paddedS)

        log.debug("Computed session key K")

        // Step 7: M1 = SHA512(SHA512(N) XOR SHA512(g) || SHA512(username) || salt || A || B || K)
        let hashN = sha512(paddedN)
        let hashG = sha512(paddedG)

        // XOR the two hashes
        var hashNxorG = Data(count: hashN.count)
        for i in 0..<hashN.count {
            hashNxorG[i] = hashN[i] ^ hashG[i]
        }

        let hashUsername = sha512(Data(username.utf8))

        var m1Input = Data()
        m1Input.append(hashNxorG)
        m1Input.append(hashUsername)
        m1Input.append(saltData)
        m1Input.append(paddedA)
        m1Input.append(paddedB)
        m1Input.append(K)
        let M1 = sha512(m1Input)

        log.debug("Computed client proof M1")

        // Step 8: Build client TLV and RSA-encrypt
        let clientTLV: [UInt8: Data] = [
            SRPBinaryBuffer.typePublicKey: paddedA,
            SRPBinaryBuffer.typeProof: M1,
        ]
        let clientTLVData = SRPBinaryBuffer.serialize(entries: clientTLV)

        let rsaKey = try RSAPublicKey(derData: rsaKeyData)
        let encryptedPayload = try rsaKey.encrypt(clientTLVData)

        // Send length-prefixed encrypted payload
        var sendData = Data()
        let payloadLen = UInt32(encryptedPayload.count)
        sendData.append(UInt8((payloadLen >> 24) & 0xFF))
        sendData.append(UInt8((payloadLen >> 16) & 0xFF))
        sendData.append(UInt8((payloadLen >> 8) & 0xFF))
        sendData.append(UInt8(payloadLen & 0xFF))
        sendData.append(encryptedPayload)

        try await connection.send(sendData)
        log.info("Sent SRP client proof (\(sendData.count) bytes)")

        // Step 9: Read server's M2
        let serverResponseLenData = try await connection.read(exactly: 4)
        let serverResponseLen = Int(Self.readBigEndianUInt32(serverResponseLenData))

        let serverResponseData = try await connection.read(exactly: serverResponseLen)
        let serverResponseTLV = try SRPBinaryBuffer.parse(data: serverResponseData)

        guard let M2 = serverResponseTLV[SRPBinaryBuffer.typeProof] else {
            throw VNCProtocolError.authenticationFailed("SRP: server did not send M2 proof")
        }

        // Step 10: Verify M2 = SHA512(pad(A) || M1 || K)
        var m2Input = Data()
        m2Input.append(paddedA)
        m2Input.append(M1)
        m2Input.append(K)
        let expectedM2 = sha512(m2Input)

        guard M2 == expectedM2 else {
            throw VNCProtocolError.authenticationFailed("SRP: server proof M2 does not match")
        }

        log.info("SRP authentication succeeded")
        return AuthenticationResult()
    }

    // MARK: - Cryptographic helpers

    /// Compute SHA-512 hash.
    private func sha512(_ data: Data) -> Data {
        let digest = SHA512.hash(data: data)
        return Data(digest)
    }

    private static func readBigEndianUInt32(_ data: Data) -> UInt32 {
        guard data.count >= 4 else { return 0 }
        let start = data.startIndex
        let b0 = UInt32(data[start]) << 24
        let b1 = UInt32(data[start + 1]) << 16
        let b2 = UInt32(data[start + 2]) << 8
        let b3 = UInt32(data[start + 3])
        return b0 | b1 | b2 | b3
    }

    /// PBKDF2 with HMAC-SHA512.
    private func pbkdf2HMACSHA512(
        password: String,
        salt: Data,
        iterations: UInt32,
        keyLength: Int
    ) throws -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: keyLength)

        let result = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            salt.withUnsafeBytes { saltPtr in
                passwordData.withUnsafeBytes { passwordPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        iterations,
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw VNCProtocolError.ioError("PBKDF2 failed with status \(result)")
        }

        return derivedKey
    }

    /// Pad big-endian big number data to a specific length with leading zeros.
    private func padToLength(_ data: Data, length: Int) -> Data {
        if data.count >= length {
            return data.suffix(length)
        }
        var padded = Data(count: length - data.count)
        padded.append(data)
        return padded
    }
}
