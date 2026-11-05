import CoreVideo
import XCTest
@testable import rootshellVNC

@MainActor
final class ComposedFrameObserverTests: XCTestCase {
    func testObserverReceivesEveryCommittedFrame() throws {
        let renderer = makeRenderer()
        var widths: [Int] = []
        renderer.onComposedFrame = { widths.append(CVPixelBufferGetWidth($0)) }

        renderer.setBands([1: try makeBuffer()])
        renderer.setBands([1: try makeBuffer()])

        XCTAssertEqual(widths, [128, 128])
        let shown = try XCTUnwrap(renderer.composedFrame)
        XCTAssertEqual(CVPixelBufferGetWidth(shown), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(shown), 96)
    }

    func testRemovedObserverReceivesNothing() throws {
        let renderer = makeRenderer()
        var count = 0
        renderer.onComposedFrame = { _ in count += 1 }
        renderer.setBands([1: try makeBuffer()])
        renderer.onComposedFrame = nil
        renderer.setBands([1: try makeBuffer()])
        XCTAssertEqual(count, 1)
    }

    func testFramesWaitForResumeAndResetClearsTheShownFrame() throws {
        let renderer = makeRenderer()
        var count = 0
        renderer.onComposedFrame = { _ in count += 1 }
        XCTAssertNil(renderer.composedFrame)

        renderer.setPresentationSuspended(true)
        renderer.setBands([1: try makeBuffer()])
        XCTAssertEqual(count, 0, "no frame is committed while suspended")
        renderer.setPresentationSuspended(false)
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(renderer.composedFrame)

        renderer.reset()
        XCTAssertNil(renderer.composedFrame)
    }

    /// A renderer composing 128×96 in a view of the same size.
    private func makeRenderer() -> VideoBandLayerRenderer {
        let renderer = VideoBandLayerRenderer()
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 128, height: 96))
        renderer.setScreenSize(width: 128, height: 96)
        return renderer
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 96,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}
