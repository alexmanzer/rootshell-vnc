import Foundation
import Security
import RFBProtocol

/// Wrapper around Security.framework for RSA public key operations.
///
/// Parses DER-encoded RSA public keys from the server and encrypts data
/// using RSA-OAEP with SHA-1 (the scheme used by Apple VNC).
public struct RSAPublicKey: @unchecked Sendable {

    /// The underlying Security framework key. Exposed for callers
    /// that need a different padding scheme (e.g. PKCS1v15 for Type 33).
    public let secKey: SecKey

    // MARK: - Init

    /// Create an RSA public key from DER-encoded data.
    ///
    /// - Parameter derData: The DER-encoded RSA public key bytes from the server's TLV.
    /// - Throws: ``VNCProtocolError`` if the key data cannot be parsed.
    public init(derData: Data) throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, &error) else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw VNCProtocolError.ioError("Failed to parse RSA public key: \(desc)")
        }

        self.secKey = key
    }

    // MARK: - Encryption

    /// Encrypt plaintext using RSA-OAEP with SHA-1 padding.
    ///
    /// - Parameter plaintext: The data to encrypt. Must be smaller than the key size minus OAEP overhead.
    /// - Returns: The RSA-encrypted ciphertext.
    /// - Throws: ``VNCProtocolError`` if encryption fails.
    public func encrypt(_ plaintext: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionOAEPSHA1,
            plaintext as CFData,
            &error
        ) else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw VNCProtocolError.ioError("RSA encryption failed: \(desc)")
        }

        return ciphertext as Data
    }

    // MARK: - Key info

    /// The block size of the RSA key in bytes (equal to the key size for RSA).
    public var blockSize: Int {
        SecKeyGetBlockSize(secKey)
    }
}
