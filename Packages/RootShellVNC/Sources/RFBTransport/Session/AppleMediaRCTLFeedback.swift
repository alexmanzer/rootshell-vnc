import Foundation

/// Extract the sender clock carried by Apple's video RTP media-control
/// extension and convert it to the Q10 clock used by RCTL.
///
/// The screen stream's extension profile is `0x9311`: media-control version 2
/// with the transmit-timestamp fields present. Its one 32-bit extension word is
/// a 24-bit Q18 timestamp with a leading pad byte. AVConference converts it to
/// the 16-bit, Q10 RCTL echo by shifting eight bits before serialization.
func appleMediaRTPTransmitTimestampQ10(_ packet: Data) -> UInt16? {
    guard packet.count >= 20 else { return nil }
    let base = packet.startIndex
    guard packet[base] >> 6 == 2,
          packet[base] & 0x10 != 0 else { return nil }

    let csrcBytes = Int(packet[base] & 0x0f) * 4
    let extensionOffset = base + 12 + csrcBytes
    guard extensionOffset + 8 <= packet.endIndex else { return nil }

    let profile = UInt16(packet[extensionOffset]) << 8
        | UInt16(packet[extensionOffset + 1])
    let wordCount = Int(UInt16(packet[extensionOffset + 2]) << 8
        | UInt16(packet[extensionOffset + 3]))
    guard profile == 0x9311, wordCount >= 1,
          extensionOffset + 4 + wordCount * 4 <= packet.endIndex else { return nil }

    let timestampQ18 = UInt32(packet[extensionOffset + 4]) << 24
        | UInt32(packet[extensionOffset + 5]) << 16
        | UInt32(packet[extensionOffset + 6]) << 8
        | UInt32(packet[extensionOffset + 7])
    return UInt16(truncatingIfNeeded: timestampQ18 >> 8)
}

/// Verified 20-byte payload used by AVConference's RTCP APP `RCTL` packet.
/// The packed word at bytes 16...17 is bursty-loss (high nibble) plus jitter
/// queue size (low 12 bits); it is not a second packet-loss fraction.
struct AppleMediaRCTLFeedback: Equatable {
    let lossPercent: UInt8
    let echoTimestamp: UInt16
    let measurementAgeMilliseconds: UInt16
    let localTimestampQ10: UInt16
    let owrdQ13: UInt16
    let burstyLoss: UInt8
    let jitterQueueSize: UInt16
    let bandwidthEstimateKbps: UInt16

    func serialized() -> Data {
        var data = Data(capacity: 20)
        data.append(0x85)
        data.append(lossPercent)
        appendUInt16BE(0x0004, to: &data)
        appendUInt16BE(echoTimestamp, to: &data)
        appendUInt16BE(0, to: &data)
        appendUInt16BE(0, to: &data)
        appendUInt16BE(measurementAgeMilliseconds, to: &data)
        appendUInt16BE(localTimestampQ10, to: &data)
        appendUInt16BE(owrdQ13, to: &data)
        let packedQueue = (UInt16(min(15, burstyLoss)) << 12)
            | min(0x0fff, jitterQueueSize)
        appendUInt16BE(packedQueue, to: &data)
        appendUInt16BE(bandwidthEstimateKbps, to: &data)
        return data
    }

    private func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }
}

/// Build the complete AVConference rate-control APP packet. The payload is
/// always 20 bytes, so the RTCP packet is 8 32-bit words and its RFC 3550
/// length field is 7 (packet words minus one).
func appleMediaRCTLPacket(
    senderSSRC: UInt32,
    feedback: AppleMediaRCTLFeedback
) -> Data {
    var packet = Data(capacity: 32)
    packet.append(0x80) // RTP version 2, no padding/subtype
    packet.append(204)  // RTCP APP
    packet.append(0x00)
    packet.append(0x07)
    packet.append(UInt8((senderSSRC >> 24) & 0xff))
    packet.append(UInt8((senderSSRC >> 16) & 0xff))
    packet.append(UInt8((senderSSRC >> 8) & 0xff))
    packet.append(UInt8(senderSSRC & 0xff))
    packet.append(contentsOf: "RCTL".utf8)
    packet.append(feedback.serialized())
    return packet
}

/// One RFC 4585 Generic NACK feedback-control entry. `packetID` identifies the
/// first missing RTP packet; bit N of `bitmask` requests packetID + N + 1.
struct AppleMediaGenericNACKEntry: Equatable {
    let packetID: UInt16
    let bitmask: UInt16
}

/// Pack missing RTP sequence numbers into the smallest ordered PID/BLP list.
/// The reorder buffer supplies sequences in forward wraparound order.
func appleMediaGenericNACKEntries(
    missingSequences: [UInt16]
) -> [AppleMediaGenericNACKEntry] {
    guard !missingSequences.isEmpty else { return [] }

    var entries: [AppleMediaGenericNACKEntry] = []
    var index = 0
    while index < missingSequences.count {
        let packetID = missingSequences[index]
        var bitmask: UInt16 = 0
        var nextIndex = index + 1
        while nextIndex < missingSequences.count {
            let distance = missingSequences[nextIndex] &- packetID
            if distance == 0 {
                nextIndex += 1
                continue
            }
            guard distance <= 16 else { break }
            bitmask |= UInt16(1) << (distance - 1)
            nextIndex += 1
        }
        entries.append(.init(packetID: packetID, bitmask: bitmask))
        index = nextIndex
    }
    return entries
}
