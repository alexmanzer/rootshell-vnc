import Foundation

/// The video-stream profile defines a low-precision echo timestamp by dropping
/// the standard 90 kHz RTP timestamp's low byte.
func appleMediaRCTLLowPrecisionEchoTimestamp(_ timestamp: UInt32) -> UInt16 {
    UInt16(truncatingIfNeeded: timestamp >> 8)
}

/// Convert one feedback interval's RTP reception statistics to the whole-
/// percent field used by VCRC. Confirmed missing packets count in the expected
/// total; intervals without traffic report zero rather than stale loss.
func appleMediaRCTLIntervalLossPercent(received: Int, lost: Int) -> UInt8 {
    let safeReceived = max(0, received)
    let safeLost = max(0, lost)
    let expected = safeReceived + safeLost
    guard expected > 0 else { return 0 }
    return UInt8(min(
        100,
        Int((Double(safeLost) * 100 / Double(expected)).rounded())))
}

/// Twenty-byte payload used by the RTCP APP `RCTL` packet.
/// The packed word at bytes 16...17 is bursty-loss (high nibble) plus the low
/// 12 bits of the cumulative received-packet count. It is not jitter depth or
/// a second packet-loss fraction.
struct AppleMediaRCTLFeedback: Equatable {
    let lossPercent: UInt8
    let echoTimestamp: UInt16
    let measurementAgeMilliseconds: UInt16
    let localTimestampQ10: UInt16
    let owrdQ13: UInt16
    let burstyLoss: UInt8
    let cumulativeReceivedPacketCount: UInt16
    let bandwidthEstimateKbps: UInt16

    func serialized() -> Data {
        var data = Data(capacity: 20)
        // Version 2 with VCRC, extended-feedback, and packet-count flags for
        // the feedback-only video profile.
        let mediaControlVersion2: UInt8 = 2 << 6
        let vcrcFieldsPresent: UInt8 = 0x05
        let extendedFeedbackFieldsPresent: UInt8 = 0x08
        data.append(
            mediaControlVersion2
                | vcrcFieldsPresent
                | extendedFeedbackFieldsPresent)
        data.append(lossPercent)
        appendUInt16BE(0x0004, to: &data)
        appendUInt16BE(echoTimestamp, to: &data)
        appendUInt16BE(0, to: &data)
        appendUInt16BE(0, to: &data)
        appendUInt16BE(measurementAgeMilliseconds, to: &data)
        appendUInt16BE(localTimestampQ10, to: &data)
        appendUInt16BE(owrdQ13, to: &data)
        let packedReceiveStatistics = (UInt16(min(15, burstyLoss)) << 12)
            | (cumulativeReceivedPacketCount & 0x0fff)
        appendUInt16BE(packedReceiveStatistics, to: &data)
        appendUInt16BE(bandwidthEstimateKbps, to: &data)
        return data
    }

    private func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }
}

/// Build the complete rate-control APP packet. The payload is
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

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
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
