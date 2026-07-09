import Foundation

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
