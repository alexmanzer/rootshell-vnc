import CoreMedia
import CoreVideo
import XCTest
@testable import RFBRendering

final class DecodedFrameOrdererTests: XCTestCase {
    func testOutOfOrderCallbacksAreReleasedInSubmissionOrder() throws {
        let received = LockedSources()
        let orderer = VideoStreamManager.DecodedFrameOrderer { _, source in
            received.append(source)
        }
        let pixelBuffer = try makePixelBuffer()

        orderer.submit(
            pixelBuffer: pixelBuffer,
            pts: CMTime(value: 3_000, timescale: 90_000),
            ssrc: 11)
        XCTAssertEqual(received.values, [])

        orderer.submit(
            pixelBuffer: pixelBuffer,
            pts: CMTime(value: 0, timescale: 90_000),
            ssrc: 10)
        XCTAssertEqual(received.values, [10, 11])
    }

    func testSparseOutputSkipsMissingFrameAfterBoundedHold() throws {
        let deliveredSecond = expectation(description: "newer sparse frame delivered")
        let received = LockedSources()
        let orderer = VideoStreamManager.DecodedFrameOrderer { _, source in
            received.append(source)
            if source == 2 { deliveredSecond.fulfill() }
        }
        let pixelBuffer = try makePixelBuffer()

        orderer.submit(
            pixelBuffer: pixelBuffer,
            pts: CMTime(value: 0, timescale: 90_000),
            ssrc: 0)
        orderer.submit(
            pixelBuffer: pixelBuffer,
            pts: CMTime(value: 6_000, timescale: 90_000),
            ssrc: 2)

        wait(for: [deliveredSecond], timeout: 1)
        XCTAssertEqual(received.values, [0, 2])
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}

private final class LockedSources: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [UInt32] = []

    func append(_ source: UInt32) {
        lock.lock()
        sources.append(source)
        lock.unlock()
    }

    var values: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return sources
    }
}
