import Dispatch
import XCTest
@testable import RFBTransport

final class ConnectionByteCounterTests: XCTestCase {
    func testConcurrentSnapshotsDoNotLoseSocketBytes() {
        let counter = ConnectionByteCounter()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            counter.receive(128)
            counter.send(64)
            _ = counter.snapshot()
        }
        XCTAssertEqual(counter.snapshot().received, 128_000)
        XCTAssertEqual(counter.snapshot().sent, 64_000)
        XCTAssertEqual(ConnectionByteCounter().snapshot(), ConnectionByteCounts())
    }
}
