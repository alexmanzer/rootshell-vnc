import SwiftUI
import RFBProtocol

/// SwiftUI view that displays the remote VNC desktop and handles user input.
///
/// This view renders the VNC framebuffer image and translates touch/mouse
/// gestures into RFB pointer events sent to the remote server.
///
/// Usage:
/// ```swift
/// RemoteDesktopView(session: vncSession)
/// ```
public struct RemoteDesktopView: View {

    // MARK: - Properties

    @Bindable var session: VNCSession

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastDragPosition: CGSize = .zero
    @State private var isPanning: Bool = false

    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler

    // MARK: - Init

    /// Create a remote desktop view bound to the given VNC session.
    ///
    /// - Parameter session: The active VNC session providing framebuffer images
    ///   and accepting input events.
    public init(session: VNCSession) {
        self.session = session
        self.touchHandler = TouchInputHandler(
            sendPointerEvent: { [session] buttonMask, x, y in
                session.sendPointerEvent(buttonMask: buttonMask, x: x, y: y)
            }
        )
        self.keyboardHandler = KeyboardInputHandler(
            sendKeyEvent: { [session] downFlag, key in
                session.sendKeyEvent(downFlag: downFlag, key: key)
            }
        )
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if session.isHighPerformanceMode {
                    #if canImport(UIKit)
                    // Zero-copy GPU rendering of the decoded HEVC screen bands.
                    VideoBandView(renderer: session.videoBandRenderer)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    #else
                    placeholderView
                    #endif
                } else if let image = session.currentImage {
                    framebufferImageView(image: image, in: geometry)
                } else {
                    placeholderView
                }
            }
            .clipped()
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
    }

    // MARK: - Subviews

    @ViewBuilder
    private func framebufferImageView(image: CGImage, in geometry: GeometryProxy) -> some View {
        let fbSize = CGSize(
            width: CGFloat(session.framebufferWidth),
            height: CGFloat(session.framebufferHeight)
        )
        let viewSize = geometry.size
        let fitScale = fitScale(framebufferSize: fbSize, viewSize: viewSize)

        // Use SwiftUI's resizable + fit to fill the available space,
        // then apply user zoom on top
        Image(decorative: image, scale: 1.0)
            .interpolation(.medium)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: viewSize.width, height: viewSize.height)
            .gesture(
                tapGesture(viewSize: viewSize, fbSize: fbSize, fitScale: fitScale)
            )
            .gesture(
                dragGesture(viewSize: viewSize, fbSize: fbSize, fitScale: fitScale)
            )
            .gesture(
                magnificationGesture()
            )
            #if os(macOS)
            .simultaneousGesture(
                scrollGesture(viewSize: viewSize, fbSize: fbSize, fitScale: fitScale)
            )
            #endif
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            switch session.connectionState {
            case .connecting:
                ProgressView()
                    .controlSize(.large)
                Text("Connecting...")
                    .foregroundStyle(.secondary)

            case .connected:
                ProgressView()
                    .controlSize(.large)
                Text("Waiting for framebuffer...")
                    .foregroundStyle(.secondary)

            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Connection Failed")
                    .font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

            case .disconnected:
                Image(systemName: "rectangle.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Disconnected")
                    .foregroundStyle(.secondary)

            case .idle, .disconnecting:
                Image(systemName: "desktopcomputer")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Active Connection")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Gestures

    private func tapGesture(
        viewSize: CGSize,
        fbSize: CGSize,
        fitScale: CGFloat
    ) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let fbPoint = viewToFramebuffer(
                    viewPoint: value.location,
                    viewSize: viewSize,
                    fbSize: fbSize,
                    fitScale: fitScale
                )
                guard let point = fbPoint else { return }
                touchHandler.handleTap(x: UInt16(point.x), y: UInt16(point.y))
            }
    }

    private func dragGesture(
        viewSize: CGSize,
        fbSize: CGSize,
        fitScale: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if isPanning {
                    // Two-finger pan: move the viewport
                    let delta = CGSize(
                        width: value.translation.width - lastDragPosition.width,
                        height: value.translation.height - lastDragPosition.height
                    )
                    offset = CGSize(
                        width: offset.width + delta.width,
                        height: offset.height + delta.height
                    )
                    lastDragPosition = value.translation
                } else {
                    // Single-finger drag: move the pointer
                    let fbPoint = viewToFramebuffer(
                        viewPoint: value.location,
                        viewSize: viewSize,
                        fbSize: fbSize,
                        fitScale: fitScale
                    )
                    guard let point = fbPoint else { return }
                    touchHandler.handleMove(x: UInt16(point.x), y: UInt16(point.y))
                }
            }
            .onEnded { _ in
                lastDragPosition = .zero
            }
    }

    private func magnificationGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = max(0.5, min(5.0, value.magnification))
                scale = newScale
            }
    }

    #if os(macOS)
    private func scrollGesture(
        viewSize: CGSize,
        fbSize: CGSize,
        fitScale: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .modifiers(.option)
            .onChanged { value in
                let fbPoint = viewToFramebuffer(
                    viewPoint: value.location,
                    viewSize: viewSize,
                    fbSize: fbSize,
                    fitScale: fitScale
                )
                guard let point = fbPoint else { return }
                let deltaY = value.translation.height - lastDragPosition.height
                lastDragPosition = CGSize(width: 0, height: value.translation.height)
                touchHandler.handleScroll(
                    x: UInt16(point.x),
                    y: UInt16(point.y),
                    deltaY: deltaY
                )
            }
            .onEnded { _ in
                lastDragPosition = .zero
            }
    }
    #endif

    // MARK: - Coordinate Conversion

    /// Convert a point in view coordinates to framebuffer coordinates.
    ///
    /// Returns `nil` if the point is outside the framebuffer area.
    private func viewToFramebuffer(
        viewPoint: CGPoint,
        viewSize: CGSize,
        fbSize: CGSize,
        fitScale: CGFloat
    ) -> CGPoint? {
        let effectiveScale = fitScale * scale

        // Calculate the displayed image size and position
        let displayedWidth = fbSize.width * effectiveScale
        let displayedHeight = fbSize.height * effectiveScale
        let imageOriginX = (viewSize.width - displayedWidth) / 2 + offset.width
        let imageOriginY = (viewSize.height - displayedHeight) / 2 + offset.height

        // Convert view point to image-relative coordinates
        let relativeX = viewPoint.x - imageOriginX
        let relativeY = viewPoint.y - imageOriginY

        // Convert to framebuffer coordinates
        let fbX = relativeX / effectiveScale
        let fbY = relativeY / effectiveScale

        // Clamp to framebuffer bounds
        guard fbX >= 0, fbX < fbSize.width,
              fbY >= 0, fbY < fbSize.height else {
            return nil
        }

        return CGPoint(x: fbX, y: fbY)
    }

    /// Calculate the scale factor to fit the framebuffer in the view
    /// while maintaining aspect ratio.
    private func fitScale(framebufferSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return 1.0 }
        let scaleX = viewSize.width / framebufferSize.width
        let scaleY = viewSize.height / framebufferSize.height
        return min(scaleX, scaleY)
    }
}
