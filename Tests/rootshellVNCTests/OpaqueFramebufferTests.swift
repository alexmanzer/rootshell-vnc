import CoreGraphics
import Foundation
import RFBProtocol
import RFBRendering
import XCTest

final class OpaqueFramebufferTests: XCTestCase {
    func testUnusedWireByteDoesNotMakeDesktopTransparent() throws {
        for padding: UInt8 in [0, 64, 255] {
            let framebuffer = Framebuffer(width: 1, height: 1, pixelFormat: .bgra8888)
            framebuffer.update(x: 0, y: 0, width: 1, height: 1,
                               data: Data([32, 160, 224, padding]))
            let image = try XCTUnwrap(framebuffer.createImage())
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertEqual(pixel, [224, 160, 32, 255], "RFB depth-24 padding=\(padding)")
        }
    }
}
