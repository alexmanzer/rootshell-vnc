import Foundation

/// Public wire representation of the media-control information Apple places in
/// the standard RTP header-extension slot.
///
/// Unlike RFC 8285 extensions, the first two bytes are not an opaque profile
/// identifier. AVConference uses them as a version/status byte and a flags/LTR
/// byte. The following big-endian word count is still the ordinary RTP
/// extension length.
struct AppleMediaRTPMediaControlInfo: Equatable {
    let version: UInt8
    let cameraStatus: UInt8
    let ltrBits: UInt8
    let ltrTimestamp: UInt32?
    let totalPacketsPerFrame: UInt16?
    let frameSequenceNumber: UInt16?
}

/// Parse Apple's media-control RTP extension without depending on
/// AVConference or any other private framework.
func appleMediaRTPMediaControlInfo(
    _ packet: Data
) -> AppleMediaRTPMediaControlInfo? {
    let minimumRTPHeaderLength = 12
    guard packet.count >= minimumRTPHeaderLength else { return nil }
    let base = packet.startIndex
    let firstByte = packet[base]
    guard firstByte >> 6 == 2,
          firstByte & 0x10 != 0 else { return nil }

    let csrcBytes = Int(firstByte & 0x0f) * 4
    let extensionOffset = base + minimumRTPHeaderLength + csrcBytes
    guard extensionOffset + 4 <= packet.endIndex else { return nil }

    let statusAndVersion = packet[extensionOffset]
    let version = statusAndVersion >> 6
    // AVConference's validator accepts the three versions used by this
    // structure. Reject zero so an unrelated extension cannot be mistaken for
    // media control merely because its flags happen to line up.
    guard (1...3).contains(version) else { return nil }

    let flagsAndLTRBits = packet[extensionOffset + 1]
    let extensionWordCount = Int(
        UInt16(packet[extensionOffset + 2]) << 8
            | UInt16(packet[extensionOffset + 3]))
    let extensionEnd = extensionOffset + 4 + extensionWordCount * 4
    guard extensionEnd <= packet.endIndex else { return nil }

    let frameExtensionPresent: UInt8 = 0x01
    let ltrTimestampPresent: UInt8 = 0x02
    var cursor = extensionOffset + 4
    var ltrTimestamp: UInt32?
    var totalPacketsPerFrame: UInt16?
    var frameSequenceNumber: UInt16?

    if flagsAndLTRBits & ltrTimestampPresent != 0 {
        guard cursor + 4 <= extensionEnd else { return nil }
        // AVConference stores this optional field directly on its little-
        // endian Apple platforms; it does not apply the network-byte-order
        // conversion used by the frame fields below.
        ltrTimestamp = UInt32(packet[cursor])
            | UInt32(packet[cursor + 1]) << 8
            | UInt32(packet[cursor + 2]) << 16
            | UInt32(packet[cursor + 3]) << 24
        cursor += 4
    }

    if version == 2, flagsAndLTRBits & frameExtensionPresent != 0 {
        guard cursor + 4 <= extensionEnd else { return nil }
        totalPacketsPerFrame = UInt16(packet[cursor]) << 8
            | UInt16(packet[cursor + 1])
        frameSequenceNumber = UInt16(packet[cursor + 2]) << 8
            | UInt16(packet[cursor + 3])
    }

    return AppleMediaRTPMediaControlInfo(
        version: version,
        cameraStatus: statusAndVersion & 0x3f,
        ltrBits: flagsAndLTRBits >> 4,
        ltrTimestamp: ltrTimestamp,
        totalPacketsPerFrame: totalPacketsPerFrame,
        frameSequenceNumber: frameSequenceNumber)
}
