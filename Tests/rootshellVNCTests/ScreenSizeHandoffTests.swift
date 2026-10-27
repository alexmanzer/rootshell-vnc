import CoreVideo
import XCTest
@testable import rootshellVNC

@MainActor
final class ScreenSizeHandoffTests: XCTestCase {
    func testSizeWithinAGenerationAppliesAtOnce() throws {
        let renderer = makeRenderer()
        renderer.setBands([1: try makeBuffer(width: 128)])
        renderer.setScreenSize(width: 64, height: 96)
        XCTAssertEqual(renderer.containerLayer.frame.width, 64)
    }

    func testNewSizeWaitsForTheFirstFrameOfTheNewGeneration() throws {
        let renderer = makeRenderer()
        var committedWidths: [Int] = []
        renderer.onFrameCommitted = { buffer, _ in committedWidths.append(CVPixelBufferGetWidth(buffer)) }
        renderer.setBands([1: try makeBuffer(width: 128)])

        renderer.beginStreamGeneration(expectedBandCount: 1)
        renderer.setScreenSize(width: 64, height: 96)
        XCTAssertEqual(renderer.containerLayer.frame.width, 128, "the old picture keeps its size")

        renderer.setBands([2: try makeBuffer(width: 64)])
        XCTAssertEqual(renderer.containerLayer.frame.width, 64)
        XCTAssertEqual(committedWidths, [128, 64])
    }

    func testLatestSizeWinsBeforeTheFirstFrame() throws {
        let renderer = makeRenderer()
        renderer.setBands([1: try makeBuffer(width: 128)])
        renderer.beginStreamGeneration(expectedBandCount: 1)
        renderer.setScreenSize(width: 96, height: 96)
        renderer.setScreenSize(width: 64, height: 96)
        renderer.setBands([2: try makeBuffer(width: 64)])
        XCTAssertEqual(renderer.containerLayer.frame.width, 64)
    }

    func testResetDropsAWaitingSize() throws {
        let renderer = makeRenderer()
        renderer.setBands([1: try makeBuffer(width: 128)])
        renderer.beginStreamGeneration(expectedBandCount: 1)
        renderer.setScreenSize(width: 64, height: 96)
        renderer.reset()
        renderer.setBands([1: try makeBuffer(width: 128)])
        XCTAssertEqual(renderer.containerLayer.frame.width, 128)
    }

    func testSuspendedHandoffLaysOutOnResume() throws {
        let renderer = makeRenderer()
        var committedWidths: [Int] = []
        renderer.onFrameCommitted = { buffer, _ in committedWidths.append(CVPixelBufferGetWidth(buffer)) }
        renderer.setBands([1: try makeBuffer(width: 128)])

        renderer.setPresentationSuspended(true)
        renderer.beginStreamGeneration(expectedBandCount: 1)
        renderer.setScreenSize(width: 64, height: 96)
        renderer.setBands([2: try makeBuffer(width: 64)])
        XCTAssertEqual(renderer.containerLayer.frame.width, 128, "no layer change while suspended")
        XCTAssertEqual(committedWidths, [128])

        renderer.setPresentationSuspended(false)
        XCTAssertEqual(renderer.containerLayer.frame.width, 64)
        XCTAssertEqual(committedWidths, [128, 64])
    }

    /// A renderer showing 128×96 in a 256×96 view: the picture is 128 points wide.
    private func makeRenderer() -> VideoBandLayerRenderer {
        let renderer = VideoBandLayerRenderer()
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 256, height: 96))
        renderer.setScreenSize(width: 128, height: 96)
        return renderer
    }

    private func makeBuffer(width: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 96,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}
