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
        let size = RemoteDisplaySize.explicit(pixelSize: CGSize(width: 2560, height: 1440))
        XCTAssertEqual(size?.pixelWidth, 2560)
        XCTAssertEqual(size?.pixelHeight, 1440)
        XCTAssertEqual(size?.pointWidth, 1280)
        XCTAssertEqual(size?.pointHeight, 720)
    }

    func testUsesTwoTimesBackingOnlyForModesMacOSAccepts() {
        // Accepted and refused 2× modes, measured against macOS 26.7.1.
        let hiDPI = [CGSize(width: 1600, height: 1056), CGSize(width: 1920, height: 1072),
                     CGSize(width: 1184, height: 1728), CGSize(width: 1728, height: 1184)]
        let oneTimes = [CGSize(width: 1280, height: 720), CGSize(width: 1152, height: 784),
                        CGSize(width: 1584, height: 1200), CGSize(width: 1920, height: 1040),
                        CGSize(width: 976, height: 2112), CGSize(width: 672, height: 1360)]
        for pixels in hiDPI {
            let size = RemoteDisplaySize.explicit(pixelSize: pixels)
            XCTAssertEqual(size?.pointWidth, UInt16(pixels.width / 2), "\(pixels)")
            XCTAssertEqual(size?.pointHeight, UInt16(pixels.height / 2), "\(pixels)")
        }
        for pixels in oneTimes {
            let size = RemoteDisplaySize.explicit(pixelSize: pixels)
            XCTAssertEqual(size?.pixelWidth, UInt16(pixels.width), "\(pixels)")
            XCTAssertEqual(size?.pointWidth, UInt16(pixels.width), "\(pixels)")
            XCTAssertEqual(size?.pointHeight, UInt16(pixels.height), "\(pixels)")
        }
    }

    func testRejectsInvalidUnalignedAndOverBudgetSizes() {
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 720),
                     CGSize(width: 1280, height: CGFloat.nan), CGSize(width: 1920, height: 1080),
                     CGSize(width: 8192, height: 720), CGSize(width: 4096, height: 4096)] {
            XCTAssertNil(RemoteDisplaySize.explicit(pixelSize: size))
        }
    }
}
