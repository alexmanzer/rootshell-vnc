import Foundation

/// Curtain mode — Apple's private "session visibility" command. Hiding the
/// session moves the remote Mac off its console so the physical display shows
/// a lock screen with an optional note, while this viewer keeps controlling it.
///
/// Apple's Screen Sharing client sends one message for both directions and
/// carries the note only when hiding:
///
///     0  UInt8   message type (12)
///     1  UInt8   padding
///     2  UInt16  visible: 0 hides the session (curtain on), 1 restores it
///     4  UInt16  message length
///     6  [UInt8] message text, UTF-8, no NUL terminator
///
/// The server reports the resulting state in DisplayInfo2's screen flags rather
/// than replying, so there is no matching server message type to parse.
enum AppleCurtainProtocol {
    static let sessionVisibilityMessageType: UInt8 = 12

    /// Apple's server rejects the whole command past this many message bytes,
    /// so an over-long note is trimmed rather than allowed to fail the toggle.
    static let maximumMessageByteCount = 512

    static func sessionVisibilityMessage(
        visible: Bool,
        message: String
    ) -> Data {
        let text = clampedMessageBytes(message)
        var data = Data(capacity: 6 + text.count)
        data.append(sessionVisibilityMessageType)
        data.append(0)
        data.append(0)
        data.append(visible ? 1 : 0)
        data.append(UInt8(truncatingIfNeeded: text.count >> 8))
        data.append(UInt8(truncatingIfNeeded: text.count))
        data.append(text)
        return data
    }

    /// Trim to the server's limit on a `Character` boundary. Cutting the raw
    /// UTF-8 instead could split a grapheme and leave the remote screen showing
    /// a replacement character.
    static func clampedMessageBytes(_ message: String) -> Data {
        let full = Data(message.utf8)
        guard full.count > maximumMessageByteCount else { return full }

        var clamped = Data(capacity: maximumMessageByteCount)
        for character in message {
            let encoded = Data(String(character).utf8)
            guard clamped.count + encoded.count <= maximumMessageByteCount else {
                break
            }
            clamped.append(encoded)
        }
        return clamped
    }
}
