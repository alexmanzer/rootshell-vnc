import Foundation
import CoreGraphics
import RFBProtocol

/// Thread-safe framebuffer backed by a CGContext.
/// Uses NSLock (not actor) for synchronous read access from the render path.
public final class Framebuffer: @unchecked Sendable {

    // MARK: - Public properties

    public private(set) var width: Int
    public private(set) var height: Int
    public let bytesPerPixel: Int
    public private(set) var bytesPerRow: Int

    // MARK: - Private state

    private let lock = NSLock()
    private var pixelData: UnsafeMutableRawPointer
    private var context: CGContext
    private let colorSpace: CGColorSpace
    private let bitmapInfo: UInt32
    private let bitsPerComponent: Int

    /// Take a consistent geometry snapshot while resize may be running on the
    /// render queue.
    package var size: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return CGSize(width: width, height: height)
    }

    // MARK: - Init

    /// Create a framebuffer with the given dimensions.
    public init(width: Int, height: Int, pixelFormat: PixelFormat) {
        precondition(width > 0 && height > 0, "Framebuffer dimensions must be positive")

        self.width = width
        self.height = height
        self.bytesPerPixel = pixelFormat.bytesPerPixel
        self.bytesPerRow = width * pixelFormat.bytesPerPixel
        self.colorSpace = CGColorSpaceCreateDeviceRGB()

        if pixelFormat.bytesPerPixel == 2 {
            // XRGB1555 little-endian — wire pixels from a 16bpp "thousands"
            // session are stored (and displayed) without conversion.
            self.bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
            self.bitsPerComponent = 5
        } else {
            // BGRA format native to macOS/iOS
            self.bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            self.bitsPerComponent = 8
        }

        let byteCount = bytesPerRow * height
        self.pixelData = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt32>.alignment
        )
        // Zero-fill so we start with a black framebuffer
        pixelData.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        self.context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
    }

    deinit {
        pixelData.deallocate()
    }

    // MARK: - Write operations

    /// Perform one compound render operation while holding the framebuffer
    /// lock. ZRLE consists of hundreds or thousands of 64×64 tiles; exposing a
    /// scoped buffer avoids acquiring the lock once per tile (or once per
    /// palette row) while keeping the raw storage private and thread-safe.
    func withUnsafeMutablePixelBytes<Result>(
        _ body: (
            UnsafeMutableRawPointer,
            Int,
            Int,
            Int,
            Int
        ) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(pixelData, width, height, bytesPerRow, bytesPerPixel)
    }

    /// Write raw pixel data for a rectangle region. Thread-safe.
    public func update(x: Int, y: Int, width w: Int, height h: Int, data: Data) {
        guard w > 0, h > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        let srcBytesPerRow = w * bytesPerPixel
        data.withUnsafeBytes { srcBuffer in
            guard let srcBase = srcBuffer.baseAddress else { return }
            for row in 0 ..< h {
                let dstY = y + row
                guard dstY >= 0, dstY < self.height else { continue }

                let srcOffset = row * srcBytesPerRow
                let dstOffset = dstY * self.bytesPerRow + x * self.bytesPerPixel

                let copyBytes = min(srcBytesPerRow, (self.width - x) * self.bytesPerPixel)
                guard copyBytes > 0 else { continue }
                guard srcOffset + copyBytes <= srcBuffer.count else { continue }

                memcpy(
                    pixelData.advanced(by: dstOffset),
                    srcBase.advanced(by: srcOffset),
                    copyBytes
                )
            }
        }
    }

    /// Copy a rectangle from one position to another. Thread-safe.
    /// Handles overlapping regions correctly. Clips to framebuffer bounds.
    public func copyRect(srcX: Int, srcY: Int, dstX: Int, dstY: Int, width w: Int, height h: Int) {
        guard w > 0, h > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        // Clip to framebuffer bounds to prevent out-of-bounds access
        let clippedW = min(w, min(width - srcX, width - dstX))
        let clippedH = min(h, min(height - srcY, height - dstY))
        guard clippedW > 0, clippedH > 0,
              srcX >= 0, srcY >= 0, dstX >= 0, dstY >= 0,
              srcX + clippedW <= width, srcY + clippedH <= height,
              dstX + clippedW <= width, dstY + clippedH <= height else {
            return
        }

        let rowBytes = clippedW * bytesPerPixel

        // Determine copy order to handle overlapping regions
        if dstY > srcY {
            // Copy bottom-to-top to avoid overwriting source data
            for row in stride(from: clippedH - 1, through: 0, by: -1) {
                let srcOffset = (srcY + row) * bytesPerRow + srcX * bytesPerPixel
                let dstOffset = (dstY + row) * bytesPerRow + dstX * bytesPerPixel
                memmove(
                    pixelData.advanced(by: dstOffset),
                    pixelData.advanced(by: srcOffset),
                    rowBytes
                )
            }
        } else {
            for row in 0 ..< clippedH {
                let srcOffset = (srcY + row) * bytesPerRow + srcX * bytesPerPixel
                let dstOffset = (dstY + row) * bytesPerRow + dstX * bytesPerPixel
                memmove(
                    pixelData.advanced(by: dstOffset),
                    pixelData.advanced(by: srcOffset),
                    rowBytes
                )
            }
        }
    }

    /// Fill a rectangle with a solid color. Thread-safe.
    /// `pixel` should contain exactly `bytesPerPixel` bytes representing the fill color.
    public func fillRect(x: Int, y: Int, width w: Int, height h: Int, pixel: Data) {
        guard w > 0, h > 0,
              pixel.count >= bytesPerPixel else { return }

        lock.lock()
        defer { lock.unlock() }

        pixel.withUnsafeBytes { pixelBuffer in
            guard let pixelBase = pixelBuffer.baseAddress else { return }
            let startX = max(0, x)
            let endX = min(self.width, x + w)
            let startY = max(0, y)
            let endY = min(self.height, y + h)
            guard startX < endX, startY < endY else { return }

            let rowBytes = (endX - startX) * bytesPerPixel
            let firstRowOffset = startY * bytesPerRow + startX * bytesPerPixel
            let firstRow = pixelData.advanced(by: firstRowOffset)

            // Seed one pixel, then double the initialized span. A 64-pixel
            // solid ZRLE tile takes six copies instead of 4096 tiny memcpys.
            memcpy(firstRow, pixelBase, bytesPerPixel)
            var initializedBytes = bytesPerPixel
            while initializedBytes < rowBytes {
                let copyBytes = min(initializedBytes, rowBytes - initializedBytes)
                memcpy(firstRow.advanced(by: initializedBytes), firstRow, copyBytes)
                initializedBytes += copyBytes
            }

            // Every later scanline is identical to the first.
            if endY - startY > 1 {
                for row in (startY + 1) ..< endY {
                    let destination = pixelData.advanced(
                        by: row * bytesPerRow + startX * bytesPerPixel)
                    memcpy(destination, firstRow, rowBytes)
                }
            }
        }
    }

    // MARK: - Read operations

    /// Create a CGImage snapshot of the current framebuffer. Thread-safe.
    public func createImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return context.makeImage()
    }

    /// Get the raw pixel data for a region (for testing). Thread-safe.
    public func getPixels(x: Int, y: Int, width w: Int, height h: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }

        let rowBytes = w * bytesPerPixel
        var result = Data(capacity: rowBytes * h)

        for row in 0 ..< h {
            let srcY = y + row
            guard srcY >= 0, srcY < self.height else {
                // Out of bounds row: write zeros
                result.append(contentsOf: [UInt8](repeating: 0, count: rowBytes))
                continue
            }

            let srcOffset = srcY * bytesPerRow + x * bytesPerPixel
            let copyBytes = min(rowBytes, (self.width - x) * bytesPerPixel)

            if copyBytes > 0 {
                let rowData = Data(
                    bytes: pixelData.advanced(by: srcOffset),
                    count: copyBytes
                )
                result.append(rowData)
                if copyBytes < rowBytes {
                    result.append(contentsOf: [UInt8](repeating: 0, count: rowBytes - copyBytes))
                }
            } else {
                result.append(contentsOf: [UInt8](repeating: 0, count: rowBytes))
            }
        }

        return result
    }

    // MARK: - Resize

    /// Resize the framebuffer (e.g., when server sends DesktopSize pseudo-encoding).
    public func resize(width newWidth: Int, height newHeight: Int) {
        precondition(newWidth > 0 && newHeight > 0, "Framebuffer dimensions must be positive")

        lock.lock()
        defer { lock.unlock() }

        guard newWidth != width || newHeight != height else { return }

        let newBytesPerRow = newWidth * bytesPerPixel
        let newByteCount = newBytesPerRow * newHeight

        let newPixelData = UnsafeMutableRawPointer.allocate(
            byteCount: newByteCount,
            alignment: MemoryLayout<UInt32>.alignment
        )
        newPixelData.initializeMemory(as: UInt8.self, repeating: 0, count: newByteCount)

        // Copy existing pixel data that fits within the new dimensions
        let copyWidth = min(width, newWidth)
        let copyHeight = min(height, newHeight)
        let copyRowBytes = copyWidth * bytesPerPixel

        for row in 0 ..< copyHeight {
            let srcOffset = row * bytesPerRow
            let dstOffset = row * newBytesPerRow
            memcpy(
                newPixelData.advanced(by: dstOffset),
                pixelData.advanced(by: srcOffset),
                copyRowBytes
            )
        }

        // Free old buffer
        pixelData.deallocate()

        // Update state
        pixelData = newPixelData
        width = newWidth
        height = newHeight
        bytesPerRow = newBytesPerRow

        context = CGContext(
            data: pixelData,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: newBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
    }
}
