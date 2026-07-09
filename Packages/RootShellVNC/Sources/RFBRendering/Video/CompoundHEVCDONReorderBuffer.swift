import Foundation

/// Restores Apple's compound screen-share pictures to their one global HEVC
/// decoding timeline. RTP sequence numbers and FU assembly are per SSRC, but
/// DON values are interleaved across every screen band.
struct CompoundHEVCDONReorderBuffer {
    struct SkippedGap: Equatable {
        let missingDON: UInt16
        let nextDON: UInt16
        let bufferedFrameCount: Int
    }

    struct Result {
        var ordered: [RTPDemuxer.DemuxedNAL] = []
        var startupOrder: [UInt16]?
        var skippedGaps: [SkippedGap] = []
    }

    private let startupFrameCount: Int
    private let maximumGapFrames: Int
    private var expectedSourceCount: Int
    private var pending: [UInt16: [RTPDemuxer.DemuxedNAL]] = [:]
    private var nextDON: UInt16?
    private var startupReferenceDON: UInt16?
    private var started = false

    init(
        expectedSourceCount: Int = 4,
        startupFrameCount: Int = 4,
        maximumGapFrames: Int = 12
    ) {
        self.expectedSourceCount = max(1, expectedSourceCount)
        self.startupFrameCount = startupFrameCount
        self.maximumGapFrames = maximumGapFrames
    }

    mutating func setExpectedSourceCount(_ count: Int) {
        guard !started else { return }
        expectedSourceCount = max(1, count)
    }

    mutating func enqueue(_ nals: [RTPDemuxer.DemuxedNAL]) -> Result {
        var result = Result()

        for nal in nals {
            if let nextDON {
                let behind = nextDON &- nal.don
                if started, behind != 0, behind < 0x8000 { continue }
            }
            if startupReferenceDON == nil { startupReferenceDON = nal.don }
            pending[nal.don, default: []].append(nal)
        }

        if !started {
            // Four screen bands carry N, N+1, N+2 and N+3, but their sockets
            // can become readable in any order. Collect the first complete pass
            // before choosing the earliest wraparound-relative DON.
            let sourceCount = Set(pending.values.flatMap { group in
                group.map(\.ssrc)
            }).count
            guard sourceCount >= expectedSourceCount,
                  pending.count >= max(startupFrameCount, expectedSourceCount),
                  let reference = startupReferenceDON else { return result }
            let order = pending.keys.sorted {
                Self.signedDistance($0, from: reference)
                    < Self.signedDistance($1, from: reference)
            }
            nextDON = order.first
            started = true
            result.startupOrder = order
        }

        while let expected = nextDON {
            if let group = pending.removeValue(forKey: expected) {
                result.ordered.append(contentsOf: group)
                nextDON = expected &+ 1
                continue
            }

            guard let nearest = nearestFutureDON(after: expected) else { break }
            let missing = Int(nearest &- expected)
            guard missing >= maximumGapFrames
                    || pending.count >= maximumGapFrames else { break }
            result.skippedGaps.append(.init(
                missingDON: expected,
                nextDON: nearest,
                bufferedFrameCount: pending.count))
            nextDON = nearest
        }
        return result
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
        nextDON = nil
        startupReferenceDON = nil
        started = false
    }

    private func nearestFutureDON(after don: UInt16) -> UInt16? {
        pending.keys
            .filter {
                let distance = $0 &- don
                return distance != 0 && distance < 0x8000
            }
            .min { ($0 &- don) < ($1 &- don) }
    }

    private static func signedDistance(_ don: UInt16, from reference: UInt16) -> Int {
        let distance = Int(don &- reference)
        return distance < 0x8000 ? distance : distance - 0x1_0000
    }
}
