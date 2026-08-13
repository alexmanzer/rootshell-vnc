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
    /// RTCP APP wire identifier required for a compatible LTR decode
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

/// Append the minimal peer-compatible SDES packet to an ordinary receiver
/// report. Its CNAME item is present with a zero-length value, making
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
    compound.append(0) // zero-length CNAME required for wire compatibility
    compound.append(0) // END
    compound.append(0) // 32-bit padding
    return compound
}

/// The most recent Sender Report timing for one remote RTP source.
///
/// RTCP LSR/DLSR values are scoped to an SSRC. Reusing a report from another
/// stream (for example, acknowledging a video SR in the audio RR) produces a
/// reply the sender cannot correlate with any report it transmitted.
struct AppleMediaSenderReportTiming: Sendable, Equatable {
    let remoteSSRC: UInt32
    let ntpTimestamp: UInt64
    let rtpTimestamp: UInt32
    let lsr: UInt32
    let arrivalNanos: UInt64
}

/// Extract the sender identity and LSR value from an unprotected RTCP Sender
/// Report. The middle 32 bits of its 64-bit NTP timestamp are the LSR echoed by
/// a Receiver Report.
func appleMediaSenderReportTiming(
    from rtcp: Data,
    arrivalNanos: UInt64
) -> AppleMediaSenderReportTiming? {
    guard rtcp.count >= 20 else { return nil }
    let base = rtcp.startIndex
    guard rtcp[base] >> 6 == 2, rtcp[base + 1] == 200 else { return nil }
    let remoteSSRC = UInt32(rtcp[base + 4]) << 24
        | UInt32(rtcp[base + 5]) << 16
        | UInt32(rtcp[base + 6]) << 8
        | UInt32(rtcp[base + 7])
    let ntpTimestamp = UInt64(rtcp[base + 8]) << 56
        | UInt64(rtcp[base + 9]) << 48
        | UInt64(rtcp[base + 10]) << 40
        | UInt64(rtcp[base + 11]) << 32
        | UInt64(rtcp[base + 12]) << 24
        | UInt64(rtcp[base + 13]) << 16
        | UInt64(rtcp[base + 14]) << 8
        | UInt64(rtcp[base + 15])
    let lsr = UInt32(rtcp[base + 10]) << 24
        | UInt32(rtcp[base + 11]) << 16
        | UInt32(rtcp[base + 12]) << 8
        | UInt32(rtcp[base + 13])
    let rtpTimestamp = UInt32(rtcp[base + 16]) << 24
        | UInt32(rtcp[base + 17]) << 16
        | UInt32(rtcp[base + 18]) << 8
        | UInt32(rtcp[base + 19])
    return AppleMediaSenderReportTiming(
        remoteSSRC: remoteSSRC,
        ntpTimestamp: ntpTimestamp,
        rtpTimestamp: rtpTimestamp,
        lsr: lsr,
        arrivalNanos: arrivalNanos)
}

/// Build the LSR/DLSR pair for one report block. A missing per-source Sender
/// Report is represented by the RFC 3550 zero pair.
func appleMediaReceiverReportTiming(
    for remoteSSRC: UInt32,
    senderReports: [UInt32: AppleMediaSenderReportTiming],
    nowNanos: UInt64
) -> (lsr: UInt32, dlsr: UInt32) {
    guard let report = senderReports[remoteSSRC] else {
        return (0, 0)
    }
    let elapsed = nowNanos &- report.arrivalNanos
    let dlsr = UInt32(
        truncatingIfNeeded: (elapsed &* 65_536) / 1_000_000_000)
    return (report.lsr, dlsr)
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
