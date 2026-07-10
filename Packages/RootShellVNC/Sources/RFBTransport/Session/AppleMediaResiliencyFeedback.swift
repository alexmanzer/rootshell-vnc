import Foundation

/// Frame-loss report consumed by AVConference's screen-video transmitter.
///
/// The wire layout and field meanings come from the local AVConference
/// `VideoReceiver_SendRTCPResiliencyInfo` / `RTCPAddPSFBAlfbPacket` path. This
/// is ordinary RTCP PSFB application feedback; no private framework is linked
/// or called by the client.
struct AppleMediaFrameLossFeedback: Equatable, Sendable {
    /// RTP timestamp of the damaged frame.
    let frameRTPTimestamp: UInt32
    /// Cumulative number of RTP packets accepted by this receiver, modulo 2^16.
    let receivedPacketCount: UInt16
    /// Total packets belonging to the damaged frame, including missing packets.
    let framePacketCount: UInt8
    /// Packets missing from the damaged frame.
    let lostPacketCount: UInt8
}

private enum AppleMediaResiliencyWire {
    static let rtpVersion: UInt8 = 2
    static let applicationFeedbackFormat: UInt8 = 15
    static let payloadSpecificFeedbackType: UInt8 = 206
    static let frameLossApplicationType: UInt32 = 6
    static let frameLossLengthInWordsMinusOne: UInt16 = 5
}

/// Serialize AVConference frame-loss feedback as one 24-byte RTCP PSFB packet.
/// The caller prefixes a Receiver Report and applies SRTCP before transmission.
func appleMediaFrameLossPacket(
    senderSSRC: UInt32,
    mediaSSRC: UInt32,
    feedback: AppleMediaFrameLossFeedback
) -> Data {
    var packet = Data(capacity: 24)
    let versionAndFormat = AppleMediaResiliencyWire.rtpVersion << 6
        | AppleMediaResiliencyWire.applicationFeedbackFormat
    packet.append(versionAndFormat)
    packet.append(AppleMediaResiliencyWire.payloadSpecificFeedbackType)
    appendUInt16BE(
        AppleMediaResiliencyWire.frameLossLengthInWordsMinusOne,
        to: &packet)
    appendUInt32BE(senderSSRC, to: &packet)
    appendUInt32BE(mediaSSRC, to: &packet)
    appendUInt32BE(AppleMediaResiliencyWire.frameLossApplicationType, to: &packet)
    appendUInt32BE(feedback.frameRTPTimestamp, to: &packet)
    appendUInt16BE(feedback.receivedPacketCount, to: &packet)
    packet.append(feedback.framePacketCount)
    packet.append(feedback.lostPacketCount)
    return packet
}

private func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value >> 8))
    data.append(UInt8(value & 0xff))
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}
