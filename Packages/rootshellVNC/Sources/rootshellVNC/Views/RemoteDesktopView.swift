import SwiftUI
import RFBProtocol

/// Displays the remote desktop and provides one input/viewport layer for both
/// Adaptive video and Full Quality framebuffer rendering.
public struct RemoteDesktopView: View {
    @Bindable var session: VNCSession
    @Environment(\.displayScale) private var displayScale

    @State private var viewport = RemoteViewportState()
    @State private var keyboardActive = false
    @State private var confirmPasswordSend = false
    @State private var keyboardCapture: VNCKeyboardCapture

    #if !canImport(UIKit)
    @State private var lastFallbackMagnification: CGFloat = 1
    @State private var fallbackDragRemotePoint: CGPoint?
    #endif

    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler
    private let isFullScreen: Bool
    private let toggleFullScreen: (() -> Void)?

    public init(
        session: VNCSession,
        keyboardCapture: VNCKeyboardCapture? = nil,
        isFullScreen: Bool = false,
        toggleFullScreen: (() -> Void)? = nil
    ) {
        self.session = session
        self._keyboardCapture = State(
            initialValue: keyboardCapture ?? VNCKeyboardCapture())
        self.isFullScreen = isFullScreen
        self.toggleFullScreen = toggleFullScreen
        self.touchHandler = TouchInputHandler(
            sendPointerEvent: { [session] buttonMask, x, y in
                session.sendPointerEvent(buttonMask: buttonMask, x: x, y: y)
            },
            sendScrollEvent: { [session] event in
                session.sendScrollEvent(event)
            },
            sendGestureEvent: { [session] event in
                session.sendGestureEvent(event)
            })
        self.keyboardHandler = KeyboardInputHandler(
            sendKeyEvent: { [session] downFlag, key in
                session.sendKeyEvent(downFlag: downFlag, key: key)
            })
    }

    public var body: some View {
        GeometryReader { geometry in
            let framebufferSize = CGSize(
                width: CGFloat(session.framebufferWidth),
                height: CGFloat(session.framebufferHeight))

            ZStack {
                Color.black
                    .ignoresSafeArea()

                desktopContent(in: geometry.size)
                    .scaleEffect(viewport.scale)
                    .offset(viewport.offset)

                if session.connectionState.isConnected,
                   framebufferSize.width > 0,
                   framebufferSize.height > 0 {
                    interactionLayer(
                        viewSize: geometry.size,
                        framebufferSize: framebufferSize)
                }

                viewportControls
            }
            .clipped()
            .confirmationDialog(
                "Type the saved password?",
                isPresented: $confirmPasswordSend,
                titleVisibility: .visible
            ) {
                Button("Type Password and Log In") {
                    session.sendLoginPassword()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The password will be typed into the remote computer, followed by Return.")
            }
            .onChange(of: geometry.size) { _, newSize in
                viewport.clampOffset(
                    viewSize: newSize,
                    framebufferSize: framebufferSize)
                updateRemoteDisplaySize(for: newSize)
            }
            .onChange(of: framebufferSize) { _, newSize in
                viewport.clampOffset(
                    viewSize: geometry.size,
                    framebufferSize: newSize)
            }
            .onAppear {
                updateRemoteDisplaySize(for: geometry.size)
            }
            .onChange(of: displayScale) { _, _ in
                updateRemoteDisplaySize(for: geometry.size)
            }
            .onChange(of: session.connectionState) { _, newState in
                if newState.isConnected {
                    updateRemoteDisplaySize(for: geometry.size)
                }
            }
            .onChange(of: session.configuration.displaySizingMode) { _, mode in
                if mode == .matchClient {
                    updateRemoteDisplaySize(for: geometry.size)
                }
            }
        }
    }

    @ViewBuilder
    private func desktopContent(in viewSize: CGSize) -> some View {
        if session.isHighPerformanceMode {
            #if canImport(UIKit)
            VideoBandView(renderer: session.videoBandRenderer)
                .frame(width: viewSize.width, height: viewSize.height)
            #else
            placeholderView
                .frame(width: viewSize.width, height: viewSize.height)
            #endif
        } else if let image = session.currentImage {
            Image(decorative: image, scale: 1)
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: viewSize.width, height: viewSize.height)
        } else {
            placeholderView
                .frame(width: viewSize.width, height: viewSize.height)
        }
    }

    @ViewBuilder
    private func interactionLayer(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> some View {
        #if canImport(UIKit)
        RemoteInteractionView(
            viewport: $viewport,
            keyboardActive: $keyboardActive,
            framebufferSize: framebufferSize,
            touchHandler: touchHandler,
            keyboardHandler: keyboardHandler,
            keyboardCapture: keyboardCapture,
            // Adaptive mode's video composites the server cursor; only the
            // classic framebuffer path adopts the remote shape locally.
            remoteCursor: session.isHighPerformanceMode ? nil : session.remoteCursor)
            .frame(width: viewSize.width, height: viewSize.height)
            .contentShape(Rectangle())
        #else
        Color.clear
            .contentShape(Rectangle())
            .gesture(fallbackTapGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize))
            .simultaneousGesture(fallbackDragGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize))
            .simultaneousGesture(fallbackMagnificationGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize))
        #endif
    }

    @ViewBuilder
    private var viewportControls: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Menu {
                    #if canImport(UIKit)
                    Button {
                        keyboardCapture.capture()
                        keyboardActive.toggle()
                    } label: {
                        Label(
                            keyboardActive ? "Hide Keyboard" : "Show Keyboard",
                            systemImage: keyboardActive
                                ? "keyboard.chevron.compact.down" : "keyboard")
                    }

                    Button {
                        keyboardCapture.toggle()
                        if !keyboardCapture.isCaptured {
                            keyboardActive = false
                        }
                    } label: {
                        Label(
                            keyboardCapture.isCaptured
                                ? "Release Keyboard Capture" : "Capture Keyboard",
                            systemImage: keyboardCapture.isCaptured
                                ? "keyboard.badge.ellipsis" : "keyboard")
                    }

                    Menu {
                        Button("Command-H") {
                            keyboardHandler.handleCommandTap("h")
                        }
                        Button("Command-M") {
                            keyboardHandler.handleCommandTap("m")
                        }
                    } label: {
                        Label(
                            "Send Command Shortcut",
                            systemImage: "command")
                    }
                    #endif

                    Button {
                        viewport.reset()
                    } label: {
                        Label("Fit Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(viewport.isIdentity)

                    if let toggleFullScreen {
                        Button(action: toggleFullScreen) {
                            Label(
                                isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                                systemImage: isFullScreen
                                    ? "arrow.down.right.and.arrow.up.left"
                                    : "arrow.up.left.and.arrow.down.right")
                        }
                    }

                    Divider()

                    Button {
                        confirmPasswordSend = true
                    } label: {
                        Label("Type User Password", systemImage: "key.fill")
                    }
                    .disabled(!session.canSendLoginPassword)

                    Divider()

                    Button(role: .destructive) {
                        session.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.bold))
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel("Remote Desktop Controls")
                .help("Remote Desktop Controls")
            }
            .padding(12)
        }
        .allowsHitTesting(true)
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            switch session.connectionState {
            case .connecting:
                ProgressView().controlSize(.large)
                Text("Connecting...").foregroundStyle(.secondary)
            case .connected:
                ProgressView().controlSize(.large)
                Text("Waiting for framebuffer...").foregroundStyle(.secondary)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Connection Failed").font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            case .disconnected:
                Image(systemName: "rectangle.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Disconnected").foregroundStyle(.secondary)
            case .idle, .disconnecting:
                Image(systemName: "desktopcomputer")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Active Connection").foregroundStyle(.secondary)
            }
        }
    }

    private func updateRemoteDisplaySize(for viewSize: CGSize) {
        session.updateRemoteDisplaySize(
            viewSize: viewSize,
            displayScale: displayScale)
    }

    #if !canImport(UIKit)
    private func fallbackTapGesture(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let point = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize) else { return }
                touchHandler.handleTap(x: point.x, y: point.y)
            }
    }

    private func fallbackDragGesture(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let point = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize) else { return }
                fallbackDragRemotePoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                touchHandler.handleDrag(x: point.x, y: point.y)
            }
            .onEnded { value in
                let mapped = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize)
                let finalPoint = mapped ?? fallbackDragRemotePoint.map({
                    (x: UInt16($0.x), y: UInt16($0.y))
                })
                fallbackDragRemotePoint = nil
                guard let finalPoint else { return }
                touchHandler.handleDragEnd(x: finalPoint.x, y: finalPoint.y)
            }
    }

    private func fallbackMagnificationGesture(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let incremental = value.magnification / lastFallbackMagnification
                viewport.zoom(
                    by: incremental,
                    around: value.startAnchor.point(in: viewSize),
                    viewSize: viewSize,
                    framebufferSize: framebufferSize)
                lastFallbackMagnification = value.magnification
            }
            .onEnded { _ in
                lastFallbackMagnification = 1
            }
    }

    private func remotePoint(
        _ point: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> (x: UInt16, y: UInt16)? {
        guard let mapped = viewport.framebufferPoint(
            for: point,
            viewSize: viewSize,
            framebufferSize: framebufferSize) else { return nil }
        return (UInt16(mapped.x), UInt16(mapped.y))
    }
    #endif
}

#if !canImport(UIKit)
private extension UnitPoint {
    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}
#endif
