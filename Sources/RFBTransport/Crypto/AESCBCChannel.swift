import Foundation
import CommonCrypto
import RFBProtocol

/// Implements the 4-cryptor AES-CBC encryption layer for Apple VNC.
///
/// After receiving the EncryptionInfo pseudo-encoding (-267), the connection
/// switches to encrypted mode using 4 AES-128-CBC cryptors:
/// - sendCBC: encrypts outgoing payload with CBC
/// - recvCBC: decrypts incoming payload with CBC
/// - sendECB: encrypts random IVs for outgoing messages
/// - recvECB: decrypts IVs for incoming messages
///
/// Encrypted frame format:
/// 1. Generate a random 16-byte IV
/// 2. ECB-encrypt the IV to produce the encrypted IV
/// 3. CBC-encrypt the payload using the original IV
/// 4. Wire format: [encrypted IV (16 bytes)] [CBC ciphertext]
///
/// Decryption:
/// 1. ECB-decrypt the first 16 bytes to recover the IV
/// 2. CBC-decrypt the remaining bytes using that IV
///
/// Thread safety is provided by NSLock since CCCryptor is not thread-safe.
public final class AESCBCChannel: @unchecked Sendable {

    // MARK: - Properties

    private var sendCBCRef: CCCryptorRef?
    private var recvCBCRef: CCCryptorRef?
    private var sendECBRef: CCCryptorRef?
    private var recvECBRef: CCCryptorRef?

    private let sendKey: Data
    private let recvKey: Data
    private let lock = NSLock()
    private let log = VNCLogger(category: "AESCBCChannel")

    // MARK: - Init

    /// Create an AES-CBC channel with separate send and receive keys.
    ///
    /// - Parameters:
    ///   - sendKey: The 16-byte AES key for encrypting outgoing data.
    ///   - recvKey: The 16-byte AES key for decrypting incoming data.
    /// - Throws: ``VNCProtocolError`` if the cryptors cannot be created.
    public init(sendKey: Data, recvKey: Data) throws {
        guard sendKey.count == kCCKeySizeAES128 else {
            throw VNCProtocolError.ioError("AES send key must be \(kCCKeySizeAES128) bytes, got \(sendKey.count)")
        }
        guard recvKey.count == kCCKeySizeAES128 else {
            throw VNCProtocolError.ioError("AES recv key must be \(kCCKeySizeAES128) bytes, got \(recvKey.count)")
        }

        self.sendKey = sendKey
        self.recvKey = recvKey

        // Create the four cryptors
        self.sendECBRef = try Self.createCryptor(
            operation: kCCEncrypt,
            mode: kCCModeECB,
            key: sendKey
        )
        self.recvECBRef = try Self.createCryptor(
            operation: kCCDecrypt,
            mode: kCCModeECB,
            key: recvKey
        )
        // CBC cryptors start with a zero IV; we reset the IV per-message
        self.sendCBCRef = try Self.createCryptor(
            operation: kCCEncrypt,
            mode: kCCModeCBC,
            key: sendKey
        )
        self.recvCBCRef = try Self.createCryptor(
            operation: kCCDecrypt,
            mode: kCCModeCBC,
            key: recvKey
        )

        log.info("AES-CBC channel initialized")
    }

    deinit {
        if let ref = sendCBCRef { CCCryptorRelease(ref) }
        if let ref = recvCBCRef { CCCryptorRelease(ref) }
        if let ref = sendECBRef { CCCryptorRelease(ref) }
        if let ref = recvECBRef { CCCryptorRelease(ref) }
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt plaintext for sending.
    ///
    /// - Parameter plaintext: The data to encrypt. Will be PKCS7-padded to a block boundary.
    /// - Returns: The encrypted data: [ECB-encrypted IV (16 bytes)] [CBC ciphertext].
    /// - Throws: ``VNCProtocolError`` on encryption failure.
    public func encrypt(_ plaintext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        // Generate random 16-byte IV
        var iv = Data(count: kCCBlockSizeAES128)
        let result = iv.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, kCCBlockSizeAES128, ptr.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw VNCProtocolError.ioError("Failed to generate random IV")
        }

        // ECB-encrypt the IV
        let encryptedIV = try ecbProcess(sendECBRef!, data: iv)

        // Recreate CBC cryptor with the new IV
        if let ref = sendCBCRef {
            CCCryptorRelease(ref)
        }
        sendCBCRef = try Self.createCryptor(
            operation: kCCEncrypt,
            mode: kCCModeCBC,
            key: sendKey,
            iv: iv
        )

        // CBC-encrypt the plaintext
        let ciphertext = try cbcProcess(sendCBCRef!, data: plaintext)

        var output = Data()
        output.append(encryptedIV)
        output.append(ciphertext)

        return output
    }

    /// Decrypt incoming ciphertext.
    ///
    /// - Parameter ciphertext: The encrypted data: [ECB-encrypted IV (16 bytes)] [CBC ciphertext].
    /// - Returns: The decrypted plaintext.
    /// - Throws: ``VNCProtocolError`` on decryption failure.
    public func decrypt(_ ciphertext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard ciphertext.count > kCCBlockSizeAES128 else {
            throw VNCProtocolError.ioError(
                "AES-CBC ciphertext too short: need at least \(kCCBlockSizeAES128 + 1) bytes, got \(ciphertext.count)")
        }
        guard ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw VNCProtocolError.ioError(
                "AES-CBC ciphertext length must be block aligned, got \(ciphertext.count)")
        }

        // Extract and ECB-decrypt the IV
        let encryptedIV = ciphertext.prefix(kCCBlockSizeAES128)
        let iv = try ecbProcess(recvECBRef!, data: Data(encryptedIV))

        // Recreate CBC cryptor with the recovered IV
        if let ref = recvCBCRef {
            CCCryptorRelease(ref)
        }
        recvCBCRef = try Self.createCryptor(
            operation: kCCDecrypt,
            mode: kCCModeCBC,
            key: recvKey,
            iv: iv
        )

        // CBC-decrypt the payload
        let payload = ciphertext.suffix(from: ciphertext.startIndex + kCCBlockSizeAES128)
        let plaintext = try cbcProcess(recvCBCRef!, data: Data(payload))

        return plaintext
    }

    /// Decrypt an incoming AES-CBC frame without PKCS#7 padding removal.
    ///
    /// Apple's media TCP fallback can carry block-aligned stream data rather
    /// than discrete padded RFB control records. The wire prefix is still the
    /// ECB-encrypted IV followed by CBC ciphertext.
    public func decryptNoPadding(_ ciphertext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard ciphertext.count > kCCBlockSizeAES128 else {
            throw VNCProtocolError.ioError(
                "AES-CBC ciphertext too short: need at least \(kCCBlockSizeAES128 + 1) bytes, got \(ciphertext.count)")
        }
        guard ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw VNCProtocolError.ioError(
                "AES-CBC ciphertext length must be block aligned, got \(ciphertext.count)")
        }

        let encryptedIV = ciphertext.prefix(kCCBlockSizeAES128)
        let iv = try ecbProcess(recvECBRef!, data: Data(encryptedIV))
        let payload = ciphertext.suffix(from: ciphertext.startIndex + kCCBlockSizeAES128)
        return try Self.cbcNoPaddingDecrypt(data: Data(payload), key: recvKey, iv: iv)
    }

    /// Decrypt one AES-ECB block with the receive key.
    ///
    /// Apple uses this to unwrap the media-stream key and IV carried in the
    /// `0x44f` encryption-info rectangle before switching to ComCryption.
    public func decryptECBBlock(_ block: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard block.count == kCCBlockSizeAES128 else {
            throw VNCProtocolError.ioError("AES ECB block must be 16 bytes, got \(block.count)")
        }

        return try ecbProcess(recvECBRef!, data: block)
    }

    // MARK: - Private

    /// Create a CCCryptor with the specified parameters.
    /// Uses ccNoPadding for ECB (block-aligned) and ccPKCS7Padding for CBC.
    private static func createCryptor(
        operation: Int,
        mode: Int,
        key: Data,
        iv: Data? = nil
    ) throws -> CCCryptorRef {
        var cryptorRef: CCCryptorRef?
        let ivBytes: [UInt8]? = iv.map { [UInt8]($0) }
        // ECB operates on exact blocks; CBC uses PKCS7 padding for variable-length data
        let padding = (mode == kCCModeECB) ? CCPadding(ccNoPadding) : CCPadding(ccPKCS7Padding)

        let status = key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
            if let ivBytes = ivBytes {
                return ivBytes.withUnsafeBufferPointer { ivPtr in
                    CCCryptorCreateWithMode(
                        CCOperation(operation),
                        CCMode(mode),
                        CCAlgorithm(kCCAlgorithmAES),
                        padding,
                        ivPtr.baseAddress,
                        keyPtr.baseAddress,
                        kCCKeySizeAES128,
                        nil, 0, 0, // tweak, tweakLength, numRounds
                        CCModeOptions(0),
                        &cryptorRef
                    )
                }
            } else {
                return CCCryptorCreateWithMode(
                    CCOperation(operation),
                    CCMode(mode),
                    CCAlgorithm(kCCAlgorithmAES),
                    padding,
                    nil,
                    keyPtr.baseAddress,
                    kCCKeySizeAES128,
                    nil, 0, 0,
                    CCModeOptions(0),
                    &cryptorRef
                )
            }
        }

        guard status == kCCSuccess, let ref = cryptorRef else {
            throw VNCProtocolError.ioError("Failed to create AES cryptor: status \(status)")
        }

        return ref
    }

    private static func cbcNoPaddingDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: data.count)
        var outLength = 0

        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                data.withUnsafeBytes { dataPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0),
                        keyPtr.baseAddress,
                        kCCKeySizeAES128,
                        ivPtr.baseAddress,
                        dataPtr.baseAddress,
                        data.count,
                        &output,
                        output.count,
                        &outLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw VNCProtocolError.ioError("AES-CBC no-padding decrypt failed: \(status)")
        }

        return Data(output.prefix(outLength))
    }

    /// Process exactly one block through an ECB cryptor.
    /// Uses CCCrypt (one-shot) instead of stateful CCCryptorUpdate to avoid
    /// accumulated state issues across calls.
    private func ecbProcess(_ cryptor: CCCryptorRef, data: Data) throws -> Data {
        // Reset the cryptor so it doesn't carry state from prior calls
        CCCryptorReset(cryptor, nil)

        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128 + kCCBlockSizeAES128)
        var outLength = 0

        let status = data.withUnsafeBytes { dataPtr in
            CCCryptorUpdate(
                cryptor,
                dataPtr.baseAddress,
                data.count,
                &output,
                output.count,
                &outLength
            )
        }

        guard status == kCCSuccess else {
            throw VNCProtocolError.ioError("AES ECB process failed: status \(status)")
        }

        return Data(output[0..<kCCBlockSizeAES128])
    }

    /// Process data through a freshly-initialized CBC cryptor.
    /// The CBC cryptor is recreated per-message with the correct IV,
    /// so we use CCCryptorUpdate + CCCryptorFinal as a single-use pass.
    private func cbcProcess(_ cryptor: CCCryptorRef, data: Data) throws -> Data {
        // Allocate enough for data + one block of padding
        let maxOutput = data.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: maxOutput)
        var updateLength = 0

        let updateStatus = data.withUnsafeBytes { dataPtr in
            CCCryptorUpdate(
                cryptor,
                dataPtr.baseAddress,
                data.count,
                &output,
                maxOutput,
                &updateLength
            )
        }

        guard updateStatus == kCCSuccess else {
            throw VNCProtocolError.ioError("AES CBC update failed: status \(updateStatus)")
        }

        var finalLength = 0
        let finalStatus = output.withUnsafeMutableBufferPointer { bufferPtr in
            let finalPtr = bufferPtr.baseAddress!.advanced(by: updateLength)
            return CCCryptorFinal(
                cryptor,
                finalPtr,
                maxOutput - updateLength,
                &finalLength
            )
        }

        guard finalStatus == kCCSuccess else {
            throw VNCProtocolError.ioError("AES CBC final failed: status \(finalStatus)")
        }

        let totalLength = updateLength + finalLength
        return Data(output[0..<totalLength])
    }
}
