import SwiftUI
import CoreVideo
import CoreMedia
import QuartzCore
import AVFoundation
import RFBTransport

/// GPU renderer for Apple's high-performance HEVC screen bands.
///
/// Each RTP SSRC is a horizontal band of the screen. This renderer shows each
/// band's decoded `CVPixelBuffer` through an `AVSampleBufferDisplayLayer`.
@MainActor
public final class VideoBandLayerRenderer {

    /// The layer the host view displays. Band sublayers are added here.
    public let containerLayer = CALayer()

    private var bandLayers: [UInt32: AVSampleBufferDisplayLayer] = [:]
    private var bandBuffers: [UInt32: CVPixelBuffer] = [:] // retained so VideoToolbox can't recycle a displayed buffer
    private var previousBandBuffers: [UInt32: CVPixelBuffer] = [:] // retained one commit longer so presentation can finish before reuse
    private var bandHeight: CGFloat = 0
    private var screenWidth: CGFloat = 0
    private var screenHeight: CGFloat = 0
    private var viewBounds: CGRect = .zero
    /// A media renegotiation can replace every SSRC. Retain the previous
    /// generation on screen while the server negotiates, then remove its
    /// layers in the same transaction that installs the first new frame.
    private var replaceLayersOnNextFrame = false
    /// Display pixel density. Hand-made CALayers default to 1.0, which renders
    /// at half resolution on a Retina display (blurry, "compressed"); this must
    /// track the screen's scale.
    private var pixelScale: CGFloat = 2
    private(set) var frameCommitCount: UInt64 = 0
    private(set) var streamGenerationCount: UInt64 = 0
    private(set) var lastCommitBandCount = 0
    private(set) var partialCommitCount: UInt64 = 0
    private var expectedBandCount = Int(AppleMediaVideoMode.negotiatedTilesPerFrame)

    var renderedBandCount: Int { bandBuffers.count }

    var renderedBandDimensions: [(width: Int, height: Int)] {
        bandBuffers.values.map {
            (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0))
        }
    }

    public init() {
        containerLayer.masksToBounds = true
        containerLayer.contentsScale = pixelScale
    }

    /// Set the backing scale to the host display's scale so the decoded frames
    /// render at native pixel density.
    public func setPixelScale(_ scale: CGFloat) {
        guard scale > 0, scale != pixelScale else { return }
        pixelScale = scale
        containerLayer.contentsScale = scale
        for layer in bandLayers.values { layer.contentsScale = scale }
    }

    public func setScreenSize(width: Int, height: Int) {
        screenWidth = CGFloat(width)
        screenHeight = CGFloat(height)
        layout()
    }

    public func configureExpectedBandCount(_ count: Int) {
        expectedBandCount = max(1, count)
    }

    public func reset() {
        for layer in bandLayers.values {
            layer.sampleBufferRenderer.flush(
                removingDisplayedImage: true,
                completionHandler: nil)
            layer.removeFromSuperlayer()
        }
        bandLayers.removeAll()
        bandBuffers.removeAll()
        previousBandBuffers.removeAll()
        replaceLayersOnNextFrame = false
    }

    public func beginStreamGeneration(
        expectedBandCount: Int = Int(AppleMediaVideoMode.negotiatedTilesPerFrame)
    ) {
        streamGenerationCount &+= 1
        self.expectedBandCount = expectedBandCount
        replaceLayersOnNextFrame = true
    }

    /// Push a synchronized screen-band set in one Core Animation transaction.
    /// `BandFrameCoalescer` freezes a set after every active band advances, with
    /// a short bounded fallback for a genuinely static/change-gated band.
    public func setBands(_ buffers: [UInt32: CVPixelBuffer]) {
        guard !buffers.isEmpty else { return }
        frameCommitCount &+= 1
        lastCommitBandCount = buffers.count
        if buffers.count != expectedBandCount {
            partialCommitCount &+= 1
        }
        var needsLayout = false

        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animation — this is video
        if replaceLayersOnNextFrame {
            for layer in bandLayers.values {
                layer.sampleBufferRenderer.flush(
                    removingDisplayedImage: true,
                    completionHandler: nil)
                layer.removeFromSuperlayer()
            }
            bandLayers.removeAll()
            bandBuffers.removeAll()
            previousBandBuffers.removeAll()
            bandHeight = 0
            replaceLayersOnNextFrame = false
            needsLayout = true
        }
        for (ssrc, pixelBuffer) in buffers {
            // Keep the just-replaced buffer alive for one extra commit so
            // presentation finishes before it returns to the decoder pool.
            previousBandBuffers[ssrc] = bandBuffers[ssrc]
            bandBuffers[ssrc] = pixelBuffer
            bandHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

            let layer: AVSampleBufferDisplayLayer
            if let existing = bandLayers[ssrc] {
                layer = existing
            } else {
                layer = AVSampleBufferDisplayLayer()
                layer.videoGravity = .resize
                layer.masksToBounds = true
                layer.contentsScale = pixelScale
                containerLayer.addSublayer(layer)
                bandLayers[ssrc] = layer
                needsLayout = true
            }

            let videoRenderer = layer.sampleBufferRenderer
            if videoRenderer.status == .failed {
                videoRenderer.flush()
            }
            if let sampleBuffer = Self.makeDisplaySample(from: pixelBuffer) {
                videoRenderer.enqueue(sampleBuffer)
            }
        }
        CATransaction.commit()

        if needsLayout { layout() }
    }

    /// Wrap an already-decoded image buffer without copying its pixels. The
    /// display-immediately attachment lets the coalescer control cadence while
    /// AVFoundation performs the correct YUV conversion and surface lifetime
    /// management.
    private static func makeDisplaySample(
        from pixelBuffer: CVPixelBuffer
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else {
            return nil
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(
                    kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    /// The host view's bounds. Drives aspect-fit layout.
    public func setViewBounds(_ bounds: CGRect) {
        viewBounds = bounds
        layout()
    }

    /// Position the bands. The coded band height need not divide the negotiated
    /// framebuffer height, so the final coded band can extend below the desktop.
    /// Clip it by geometry to the negotiated height; no pixel inspection is
    /// involved.
    public func layout() {
        guard screenWidth > 0, screenHeight > 0, viewBounds.width > 0, viewBounds.height > 0 else { return }
        let nativeBandHeight = bandHeight > 0 ? bandHeight : screenHeight

        // Aspect-fit the native screen into the view.
        let scale = min(viewBounds.width / screenWidth, viewBounds.height / screenHeight)
        let fitWidth = screenWidth * scale
        let fitHeight = screenHeight * scale
        let originX = viewBounds.minX + (viewBounds.width - fitWidth) / 2
        let originY = viewBounds.minY + (viewBounds.height - fitHeight) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = CGRect(x: originX, y: originY, width: fitWidth, height: fitHeight)
        for (rank, entry) in bandLayers.sorted(by: { $0.key < $1.key }).enumerated() {
            let topNative = CGFloat(rank) * nativeBandHeight
            let validNative = min(nativeBandHeight, screenHeight - topNative)
            if validNative <= 0 {
                entry.value.isHidden = true
                continue
            }
            entry.value.isHidden = false
            // Keep every decoded band at its coded height. The last HEVC band
            // often contains padding below the negotiated desktop (for
            // example, 4 x 480 coded rows for a 1860-row screen). Shrinking
            // that 480-row sample into the remaining 420 rows displays and
            // resamples the padding, which shows up as a flickering bottom
            // tile. The container already clips to the exact desktop height,
            // so extend the final layer past its lower edge and let ordinary
            // layer clipping discard the padded rows at 1:1 geometry.
            entry.value.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            entry.value.frame = CGRect(
                x: 0,
                y: topNative * scale,
                width: fitWidth,
                height: nativeBandHeight * scale)
        }
        CATransaction.commit()
    }
}

#if canImport(UIKit)
import UIKit

/// Hosts a ``VideoBandLayerRenderer`` and keeps its container layer sized.
private final class BandHostView: UIView {
    let renderer: VideoBandLayerRenderer

    init(renderer: VideoBandLayerRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(renderer.containerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        if scale > 0 { renderer.setPixelScale(scale) }
        renderer.setViewBounds(bounds)
    }
}

/// SwiftUI wrapper that displays a session's decoded screen bands on the GPU.
public struct VideoBandView: UIViewRepresentable {
    private let renderer: VideoBandLayerRenderer

    public init(renderer: VideoBandLayerRenderer) {
        self.renderer = renderer
    }

    public func makeUIView(context: Context) -> UIView {
        BandHostView(renderer: renderer)
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
