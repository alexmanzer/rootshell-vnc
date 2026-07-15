import Foundation
import CoreGraphics
import RFBProtocol

/// A decoded remote cursor shape from the Cursor (-239) pseudo-encoding.
/// The pointer itself stays local (system pointer); this only carries the
/// shape the remote UI wants shown (I-beam, resize arrows, ...).
public struct RemoteCursor: @unchecked Sendable {
    public let image: CGImage
    /// Hotspot in cursor-image pixels (from the rect's x/y fields).
    public let hotspotX: Int
    public let hotspotY: Int
    /// Silhouette of the visible cursor pixels, hotspot at the origin, in
    /// cursor-image pixel units. UIPointerShape has no image variant, so the
    /// system pointer adopts this path instead.
    public let shapePath: CGPath

    public var width: Int { image.width }
    public var height: Int { image.height }
}

/// Outcome of a Cursor pseudo-encoding rect: either a new shape or an
/// explicit empty rect, which means "no cursor" (hide / revert to default).
public enum RemoteCursorUpdate: @unchecked Sendable {
    case shape(RemoteCursor)
    case hidden
}

public enum RemoteCursorDecoder {

    /// Decode a Cursor pseudo-encoding payload: width*height pixels in the
    /// negotiated pixel format followed by a left-to-right, MSB-first
    /// bitmask of ((width+7)/8) bytes per row. Returns nil for malformed
    /// payloads (the shape is cosmetic — never fail the update over it).
    public static func decode(
        rect: FramebufferRect,
        data: Data,
        pixelFormat: PixelFormat
    ) -> RemoteCursorUpdate? {
        let width = Int(rect.width)
        let height = Int(rect.height)
        guard width > 0, height > 0 else { return .hidden }

        if rect.encoding == .xCursor {
            return decodeXCursor(rect: rect, data: data)
        }

        let bytesPerPixel = pixelFormat.bytesPerPixel
        guard bytesPerPixel == 4 else { return nil }
        let pixelBytes = width * height * bytesPerPixel
        let maskRowBytes = (width + 7) / 8
        guard data.count >= pixelBytes + maskRowBytes * height else { return nil }

        let redShift = Int(pixelFormat.redShift)
        let greenShift = Int(pixelFormat.greenShift)
        let blueShift = Int(pixelFormat.blueShift)
        let bigEndian = pixelFormat.bigEndian

        // Straight (non-premultiplied would need alphaInfo .last; alpha is
        // 0 or 255 here so premultiplied and straight coincide) RGBA output.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let shapePath = CGMutablePath()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            let pixels = base
            let mask = base + pixelBytes
            for y in 0..<height {
                var runStart: Int?
                func closeRun(at endX: Int) {
                    guard let start = runStart else { return }
                    runStart = nil
                    shapePath.addRect(CGRect(
                        x: start - Int(rect.x),
                        y: y - Int(rect.y),
                        width: endX - start,
                        height: 1))
                }
                for x in 0..<width {
                    let index = y * width + x
                    let src = pixels + index * bytesPerPixel
                    let value: UInt32
                    if bigEndian {
                        value = UInt32(src.load(fromByteOffset: 0, as: UInt8.self)) << 24
                            | UInt32(src.load(fromByteOffset: 1, as: UInt8.self)) << 16
                            | UInt32(src.load(fromByteOffset: 2, as: UInt8.self)) << 8
                            | UInt32(src.load(fromByteOffset: 3, as: UInt8.self))
                    } else {
                        value = UInt32(src.load(fromByteOffset: 3, as: UInt8.self)) << 24
                            | UInt32(src.load(fromByteOffset: 2, as: UInt8.self)) << 16
                            | UInt32(src.load(fromByteOffset: 1, as: UInt8.self)) << 8
                            | UInt32(src.load(fromByteOffset: 0, as: UInt8.self))
                    }
                    let maskByte = mask.load(
                        fromByteOffset: y * maskRowBytes + x / 8, as: UInt8.self)
                    let visible = maskByte & (0x80 >> UInt8(x % 8)) != 0
                    if visible {
                        if runStart == nil { runStart = x }
                    } else {
                        closeRun(at: x)
                    }

                    let out = index * 4
                    rgba[out] = UInt8((value >> UInt32(redShift)) & 0xFF)
                    rgba[out + 1] = UInt8((value >> UInt32(greenShift)) & 0xFF)
                    rgba[out + 2] = UInt8((value >> UInt32(blueShift)) & 0xFF)
                    rgba[out + 3] = visible ? 0xFF : 0x00
                }
                closeRun(at: width)
            }
        }
        guard !shapePath.isEmpty else { return .hidden }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent)
        else { return nil }

        return .shape(RemoteCursor(
            image: image,
            hotspotX: Int(rect.x),
            hotspotY: Int(rect.y),
            shapePath: shapePath.copy() ?? shapePath))
    }

    /// Decode TightVNC's XCursor (-240) payload. Its first six bytes are
    /// foreground/background RGB triplets; source and mask bitmaps follow.
    private static func decodeXCursor(
        rect: FramebufferRect,
        data: Data
    ) -> RemoteCursorUpdate? {
        let width = Int(rect.width)
        let height = Int(rect.height)
        let rowBytes = (width + 7) / 8
        let bitmapBytes = rowBytes * height
        guard data.count >= 6 + bitmapBytes * 2 else { return nil }

        let foreground = (data[0], data[1], data[2])
        let background = (data[3], data[4], data[5])
        let sourceOffset = 6
        let maskOffset = sourceOffset + bitmapBytes
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let shapePath = CGMutablePath()

        for y in 0..<height {
            var runStart: Int?
            func closeRun(at endX: Int) {
                guard let start = runStart else { return }
                runStart = nil
                shapePath.addRect(CGRect(
                    x: start - Int(rect.x),
                    y: y - Int(rect.y),
                    width: endX - start,
                    height: 1))
            }

            for x in 0..<width {
                let byteIndex = y * rowBytes + x / 8
                let bit: UInt8 = 0x80 >> UInt8(x % 8)
                let visible = data[maskOffset + byteIndex] & bit != 0
                let usesForeground = data[sourceOffset + byteIndex] & bit != 0
                let color = usesForeground ? foreground : background
                let output = (y * width + x) * 4
                rgba[output] = color.0
                rgba[output + 1] = color.1
                rgba[output + 2] = color.2
                rgba[output + 3] = visible ? 0xFF : 0x00

                if visible {
                    if runStart == nil { runStart = x }
                } else {
                    closeRun(at: x)
                }
            }
            closeRun(at: width)
        }

        guard !shapePath.isEmpty,
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent)
        else { return shapePath.isEmpty ? .hidden : nil }

        return .shape(RemoteCursor(
            image: image,
            hotspotX: Int(rect.x),
            hotspotY: Int(rect.y),
            shapePath: shapePath.copy() ?? shapePath))
    }
}
