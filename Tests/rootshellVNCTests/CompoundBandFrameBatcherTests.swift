import XCTest
@testable import rootshellVNC

final class AtomicBandFrameAccumulatorTests: XCTestCase {
    func testDecodedBandTrackerResetDropsRetiredGenerationSources() {
        let tracker = DecodedBandTracker()
        tracker.record(10)
        tracker.record(11)
        XCTAssertEqual(tracker.count, 2)

        tracker.reset()
        tracker.record(20)

        XCTAssertEqual(tracker.count, 1)
        XCTAssertEqual(tracker.frameCount, 1)
    }

    func testDoesNotPublishPartialCompoundFrame() {
        var accumulator = AtomicBandFrameAccumulator<String>(expectedSourceCount: 2)

        accumulator.submit(source: 10, value: "top")
        XCTAssertNil(accumulator.takeSynchronizedFrame())
        accumulator.submit(source: 11, value: "bottom")
        XCTAssertEqual(accumulator.takeSynchronizedFrame(), [10: "top", 11: "bottom"])
    }

    func testFourBandNativeProfilePublishesOnlyCompleteFrames() {
        var accumulator = AtomicBandFrameAccumulator<String>(expectedSourceCount: 4)

        accumulator.submit(source: 10, value: "one")
        accumulator.submit(source: 11, value: "two")
        accumulator.submit(source: 12, value: "three")
        XCTAssertNil(accumulator.takeSynchronizedFrame())

        accumulator.submit(source: 13, value: "four")
        XCTAssertEqual(accumulator.takeSynchronizedFrame(), [
            10: "one",
            11: "two",
            12: "three",
            13: "four",
        ])
    }

    func testNewestBandSupersedesOlderValueBeforeDrain() {
        var accumulator = AtomicBandFrameAccumulator<Int>(expectedSourceCount: 2)

        accumulator.submit(source: 1, value: 1)
        accumulator.submit(source: 1, value: 2)
        accumulator.submit(source: 2, value: 3)
        let frame = accumulator.takeSynchronizedFrame()

        XCTAssertEqual(frame?[1], 2)
        XCTAssertEqual(frame?[2], 3)
    }

    func testSingleDirtyBandWaitsForBoundedFallback() {
        var accumulator = AtomicBandFrameAccumulator<Int>(expectedSourceCount: 2)

        accumulator.submit(source: 1, value: 1)
        XCTAssertNil(accumulator.takeSynchronizedFrame())
        accumulator.submit(source: 2, value: 2)
        XCTAssertEqual(accumulator.takeSynchronizedFrame(), [1: 1, 2: 2])
        XCTAssertNil(accumulator.takeSynchronizedFrame())

        accumulator.submit(source: 2, value: 3)
        XCTAssertNil(accumulator.takeSynchronizedFrame())
        XCTAssertEqual(
            accumulator.takeLatestPendingSnapshot(),
            [1: 1, 2: 3])
    }

    func testReadyFrameCannotBeTornByNextBandCallback() {
        var accumulator = AtomicBandFrameAccumulator<Int>(expectedSourceCount: 2)

        accumulator.submit(source: 1, value: 10)
        accumulator.submit(source: 2, value: 20)
        accumulator.submit(source: 1, value: 11)

        XCTAssertEqual(
            accumulator.takeSynchronizedFrame(),
            [1: 10, 2: 20])
        XCTAssertNil(accumulator.takeSynchronizedFrame())

        accumulator.submit(source: 2, value: 21)
        XCTAssertEqual(
            accumulator.takeSynchronizedFrame(),
            [1: 11, 2: 21])
    }
}
