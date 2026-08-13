/// Assembles VCL NAL units in the one-tile RTP mode, where no DONL is present.
/// RTP marker bits delimit access units and the transport has already restored
/// packet sequence order, so no cross-source decode-order scheduler is needed.
struct SequentialHEVCAccessUnitAssembler {
    private var pendingVCL: [RTPDemuxer.DemuxedNAL] = []
    private var pendingSSRC: UInt32?
    private var nextIdentifier: UInt16 = 0

    mutating func appendVCL(_ nal: RTPDemuxer.DemuxedNAL) {
        if let pendingSSRC, pendingSSRC != nal.ssrc {
            resetPending()
        }
        pendingSSRC = nal.ssrc
        pendingVCL.append(nal)
    }

    /// Finish the current access unit when any NAL carrying the RTP marker is
    /// observed. This also handles streams whose marker is on a suffix SEI
    /// rather than on the final VCL NAL itself.
    mutating func finish(ssrc: UInt32) -> CompoundHEVCDONReorderBuffer.AccessUnit? {
        guard pendingSSRC == ssrc, !pendingVCL.isEmpty else { return nil }
        let result = CompoundHEVCDONReorderBuffer.AccessUnit(
            don: nextIdentifier,
            timestamp: pendingVCL[0].timestamp,
            ssrc: ssrc,
            nals: pendingVCL)
        nextIdentifier &+= 1
        resetPending()
        return result
    }

    mutating func reset() {
        resetPending()
        nextIdentifier = 0
    }

    mutating func discardPartialAccessUnit() {
        resetPending()
    }

    private mutating func resetPending() {
        pendingVCL.removeAll(keepingCapacity: true)
        pendingSSRC = nil
    }
}
