import XCTest
import Foundation
import RFBRendering

final class RTPDemuxerTests: XCTestCase {

    func testAggregationPacketReturnsEveryNALUnit() throws {
        let demuxer = RTPDemuxer()
        let nal1 = Data([0x42, 0x01, 0xAA])
        let nal2 = Data([0x44, 0x01, 0xBB, 0xCC])

        // Apple's AP: PayloadHdr, a single 2-byte DONL, then [size][NAL] units.
        var payload = Data([0x60, 0x01]) // AP NAL header, type 48
        payload.append(contentsOf: [0xD4, 0x10]) // DONL
        payload.append(contentsOf: [0x00, UInt8(nal1.count)])
        payload.append(nal1)
        payload.append(contentsOf: [0x00, UInt8(nal2.count)])
        payload.append(nal2)

        let packet = RTPDemuxer.RTPPacket(
            version: 2,
            payloadType: 96,
            sequenceNumber: 1,
            timestamp: 90000,
            ssrc: 1,
            payload: payload,
            marker: true
        )

        let result = demuxer.feedPacket(packet)
        XCTAssertEqual(result.map(\.nal), [nal1, nal2])
        // All aggregated units share the AP's DON (0xD410).
        XCTAssertEqual(result.map(\.don), [0xD410, 0xD410])
        XCTAssertEqual(result.map(\.endOfAccessUnit), [false, true])
    }

    func testFragmentationUnitReassemblesNALUnit() throws {
        let demuxer = RTPDemuxer()

        // Apple repeats a 2-byte DONL after the FU header in every fragment.
        let startPayload = Data([
            0x62, 0x01,       // FU NAL header, type 49
            0x80 | 19,        // start, original NAL type 19
            0xD4, 0x10,       // DONL (stripped)
            0xAA, 0xBB,
        ])
        let endPayload = Data([
            0x62, 0x01,
            0x40 | 19,        // end, original NAL type 19
            0xD4, 0x10,       // DONL (stripped)
            0xCC, 0xDD,
        ])

        let start = packet(sequence: 10, payload: startPayload)
        let end = packet(sequence: 11, payload: endPayload, marker: true)

        XCTAssertTrue(demuxer.feedPacket(start).isEmpty)
        let result = demuxer.feedPacket(end)
        XCTAssertEqual(result.map(\.nal), [Data([0x26, 0x01, 0xAA, 0xBB, 0xCC, 0xDD])])
        // DON is taken from the start fragment's DONL (0xD410).
        XCTAssertEqual(result.first?.don, 0xD410)
        XCTAssertEqual(result.first?.endOfAccessUnit, true)
    }

    func testSequenceGapDropsInProgressFragment() throws {
        let demuxer = RTPDemuxer()

        let startPayload = Data([0x62, 0x01, 0x80 | 19, 0xD4, 0x10, 0xAA])
        let endPayload = Data([0x62, 0x01, 0x40 | 19, 0xD4, 0x10, 0xBB])

        XCTAssertTrue(demuxer.feedPacket(packet(sequence: 10, payload: startPayload)).isEmpty)
        XCTAssertTrue(demuxer.feedPacket(packet(sequence: 12, payload: endPayload)).isEmpty)
    }

    func testSingleNALUnitStripsDONL() throws {
        let demuxer = RTPDemuxer()
        // Single-NAL packet: [NAL hdr 0x02 0x01][DONL 0xD4 0x14][RBSP ...].
        let payload = Data([0x02, 0x01, 0xD4, 0x14, 0xAA, 0xBB, 0xCC])
        let result = demuxer.feedPacket(packet(sequence: 5, payload: payload, marker: true))
        // DONL removed; NAL header + RBSP retained.
        XCTAssertEqual(result.map(\.nal), [Data([0x02, 0x01, 0xAA, 0xBB, 0xCC])])
        XCTAssertEqual(result.first?.don, 0xD414)
        XCTAssertEqual(result.first?.endOfAccessUnit, true)
    }

    func testAggregationPacketWithoutDONL() throws {
        let demuxer = RTPDemuxer(usesDecodingOrderNumbers: false)
        let vps = Data([0x40, 0x01, 0xAA])
        let sps = Data([0x42, 0x01, 0xBB])
        var payload = Data([0x60, 0x01])
        payload.append(contentsOf: [0x00, UInt8(vps.count)])
        payload.append(vps)
        payload.append(contentsOf: [0x00, UInt8(sps.count)])
        payload.append(sps)

        let result = demuxer.feedPacket(packet(
            sequence: 30,
            payload: payload,
            marker: true))

        XCTAssertEqual(result.map(\.nal), [vps, sps])
        XCTAssertEqual(result.map(\.don), [0, 0])
    }

    func testFragmentationUnitWithoutDONL() throws {
        let demuxer = RTPDemuxer(usesDecodingOrderNumbers: false)
        let start = Data([0x62, 0x01, 0x80 | 19, 0xAA, 0xBB])
        let end = Data([0x62, 0x01, 0x40 | 19, 0xCC, 0xDD])

        XCTAssertTrue(demuxer.feedPacket(packet(sequence: 40, payload: start)).isEmpty)
        let result = demuxer.feedPacket(packet(
            sequence: 41,
            payload: end,
            marker: true))

        XCTAssertEqual(result.map(\.nal), [Data([0x26, 0x01, 0xAA, 0xBB, 0xCC, 0xDD])])
        XCTAssertEqual(result.first?.don, 0)
    }

    func testSingleNALUnitWithoutDONLPreservesRBSP() throws {
        let demuxer = RTPDemuxer(usesDecodingOrderNumbers: false)
        let payload = Data([0x02, 0x01, 0xD4, 0x14, 0xAA])

        let result = demuxer.feedPacket(packet(
            sequence: 50,
            payload: payload,
            marker: true))

        XCTAssertEqual(result.map(\.nal), [payload])
        XCTAssertEqual(result.first?.don, 0)
    }

    func testRTCPPacketDetection() {
        let senderReport = Data([0x81, 0xc8, 0x00, 0x0c])
        let receiverReport = Data([0x81, 0xc9, 0x00, 0x07])
        let rtpMedia = Data([0x80, 0xe5, 0xd8, 0x13])

        XCTAssertTrue(RTPDemuxer.isRTCPPacket(senderReport))
        XCTAssertTrue(RTPDemuxer.isRTCPPacket(receiverReport))
        XCTAssertFalse(RTPDemuxer.isRTCPPacket(rtpMedia))
    }

    private func packet(
        sequence: UInt16,
        payload: Data,
        marker: Bool = false
    ) -> RTPDemuxer.RTPPacket {
        RTPDemuxer.RTPPacket(
            version: 2,
            payloadType: 96,
            sequenceNumber: sequence,
            timestamp: 1234,
            ssrc: 42,
            payload: payload,
            marker: marker
        )
    }
}
