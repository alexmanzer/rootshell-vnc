import Foundation
import XCTest
@testable import RFBRendering

final class CompoundHEVCDONReorderBufferTests: XCTestCase {
    func testStartupRestoresFourInterleavedBandsToGlobalDONOrder() {
        var reorder = CompoundHEVCDONReorderBuffer()
        XCTAssertTrue(reorder.enqueue([nal(102)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(100)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(103)]).orderedAccessUnits.isEmpty)

        let result = reorder.enqueue([nal(101)])
        XCTAssertEqual(result.startupOrder, [100, 101, 102, 103])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [100, 101, 102, 103])
        XCTAssertTrue(result.skippedGaps.isEmpty)
    }

    func testPostStartupFuturePictureWaitsForMissingDON() {
        var reorder = startedBuffer(at: 100)
        XCTAssertTrue(reorder.enqueue([nal(105)]).orderedAccessUnits.isEmpty)

        let result = reorder.enqueue([nal(104)])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [104, 105])
        XCTAssertTrue(result.skippedGaps.isEmpty)
    }

    func testStartupDoesNotAdvanceAfterFourDONsFromOnlyTwoBands() {
        var reorder = CompoundHEVCDONReorderBuffer(expectedSourceCount: 4)
        XCTAssertTrue(reorder.enqueue([nal(66, ssrc: 0)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(67, ssrc: 1)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(70, ssrc: 0)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(71, ssrc: 1)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(68, ssrc: 2)]).orderedAccessUnits.isEmpty)

        let result = reorder.enqueue([nal(69, ssrc: 3)])
        XCTAssertEqual(result.startupOrder, [66, 67, 68, 69, 70, 71])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [66, 67, 68, 69, 70, 71])
        XCTAssertTrue(result.skippedGaps.isEmpty)
    }

    func testStartupOrderingHandlesDONWraparound() {
        var reorder = CompoundHEVCDONReorderBuffer()
        _ = reorder.enqueue([nal(1)])
        _ = reorder.enqueue([nal(.max)])
        _ = reorder.enqueue([nal(2)])
        let result = reorder.enqueue([nal(0)])

        XCTAssertEqual(result.startupOrder, [.max, 0, 1, 2])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [.max, 0, 1, 2])
    }

    func testBoundedMissingDONSkipsInsteadOfFreezing() {
        var reorder = startedBuffer(at: 100)
        var final = CompoundHEVCDONReorderBuffer.Result()
        for don in UInt16(105)...UInt16(116) {
            final = reorder.enqueue([nal(don)])
        }

        XCTAssertEqual(final.skippedGaps, [
            .init(missingDON: 104, nextDON: 105, bufferedFrameCount: 12),
        ])
        XCTAssertEqual(final.orderedAccessUnits.map(\.don), Array(UInt16(105)...UInt16(116)))
    }

    func testLatePictureIsIgnoredAfterTimelineAdvanced() {
        var reorder = startedBuffer(at: 100)
        XCTAssertTrue(reorder.enqueue([nal(102)]).orderedAccessUnits.isEmpty)
    }

    func testMultipleSlicesWithOneDONBecomeOneCompleteAccessUnit() {
        var reorder = startedBuffer(at: 100)
        let firstSlice = nal(104, ssrc: 0, endOfAccessUnit: false)
        XCTAssertTrue(reorder.enqueue([firstSlice]).orderedAccessUnits.isEmpty)

        let finalSlice = nal(104, ssrc: 0, endOfAccessUnit: true)
        let result = reorder.enqueue([finalSlice])
        XCTAssertEqual(result.orderedAccessUnits.count, 1)
        XCTAssertEqual(result.orderedAccessUnits.first?.don, 104)
        XCTAssertEqual(result.orderedAccessUnits.first?.nals, [firstSlice, finalSlice])
    }

    private func startedBuffer(at firstDON: UInt16) -> CompoundHEVCDONReorderBuffer {
        var reorder = CompoundHEVCDONReorderBuffer()
        _ = reorder.enqueue([nal(firstDON &+ 2)])
        _ = reorder.enqueue([nal(firstDON)])
        _ = reorder.enqueue([nal(firstDON &+ 3)])
        let result = reorder.enqueue([nal(firstDON &+ 1)])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [firstDON, firstDON &+ 1, firstDON &+ 2, firstDON &+ 3])
        return reorder
    }

    private func nal(
        _ don: UInt16,
        ssrc: UInt32? = nil,
        endOfAccessUnit: Bool = true
    ) -> RTPDemuxer.DemuxedNAL {
        RTPDemuxer.DemuxedNAL(
            don: don,
            ssrc: ssrc ?? UInt32(don & 3),
            nal: Data([0x02, 0x01]),
            endOfAccessUnit: endOfAccessUnit)
    }
}
