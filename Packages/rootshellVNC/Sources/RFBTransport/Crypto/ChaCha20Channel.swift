import Foundation
import CryptoKit
import RFBProtocol

/// ChaCha20-Poly1305 channel encryption for post-SRP communication.
///
/// Newer versions of macOS Apple Remote Desktop use ChaCha20-Poly1305
/// instead of AES-CBC for channel encryption after SRP authentication.
///
/// This is a simple wrapper around CryptoKit's ChaChaPoly implementation.
public struct ChaCha20Channel: Sendable {

    private let symmetricKey: SymmetricKey
    private let log = VNCLogger(category: "ChaCha20")

    // MARK: - Init

    /// Create a ChaCha20-Poly1305 channel with the given key.
    ///
    /// - Parameter key: The 32-byte symmetric key derived from the SRP shared secret.
    /// - Throws: ``VNCProtocolError`` if the key is not 32 bytes.
    public init(key: Data) throws {
        guard key.count == 32 else {
            throw VNCProtocolError.ioError(
                "ChaCha20-Poly1305 requires a 32-byte key, got \(key.count) bytes")
        }
        self.symmetricKey = SymmetricKey(data: key)
        log.info("ChaCha20-Poly1305 channel initialized")
    }

    // MARK: - Seal / Open

    /// Encrypt plaintext using ChaCha20-Poly1305.
    ///
    /// - Parameters:
    ///   - plaintext: The data to encrypt.
    ///   - nonce: Optional 12-byte nonce. If nil, a random nonce is generated.
    /// - Returns: The combined output: [nonce (12 bytes)] [ciphertext] [tag (16 bytes)].
    /// - Throws: ``VNCProtocolError`` on encryption failure.
    public func seal(_ plaintext: Data, nonce: Data? = nil) throws -> Data {
        let chachaNonce: ChaChaPoly.Nonce
        if let nonceData = nonce {
            guard nonceData.count == 12 else {
                throw VNCProtocolError.ioError("ChaCha20 nonce must be 12 bytes, got \(nonceData.count)")
            }
            chachaNonce = try ChaChaPoly.Nonce(data: nonceData)
        } else {
            chachaNonce = ChaChaPoly.Nonce()
        }

        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: chachaNonce)
        } catch {
            throw VNCProtocolError.ioError("ChaCha20-Poly1305 seal failed: \(error.localizedDescription)")
        }

        // Return combined: nonce + ciphertext + tag
        return sealedBox.combined
    }

    /// Decrypt ciphertext using ChaCha20-Poly1305.
    ///
    /// - Parameters:
    ///   - ciphertext: The combined data: [nonce (12 bytes)] [ciphertext] [tag (16 bytes)].
    ///     If `nonce` is provided separately, `ciphertext` is just [ciphertext] [tag (16 bytes)].
    ///   - nonce: Optional 12-byte nonce. If nil, the nonce is extracted from the first 12 bytes
    ///     of `ciphertext` (combined format).
    /// - Returns: The decrypted plaintext.
    /// - Throws: ``VNCProtocolError`` on decryption or authentication failure.
    public func open(_ ciphertext: Data, nonce: Data? = nil) throws -> Data {
        let sealedBox: ChaChaPoly.SealedBox
        do {
            if let nonceData = nonce {
                guard nonceData.count == 12 else {
                    throw VNCProtocolError.ioError("ChaCha20 nonce must be 12 bytes, got \(nonceData.count)")
                }
                guard ciphertext.count >= 16 else {
                    throw VNCProtocolError.ioError("ChaCha20 ciphertext too short for tag")
                }
                let chachaNonce = try ChaChaPoly.Nonce(data: nonceData)
                let ctLen = ciphertext.count - 16
                let ct = ciphertext.prefix(ctLen)
                let tag = ciphertext.suffix(16)
                sealedBox = try ChaChaPoly.SealedBox(
                    nonce: chachaNonce,
                    ciphertext: ct,
                    tag: tag
                )
            } else {
                // Combined format: nonce (12) + ciphertext + tag (16)
                sealedBox = try ChaChaPoly.SealedBox(combined: ciphertext)
            }
        } catch let error as VNCProtocolError {
            throw error
        } catch {
            throw VNCProtocolError.ioError("ChaCha20-Poly1305 failed to parse sealed box: \(error.localizedDescription)")
        }

        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(sealedBox, using: symmetricKey)
        } catch {
            throw VNCProtocolError.ioError("ChaCha20-Poly1305 open failed: \(error.localizedDescription)")
        }

        return plaintext
    }
}
