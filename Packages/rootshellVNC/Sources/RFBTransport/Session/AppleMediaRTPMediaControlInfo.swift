import Foundation

/// Public wire representation of the media-control information Apple places in
/// the standard RTP header-extension slot.
///
/// Unlike RFC 8285 extensions, the first two bytes are not an opaque profile
/// identifier. This profile defines them as a version/status byte and a
/// flags/LTR byte. The following big-endian word count remains the RTP
/// extension length.
struct AppleMediaRTPMediaControlInfo: Equatable {
    let version: UInt8
    let cameraStatus: UInt8
    let ltrBits: UInt8
    let ltrTimestamp: UInt32?
    let totalPacketsPerFrame: UInt16?
    let frameSequenceNumber: UInt16?
}

/// Parse the media-control RTP extension from its wire representation.
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
    // The media-control profile defines versions 1 through 3. Reject zero so
    // an unrelated extension cannot be mistaken for
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
        // This optional field is little-endian, unlike the network-byte-order
        // frame fields below.
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

/// Return the RTP timestamp that the native receiver acknowledges for a
/// completed LTR-marked access unit. Only an RTP marker packet completes an
/// access unit; acknowledging an earlier fragment could let the sender use a
/// reference picture whose remaining packets never arrived.
func appleMediaLTRAcknowledgementTimestamp(_ packet: Data) -> UInt32? {
    let minimumRTPHeaderLength = 12
    guard packet.count >= minimumRTPHeaderLength else { return nil }
    let base = packet.startIndex
    guard packet[base] >> 6 == 2,
          packet[base + 1] & 0x80 != 0,
          let mediaControl = appleMediaRTPMediaControlInfo(packet),
          mediaControl.ltrBits != 0 else { return nil }
    return UInt32(packet[base + 4]) << 24
        | UInt32(packet[base + 5]) << 16
        | UInt32(packet[base + 6]) << 8
        | UInt32(packet[base + 7])
}
