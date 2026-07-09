import XCTest
@testable import RootShellVNC

final class LatestBandFrameAccumulatorTests: XCTestCase {
    func testActiveBandDoesNotWaitForStaticBands() {
        var accumulator = LatestBandFrameAccumulator<String>()

        accumulator.submit(source: 10, value: "top")
        let frame = accumulator.takeAll()

        XCTAssertEqual(frame, [10: "top"])
    }

    func testNewestBandSupersedesOlderValueBeforeDrain() {
        var accumulator = LatestBandFrameAccumulator<Int>()

        accumulator.submit(source: 1, value: 1)
        accumulator.submit(source: 1, value: 2)
        accumulator.submit(source: 2, value: 3)
        let frame = accumulator.takeAll()

        XCTAssertEqual(frame[1], 2)
        XCTAssertEqual(frame[2], 3)
    }

    func testDrainClearsOnlyPreviouslyStagedValues() {
        var accumulator = LatestBandFrameAccumulator<Int>()

        accumulator.submit(source: 1, value: 1)
        XCTAssertEqual(accumulator.takeAll(), [1: 1])
        XCTAssertTrue(accumulator.takeAll().isEmpty)

        accumulator.submit(source: 2, value: 2)
        XCTAssertEqual(accumulator.takeAll(), [2: 2])
    }
}
