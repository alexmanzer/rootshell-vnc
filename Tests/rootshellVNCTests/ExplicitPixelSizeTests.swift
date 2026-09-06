import CoreGraphics
import CoreVideo
import XCTest
@testable import rootshellVNC

final class ExplicitPixelSizeTests: XCTestCase {
    @MainActor
    func testHostCallbackReportsCommittedGeometry() throws {
        let session = VNCSession()
        var size: CGSize?
        session.onVideoFrameCommitted = { size = $0 }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 128, 96,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        session.videoBandRenderer.setScreenSize(width: 128, height: 96)
        session.videoBandRenderer.setBands([1: try XCTUnwrap(buffer)])
        XCTAssertEqual(size, CGSize(width: 128, height: 96))
    }

    func testExactPixelsNeverDoubleOrRoundUp() {
        let size = RemoteDisplaySize.explicit(pixelSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(size?.pixelWidth, 1280)
        XCTAssertEqual(size?.pixelHeight, 720)
        XCTAssertEqual(size?.pointWidth, 1280)
    }

    func testRejectsInvalidUnalignedAndOverBudgetSizes() {
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 720),
                     CGSize(width: 1280, height: CGFloat.nan), CGSize(width: 1920, height: 1080),
                     CGSize(width: 8192, height: 720), CGSize(width: 4096, height: 4096)] {
            XCTAssertNil(RemoteDisplaySize.explicit(pixelSize: size))
        }
    }
}
