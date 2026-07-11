import XCTest
@testable import RootShellVNC

final class AtomicBandFrameAccumulatorTests: XCTestCase {
    func testDoesNotPublishPartialCompoundFrame() {
        var accumulator = AtomicBandFrameAccumulator<String>(expectedSourceCount: 2)

        accumulator.submit(source: 10, value: "top")
        XCTAssertNil(accumulator.takeCompleteFrame())
        accumulator.submit(source: 11, value: "bottom")
        XCTAssertEqual(accumulator.takeCompleteFrame(), [10: "top", 11: "bottom"])
    }

    func testNewestBandSupersedesOlderValueBeforeDrain() {
        var accumulator = AtomicBandFrameAccumulator<Int>(expectedSourceCount: 2)

        accumulator.submit(source: 1, value: 1)
        accumulator.submit(source: 1, value: 2)
        accumulator.submit(source: 2, value: 3)
        let frame = accumulator.takeCompleteFrame()

        XCTAssertEqual(frame?[1], 2)
        XCTAssertEqual(frame?[2], 3)
    }

    func testStaticBandIsRetainedInNextAtomicSnapshot() {
        var accumulator = AtomicBandFrameAccumulator<Int>(expectedSourceCount: 2)

        accumulator.submit(source: 1, value: 1)
        XCTAssertNil(accumulator.takeCompleteFrame())
        accumulator.submit(source: 2, value: 2)
        XCTAssertEqual(accumulator.takeCompleteFrame(), [1: 1, 2: 2])
        XCTAssertNil(accumulator.takeCompleteFrame())

        accumulator.submit(source: 2, value: 3)
        XCTAssertEqual(accumulator.takeCompleteFrame(), [1: 1, 2: 3])
    }
}
