import Foundation
import XCTest
@testable import RFBTransport

final class BoundedDatagramFIFOTests: XCTestCase {
    func testPreservesFIFOOrderAcrossCompactionThreshold() {
        var fifo = BoundedDatagramFIFO(capacity: 10_000)
        let first = (0..<6_000).map { packet($0) }
        XCTAssertEqual(fifo.append(contentsOf: first), 0)

        for expected in first.prefix(5_000) {
            XCTAssertEqual(fifo.popFirst(), expected)
        }

        let second = (6_000..<11_000).map { packet($0) }
        XCTAssertEqual(fifo.append(contentsOf: second), 0)
        XCTAssertEqual(
            drain(&fifo),
            Array(first.dropFirst(5_000)) + second)
    }

    func testOverflowDropsOnlyOldestDatagrams() {
        var fifo = BoundedDatagramFIFO(capacity: 3)
        XCTAssertEqual(fifo.append(contentsOf: [packet(1), packet(2)]), 0)
        XCTAssertEqual(
            fifo.append(contentsOf: [packet(3), packet(4), packet(5)]),
            2)
        XCTAssertEqual(drain(&fifo), [packet(3), packet(4), packet(5)])
    }

    private func drain(_ fifo: inout BoundedDatagramFIFO) -> [PosixUDPDatagram] {
        var result: [PosixUDPDatagram] = []
        while let packet = fifo.popFirst() { result.append(packet) }
        return result
    }

    private func packet(_ value: Int) -> PosixUDPDatagram {
        PosixUDPDatagram(data: packetData(value), arrivalNanos: UInt64(value))
    }

    private func packetData(_ value: Int) -> Data {
        var bigEndian = UInt32(value).bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
    }
}
