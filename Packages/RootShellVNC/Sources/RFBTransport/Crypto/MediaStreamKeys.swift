import Foundation
import CryptoKit
import RFBProtocol

/// Derives the 6 per-stream keys needed for encrypted UDP HEVC streams.
///
/// From the master key (obtained during SRP/DH authentication) and a stream ID,
/// this derives separate encryption and authentication keys for video, audio,
/// and control sub-channels using SHA-512 with concatenated labels.
///
/// Key derivation:
/// For each sub-channel and purpose, compute:
///   key = SHA512(masterKey || streamID_bytes || label)
/// where label is a unique ASCII string identifying the key's purpose,
/// and the result is truncated to the needed key length.
public struct MediaStreamKeys: Sendable {

    /// The encryption key for video data (32 bytes).
    public let videoEncryptionKey: Data

    /// The authentication (HMAC) key for video data (32 bytes).
    public let videoAuthKey: Data

    /// The encryption key for audio data (32 bytes).
    public let audioEncryptionKey: Data

    /// The authentication (HMAC) key for audio data (32 bytes).
    public let audioAuthKey: Data

    /// The encryption key for control channel data (32 bytes).
    public let controlEncryptionKey: Data

    /// The authentication (HMAC) key for control channel data (32 bytes).
    public let controlAuthKey: Data

    // MARK: - Init

    /// Derive all 6 stream keys from a master key and stream identifier.
    ///
    /// - Parameters:
    ///   - masterKey: The master key from the authentication phase.
    ///   - streamID: The stream identifier from the server's media stream offer.
    public init(masterKey: Data, streamID: UInt32) {
        let streamIDBytes = Self.uint32ToBytes(streamID)

        self.videoEncryptionKey = Self.deriveKey(
            masterKey: masterKey, streamID: streamIDBytes, label: "video-encryption"
        )
        self.videoAuthKey = Self.deriveKey(
            masterKey: masterKey, streamID: streamIDBytes, label: "video-auth"
        )
        self.audioEncryptionKey = Self.deriveKey(
            masterKey: masterKey, streamID: streamIDBytes, label: "audio-encryption"
        )
        self.audioAuthKey = Self.deriveKey(
            masterKey: masterKey, streamID: streamIDBytes, label: "audio-auth"
        )
        self.controlEncryptionKey = Self.deriveKey(
            masterKey: masterKey, streamID: streamIDBytes, label: "control-encryption"
        )
        self.controlAuthKey = Self.deriveKey(
            masterKey: masterKey, streamID: streamIDBytes, label: "control-auth"
        )
    }

    // MARK: - Private

    /// Derive a single 32-byte key using SHA-512.
    ///
    /// Formula: truncate(SHA512(masterKey || streamID || label), 32)
    private static func deriveKey(masterKey: Data, streamID: Data, label: String) -> Data {
        var input = Data()
        input.append(masterKey)
        input.append(streamID)
        input.append(Data(label.utf8))

        let hash = SHA512.hash(data: input)
        // Truncate to 32 bytes (256 bits) for use as an AES-256 or ChaCha20 key
        return Data(hash.prefix(32))
    }

    /// Convert a UInt32 to 4-byte big-endian Data.
    private static func uint32ToBytes(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}
