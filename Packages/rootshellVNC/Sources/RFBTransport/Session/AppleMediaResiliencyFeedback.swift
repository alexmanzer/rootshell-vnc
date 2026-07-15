import Foundation

/// Frame-loss report for the negotiated screen-video transmitter.
///
/// The wire format is an RTCP PSFB application-feedback packet carrying frame
/// timing and packet-loss counters.
struct AppleMediaFrameLossFeedback: Equatable, Sendable {
    /// RTP timestamp of the damaged frame.
    let frameRTPTimestamp: UInt32
    /// Sequence of the damaged frame from Apple's RTP media-control extension.
    let frameSequenceNumber: UInt16
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
    /// AVConference's public RTCP APP wire identifier for an LTR decode
    /// acknowledgement. This is a network-order integer, not a fourcc.
    static let ltrAcknowledgementApplicationType: UInt32 = 5
    static let ltrAcknowledgementLengthInWordsMinusOne: UInt16 = 3
}

/// Apple's compound screen stream assigns ascending SSRCs from the base band.
/// FIR targets that base source because all bands share one HEVC reference
/// timeline. Frame-loss feedback still identifies the band that lost RTP.
func appleMediaCompoundBaseSSRC(_ ssrcs: [UInt32]) -> UInt32? {
    ssrcs.min()
}

/// Serialize frame-loss feedback as one 24-byte RTCP PSFB packet.
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
    appendUInt16BE(feedback.frameSequenceNumber, to: &packet)
    packet.append(feedback.framePacketCount)
    packet.append(feedback.lostPacketCount)
    return packet
}

/// Serialize the PSFB FIR used when AFB type-6 loss feedback does not restore
/// video output. The receiver then resets its expected decoding order.
func appleMediaFullIntraRequestPacket(
    senderSSRC: UInt32,
    mediaSSRC: UInt32,
    sequenceNumber: UInt8
) -> Data {
    var packet = Data(capacity: 20)
    packet.append(0x84) // V=2, P=0, FMT=4
    packet.append(0xce) // PT=206, payload-specific feedback
    appendUInt16BE(4, to: &packet)
    appendUInt32BE(senderSSRC, to: &packet)
    appendUInt32BE(0, to: &packet) // FIR uses zero in the common media-SSRC field
    appendUInt32BE(mediaSSRC, to: &packet)
    packet.append(sequenceNumber)
    packet.append(contentsOf: [0, 0, 0])
    return packet
}

/// Serialize the native 16-byte RTCP APP acknowledgement emitted after an
/// LTR-marked video access unit is accepted by the receiver.
///
/// Wire layout: `80 CC 00 03 [sender SSRC] 00 00 00 05 [RTP timestamp]`.
func appleMediaLTRAcknowledgementPacket(
    senderSSRC: UInt32,
    rtpTimestamp: UInt32
) -> Data {
    var packet = Data(capacity: 16)
    packet.append(0x80) // V=2, P=0, APP subtype=0
    packet.append(0xcc) // PT=204, APP
    appendUInt16BE(
        AppleMediaResiliencyWire.ltrAcknowledgementLengthInWordsMinusOne,
        to: &packet)
    appendUInt32BE(senderSSRC, to: &packet)
    appendUInt32BE(
        AppleMediaResiliencyWire.ltrAcknowledgementApplicationType,
        to: &packet)
    appendUInt32BE(rtpTimestamp, to: &packet)
    return packet
}

/// Append the minimal SDES packet emitted by AVConference to an ordinary
/// receiver report. Its CNAME item is present with a zero-length value, making
/// the SDES packet exactly 12 bytes. After the 14-byte SRTCP trailer, a
/// 32-byte one-source RR plus this SDES is the native capture's distinctive
/// 58-byte UDP control payload.
func appleMediaReceiverReportCompound(
    receiverReport: Data,
    senderSSRC: UInt32
) -> Data {
    var compound = receiverReport
    compound.append(0x81) // V=2, one SDES chunk
    compound.append(0xca) // PT=202 (SDES)
    appendUInt16BE(2, to: &compound) // 12 bytes total
    appendUInt32BE(senderSSRC, to: &compound)
    compound.append(1) // CNAME item
    compound.append(0) // zero-length CNAME, matching AVConference
    compound.append(0) // END
    compound.append(0) // 32-bit padding
    return compound
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
