import Foundation
import XCTest
@testable import RFBTransport

final class AppleMediaRTPIngressTests: XCTestCase {
    func testHandoffDrainsStartupPacketsInFIFOOrder() {
        let received = LockedPackets()
        var handoff = AppleMediaPacketHandoff(maximumPackets: 8, maximumBytes: 128)

        XCTAssertEqual(handoff.deliver(Data([1])), .buffered)
        XCTAssertEqual(handoff.deliver(Data([2])), .buffered)
        let result = handoff.installSink { received.append($0) }
        XCTAssertEqual(result.packetCount, 2)
        XCTAssertEqual(result.byteCount, 2)
        XCTAssertFalse(result.overflowed)

        XCTAssertEqual(handoff.deliver(Data([3])), .delivered)
        XCTAssertEqual(received.values, [Data([1]), Data([2]), Data([3])])
    }

    func testHandoffOverflowPreservesOldestBootstrapPackets() {
        let received = LockedPackets()
        var handoff = AppleMediaPacketHandoff(maximumPackets: 2, maximumBytes: 2)

        XCTAssertEqual(handoff.deliver(Data([1])), .buffered)
        XCTAssertEqual(handoff.deliver(Data([2])), .buffered)
        XCTAssertEqual(handoff.deliver(Data([3])), .overflow)
        let result = handoff.installSink { received.append($0) }

        XCTAssertTrue(result.overflowed)
        XCTAssertEqual(result.droppedPacketCount, 1)
        XCTAssertEqual(received.values, [Data([1]), Data([2])])
    }

    func testStartupHoldRestoresPacketsThatArriveOutOfOrder() {
        var reorder = makeReorderBuffer()
        XCTAssertTrue(reorder.insert(packet: packet(11), ssrc: 1, sequence: 11, nowNanos: 0).packets.isEmpty)
        XCTAssertTrue(reorder.insert(packet: packet(10), ssrc: 1, sequence: 10, nowNanos: 1).packets.isEmpty)

        let result = reorder.flushExpired(nowNanos: 9)
        XCTAssertEqual(result.packets, [packet(10), packet(11)])
        XCTAssertTrue(result.gaps.isEmpty)
    }

    func testPostStartupReorderingDoesNotBecomeLoss() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 1, sequence: 10, nowNanos: 0)
        XCTAssertEqual(reorder.flushExpired(nowNanos: 8).packets, [packet(10)])

        XCTAssertTrue(reorder.insert(packet: packet(12), ssrc: 1, sequence: 12, nowNanos: 9).packets.isEmpty)
        let result = reorder.insert(packet: packet(11), ssrc: 1, sequence: 11, nowNanos: 10)
        XCTAssertEqual(result.packets, [packet(11), packet(12)])
        XCTAssertTrue(result.gaps.isEmpty)
        XCTAssertTrue(result.retransmissionRequests.isEmpty)
    }

    func testMissingPacketRequestsRetransmissionBeforeBecomingLoss() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 7, sequence: 10, nowNanos: 0)
        _ = reorder.flushExpired(nowNanos: 8)
        let initial = reorder.insert(packet: packet(12), ssrc: 7, sequence: 12, nowNanos: 9)
        XCTAssertEqual(initial.retransmissionRequests, [
            .init(ssrc: 7, missingSequences: [11]),
        ])

        XCTAssertTrue(reorder.flushExpired(nowNanos: 18).packets.isEmpty)
        XCTAssertEqual(reorder.flushExpired(nowNanos: 19).retransmissionRequests, [
            .init(ssrc: 7, missingSequences: [11]),
        ])
        let result = reorder.flushExpired(nowNanos: 39)
        XCTAssertEqual(result.packets, [packet(12)])
        XCTAssertEqual(result.gaps, [.init(ssrc: 7, missingPacketCount: 1)])
    }

    func testRetransmittedPacketClosesGapAndReleasesInOrder() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 7, sequence: 10, nowNanos: 0)
        _ = reorder.flushExpired(nowNanos: 8)
        _ = reorder.insert(packet: packet(12), ssrc: 7, sequence: 12, nowNanos: 9)

        let recovered = reorder.insert(
            packet: packet(11),
            ssrc: 7,
            sequence: 11,
            nowNanos: 12)
        XCTAssertEqual(recovered.packets, [packet(11), packet(12)])
        XCTAssertTrue(recovered.gaps.isEmpty)
        XCTAssertTrue(recovered.retransmissionRequests.isEmpty)
    }

    func testSequenceWraparoundAndIndependentSSRCs() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(1), ssrc: 1, sequence: .max, nowNanos: 0)
        _ = reorder.insert(packet: packet(2), ssrc: 2, sequence: 40, nowNanos: 1)
        _ = reorder.insert(packet: packet(3), ssrc: 1, sequence: 0, nowNanos: 2)

        let result = reorder.flushExpired(nowNanos: 9)
        XCTAssertEqual(result.packets, [packet(1), packet(2), packet(3)])
        XCTAssertTrue(result.gaps.isEmpty)
    }

    private func makeReorderBuffer() -> AppleMediaRTPReorderBuffer {
        AppleMediaRTPReorderBuffer(
            startupHoldNanos: 8,
            maximumGapWaitNanos: 30,
            nackRetryNanos: 10,
            maximumBufferedPacketsPerStream: 64)
    }

    private func packet(_ value: UInt8) -> Data { Data([value]) }
}

private final class LockedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    func append(_ packet: Data) {
        lock.lock()
        packets.append(packet)
        lock.unlock()
    }

    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return packets
    }
}
