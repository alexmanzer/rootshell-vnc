import CoreVideo
import XCTest
@testable import rootshellVNC

@MainActor
final class BandFrameRetirementTests: XCTestCase {
    func testResetRejectsQueuedAndLateFramesFromRetiredCoalescer() async throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setScreenSize(width: 128, height: 96)
        let old = BandFrameCoalescer(renderer: renderer, expectedSourceCount: 1)
        let buffer = try makeBuffer()
        old.submit(ssrc: 1, pixelBuffer: buffer)
        renderer.reset()
        old.submit(ssrc: 1, pixelBuffer: buffer)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(renderer.frameCommitCount, 0)
        XCTAssertEqual(renderer.renderedBandCount, 0)

        let replacement = BandFrameCoalescer(renderer: renderer, expectedSourceCount: 1)
        replacement.submit(ssrc: 2, pixelBuffer: buffer)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(renderer.frameCommitCount, 1)
        XCTAssertEqual(renderer.renderedBandCount, 1)
    }

    func testResetRejectsQueuedMediaGenerationHandoff() async throws {
        let renderer = VideoBandLayerRenderer()
        let old = BandFrameCoalescer(renderer: renderer, expectedSourceCount: 1)
        let before = renderer.streamGenerationCount
        old.beginStreamGeneration(3, expectedSourceCount: 1)
        renderer.reset()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(renderer.streamGenerationCount, before)
    }

    func testResetRejectsDelayedPartialBandFallback() async throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setScreenSize(width: 128, height: 192)
        renderer.configureExpectedBandCount(2)
        let old = BandFrameCoalescer(renderer: renderer, expectedSourceCount: 2)
        let buffer = try makeBuffer()
        old.submit(ssrc: 1, pixelBuffer: buffer)
        old.submit(ssrc: 2, pixelBuffer: buffer)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(renderer.frameCommitCount, 1)
        old.submit(ssrc: 1, pixelBuffer: buffer)
        renderer.reset()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(renderer.frameCommitCount, 1)
        XCTAssertEqual(renderer.renderedBandCount, 0)
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 96,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}
