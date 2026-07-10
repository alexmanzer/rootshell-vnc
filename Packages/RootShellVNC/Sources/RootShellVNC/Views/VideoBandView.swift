import SwiftUI
import CoreVideo
import QuartzCore

/// GPU renderer for Apple's high-performance HEVC screen bands.
///
/// Each RTP SSRC is a horizontal band of the screen. This renderer shows each
/// band's decoded `CVPixelBuffer` directly, via an `IOSurface`-backed
/// `CALayer` positioned at the band's Y offset. That is a zero-copy path — the
/// GPU composites the layers, and nothing pushes a full-screen image through
/// the CPU or SwiftUI every frame (which is what pinned the CPU at 5K).
@MainActor
public final class VideoBandLayerRenderer {

    /// The layer the host view displays. Band sublayers are added here.
    public let containerLayer = CALayer()

    private var bandLayers: [UInt32: CALayer] = [:]
    private var bandBuffers: [UInt32: CVPixelBuffer] = [:] // retained so VideoToolbox can't recycle a displayed buffer
    private var previousBandBuffers: [UInt32: CVPixelBuffer] = [:] // retained one commit longer: WindowServer may still scan out the just-replaced surface
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

    public func reset() {
        for layer in bandLayers.values { layer.removeFromSuperlayer() }
        bandLayers.removeAll()
        bandBuffers.removeAll()
        previousBandBuffers.removeAll()
        replaceLayersOnNextFrame = false
    }

    public func beginStreamGeneration() {
        replaceLayersOnNextFrame = true
    }

    /// Push the latest independently updated screen bands in a single Core
    /// Animation transaction. `BandFrameCoalescer` coalesces only values already
    /// pending in the same main-thread hop; it never invents a cross-band frame
    /// boundary from timing or pixels.
    public func setBands(_ buffers: [UInt32: CVPixelBuffer]) {
        guard !buffers.isEmpty else { return }
        var needsLayout = false

        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animation — this is video
        if replaceLayersOnNextFrame {
            for layer in bandLayers.values { layer.removeFromSuperlayer() }
            bandLayers.removeAll()
            bandBuffers.removeAll()
            previousBandBuffers.removeAll()
            bandHeight = 0
            replaceLayersOnNextFrame = false
            needsLayout = true
        }
        for (ssrc, pixelBuffer) in buffers {
            // Keep the just-replaced buffer alive one extra commit: WindowServer
            // can still be scanning out its IOSurface this frame, and releasing
            // it returns it to VideoToolbox's pool for immediate overwrite.
            previousBandBuffers[ssrc] = bandBuffers[ssrc]
            bandBuffers[ssrc] = pixelBuffer
            bandHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

            let layer: CALayer
            if let existing = bandLayers[ssrc] {
                layer = existing
            } else {
                layer = CALayer()
                layer.contentsGravity = .resize
                layer.masksToBounds = true
                layer.contentsScale = pixelScale
                containerLayer.addSublayer(layer)
                bandLayers[ssrc] = layer
                needsLayout = true // a new band changes the tiling
            }

            if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
                // VideoToolbox recycles a small pool of buffers, so the SAME
                // IOSurface object comes back every few frames. Core Animation
                // only re-composites `contents` when the object IDENTITY
                // changes — reassigning the identical surface is a no-op, and
                // the layer keeps showing whatever mix of old and newly-decoded
                // pixels the surface holds ("flicker" + shredded macroblocks
                // under motion). Rebind via nil so every frame is composited.
                if (layer.contents as AnyObject?) === surface {
                    layer.contents = nil
                }
                layer.contents = surface
            } else {
                layer.contents = pixelBuffer
            }
        }
        CATransaction.commit()

        if needsLayout { layout() }
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
            // Show only the top `validNative` rows of the band (drop the padding).
            let fraction = validNative / nativeBandHeight
            entry.value.contentsRect = CGRect(x: 0, y: 0, width: 1, height: fraction)
            entry.value.frame = CGRect(
                x: 0, y: topNative * scale, width: fitWidth, height: validNative * scale)
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
