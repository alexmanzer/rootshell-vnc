import Foundation
import XCTest
@testable import RFBRendering

final class SequentialHEVCAccessUnitAssemblerTests: XCTestCase {
    func testMarkerFinishesMultipleVCLNALs() throws {
        var assembler = SequentialHEVCAccessUnitAssembler()
        let first = nal(ssrc: 7, marker: false, byte: 1)
        let second = nal(ssrc: 7, marker: true, byte: 2)

        assembler.appendVCL(first)
        assembler.appendVCL(second)
        let result = try XCTUnwrap(assembler.finish(ssrc: 7))

        XCTAssertEqual(result.don, 0)
        XCTAssertEqual(result.ssrc, 7)
        XCTAssertEqual(result.nals, [first, second])
    }

    func testSuffixMarkerFinishesPendingVCL() throws {
        var assembler = SequentialHEVCAccessUnitAssembler()
        let slice = nal(ssrc: 9, marker: false, byte: 3)
        assembler.appendVCL(slice)

        let result = try XCTUnwrap(assembler.finish(ssrc: 9))
        XCTAssertEqual(result.nals, [slice])
    }

    func testPacketLossDiscardsPartialAccessUnit() {
        var assembler = SequentialHEVCAccessUnitAssembler()
        assembler.appendVCL(nal(ssrc: 1, marker: false, byte: 4))
        assembler.discardPartialAccessUnit()

        XCTAssertNil(assembler.finish(ssrc: 1))
    }

    private func nal(
        ssrc: UInt32,
        marker: Bool,
        byte: UInt8
    ) -> RTPDemuxer.DemuxedNAL {
        .init(
            don: 0,
            ssrc: ssrc,
            nal: Data([0x02, 0x01, byte]),
            endOfAccessUnit: marker)
    }
}
