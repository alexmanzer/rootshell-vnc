import CoreGraphics
import CoreVideo
import XCTest
@testable import rootshellVNC

@MainActor
final class VNCBrightnessPresenterTests: XCTestCase {
    func testUnsupportedRuntimeForcesNeutralGain() {
        XCTAssertEqual(
            VNCBrightnessCapability.effectiveGain(2.0, supported: false),
            1.0)
    }

    func testSupportedRuntimeClampsGain() {
        XCTAssertEqual(
            VNCBrightnessCapability.effectiveGain(0.5, supported: true),
            1.0)
        XCTAssertEqual(
            VNCBrightnessCapability.effectiveGain(2.0, supported: true),
            2.0)
        XCTAssertEqual(
            VNCBrightnessCapability.effectiveGain(32.0, supported: true),
            16.0)
    }

    func testNeutralGainDoesNotCreateEDRSurface() throws {
        let presenter = VNCBrightnessPresenter(contentsGravity: .resizeAspect)
        presenter.setSource(try makeImage(), gain: 1.0)

        XCTAssertFalse(presenter.isPresentingBoostedContent)
        XCTAssertNil(presenter.presentedPixelFormat)
    }

    func testBoostUsesHalfFloatSurfaceWhenAvailable() throws {
        guard VNCBrightnessCapability.isEDRPresentationAvailable else { return }
        let presenter = VNCBrightnessPresenter(contentsGravity: .resizeAspect)
        presenter.setSource(try makeImage(), gain: 1.5)

        XCTAssertTrue(presenter.isPresentingBoostedContent)
        XCTAssertEqual(
            presenter.presentedPixelFormat,
            kCVPixelFormatType_64RGBAHalf)
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(
            CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
