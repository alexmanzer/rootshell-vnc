import SwiftUI
import RFBProtocol
#if canImport(UIKit)
import UIKit

private struct DockedKeyboardViewportMetrics: Equatable {
    var containerSize: CGSize = .zero
    var keyboardInset: CGFloat = 0

    var availableSize: CGSize {
        CGSize(
            width: containerSize.width,
            height: max(0, containerSize.height - keyboardInset))
    }

    func isApproximatelyEqual(
        to other: DockedKeyboardViewportMetrics
    ) -> Bool {
        abs(containerSize.width - other.containerSize.width) <= 0.5
            && abs(containerSize.height - other.containerSize.height) <= 0.5
            && abs(keyboardInset - other.keyboardInset) <= 0.5
    }
}
#endif

/// Chooses which layer owns keyboard and accessory clearance for the remote
/// viewport. Container apps with a shared pane layout can opt out of the
/// package spacer while the standalone view keeps automatic avoidance.
public enum VNCKeyboardAvoidanceMode: Equatable, Sendable {
    case automatic
    case hostManaged
}

/// Displays the remote desktop and provides one input/viewport layer for both
/// Adaptive video and Full Quality framebuffer rendering.
public struct RemoteDesktopView: View {
    @Bindable var session: VNCSession
    @Environment(\.displayScale) private var displayScale

    @State private var viewport = RemoteViewportState()
    @State private var keyboardActive = false
    @State private var confirmPasswordSend = false
    @State private var keyboardCapture: VNCKeyboardCapture
    #if canImport(UIKit)
    @State private var keyboardViewportMetrics = DockedKeyboardViewportMetrics()
    @State private var hardwareKeyboardAttached = false
    #endif

    #if !canImport(UIKit)
    @State private var lastFallbackMagnification: CGFloat = 1
    @State private var fallbackDragRemotePoint: CGPoint?
    #endif

    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler
    private let isFullScreen: Bool
    private let toggleFullScreen: (() -> Void)?
    private let hudMenuExtras: AnyView?
    private let keyboardAvoidanceMode: VNCKeyboardAvoidanceMode

    public init(
        session: VNCSession,
        keyboardCapture: VNCKeyboardCapture? = nil,
        isFullScreen: Bool = false,
        toggleFullScreen: (() -> Void)? = nil,
        keyboardAvoidanceMode: VNCKeyboardAvoidanceMode = .automatic
    ) {
        self.init(
            session: session,
            keyboardCapture: keyboardCapture,
            isFullScreen: isFullScreen,
            toggleFullScreen: toggleFullScreen,
            keyboardAvoidanceMode: keyboardAvoidanceMode,
            hudMenuExtras: nil)
    }

    /// Creates a remote desktop view whose HUD menu shows extra items between
    /// the built-in viewport controls and the password/disconnect actions.
    ///
    /// The extras are captured once at init and type-erased; container apps
    /// that want live state in these items should pass views that read their
    /// own `@Observable` models so the hosted menu re-renders on change.
    public init<MenuExtras: View>(
        session: VNCSession,
        keyboardCapture: VNCKeyboardCapture? = nil,
        isFullScreen: Bool = false,
        toggleFullScreen: (() -> Void)? = nil,
        keyboardAvoidanceMode: VNCKeyboardAvoidanceMode = .automatic,
        @ViewBuilder hudMenuExtras: () -> MenuExtras
    ) {
        self.init(
            session: session,
            keyboardCapture: keyboardCapture,
            isFullScreen: isFullScreen,
            toggleFullScreen: toggleFullScreen,
            keyboardAvoidanceMode: keyboardAvoidanceMode,
            hudMenuExtras: AnyView(hudMenuExtras()))
    }

    private init(
        session: VNCSession,
        keyboardCapture: VNCKeyboardCapture?,
        isFullScreen: Bool,
        toggleFullScreen: (() -> Void)?,
        keyboardAvoidanceMode: VNCKeyboardAvoidanceMode,
        hudMenuExtras: AnyView?
    ) {
        self.session = session
        self.hudMenuExtras = hudMenuExtras
        self._keyboardCapture = State(
            initialValue: keyboardCapture ?? VNCKeyboardCapture())
        self.isFullScreen = isFullScreen
        self.toggleFullScreen = toggleFullScreen
        self.keyboardAvoidanceMode = keyboardAvoidanceMode
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
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let framebufferSize = session.presentedFramebufferSize
                let framebufferOrigin = session.presentedFramebufferRegion?.origin ?? .zero

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
                            framebufferSize: framebufferSize,
                            framebufferOrigin: framebufferOrigin)
                    }

                    viewportControls

                    recoveryOverlay
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
                    #if !canImport(UIKit)
                    updateRemoteDisplaySize(for: newSize)
                    #endif
                }
                .onChange(of: framebufferSize) { _, newSize in
                    viewport.clampOffset(
                        viewSize: geometry.size,
                        framebufferSize: newSize)
                }
                .onAppear {
                    #if !canImport(UIKit)
                    updateRemoteDisplaySize(for: geometry.size)
                    #endif
                }
                .onChange(of: displayScale) { _, _ in
                    #if canImport(UIKit)
                    updateRemoteDisplaySizeFromMeasuredContainer()
                    #else
                    updateRemoteDisplaySize(for: geometry.size)
                    #endif
                }
                .onChange(of: session.connectionState) { _, newState in
                    if newState.isConnected {
                        #if canImport(UIKit)
                        updateRemoteDisplaySizeFromMeasuredContainer()
                        #else
                        updateRemoteDisplaySize(for: geometry.size)
                        #endif
                    }
                }
                .onChange(of: session.configuration.displaySizingMode) { _, mode in
                    if mode == .matchClient {
                        #if canImport(UIKit)
                        updateRemoteDisplaySizeFromMeasuredContainer()
                        #else
                        updateRemoteDisplaySize(for: geometry.size)
                        #endif
                    }
                }
            }

            #if canImport(UIKit)
            if keyboardAvoidanceMode == .automatic {
                Color.clear
                    .frame(height: keyboardViewportMetrics.keyboardInset)
                    .accessibilityHidden(true)
            }
            #endif
        }
        // Two-way sync with the host-visible keyboard request. The local
        // @State stays authoritative for HUD-driven changes; the equality
        // guards prevent onChange ping-pong between the two sources.
        .onChange(of: keyboardActive) { _, active in
            if keyboardCapture.softwareKeyboardRequested != active {
                keyboardCapture.softwareKeyboardRequested = active
            }
        }
        .onChange(of: keyboardCapture.softwareKeyboardRequested) { _, requested in
            if keyboardActive != requested {
                keyboardActive = requested
            }
        }
        #if canImport(UIKit)
        .background {
            DockedKeyboardInsetReader(metrics: $keyboardViewportMetrics)
        }
        // UIKit's layout guide distinguishes a bottom-docked keyboard from
        // floating and split keyboards; SwiftUI's safe area does not.
        .ignoresSafeArea(.keyboard)
        .onChange(of: keyboardViewportMetrics) { _, _ in
            updateRemoteDisplaySizeFromMeasuredContainer()
        }
        #endif
    }

    @ViewBuilder
    private func desktopContent(in viewSize: CGSize) -> some View {
        if session.isHighPerformanceMode {
            #if canImport(UIKit)
            AdaptiveDisplayView(
                primaryRenderer: session.videoBandRenderer,
                secondaryRenderer: session.secondaryVideoBandRenderer,
                displayRegions: session.presentedVideoDisplayRegions)
                .frame(width: viewSize.width, height: viewSize.height)
            #else
            placeholderView
                .frame(width: viewSize.width, height: viewSize.height)
            #endif
        } else {
            StandardFramebufferContent(session: session)
                .frame(width: viewSize.width, height: viewSize.height)
        }
    }

    @ViewBuilder
    private func interactionLayer(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some View {
        #if canImport(UIKit)
        RemoteInteractionView(
            viewport: $viewport,
            keyboardActive: $keyboardActive,
            hardwareKeyboardAttached: $hardwareKeyboardAttached,
            framebufferSize: framebufferSize,
            touchHandler: touchHandler,
            keyboardHandler: keyboardHandler,
            keyboardCapture: keyboardCapture,
            framebufferOrigin: framebufferOrigin,
            requestPasswordSend: requestPasswordSend,
            requestDictation: requestDictation,
            toggleFullScreen: toggleFullScreen,
            disconnect: { session.disconnect() },
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
                framebufferSize: framebufferSize,
                framebufferOrigin: framebufferOrigin))
            .simultaneousGesture(fallbackDragGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize,
                framebufferOrigin: framebufferOrigin))
            .simultaneousGesture(fallbackMagnificationGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize))
        #endif
    }

    @ViewBuilder
    private var viewportControls: some View {
        #if canImport(UIKit)
        DraggableHUDOverlay {
            hudMenu
                .padding(12)
        }
        #else
        VStack {
            Spacer()
            HStack {
                Spacer()
                hudMenu
            }
            .padding(12)
        }
        .allowsHitTesting(true)
        #endif
    }

    @ViewBuilder
    private var hudMenu: some View {
        Menu {
            #if canImport(UIKit)
            if !hardwareKeyboardAttached {
                Button {
                    keyboardCapture.capture()
                    keyboardActive.toggle()
                } label: {
                    Label(
                        keyboardActive ? "Hide Keyboard" : "Show Keyboard",
                        systemImage: keyboardActive
                            ? "keyboard.chevron.compact.down" : "keyboard")
                }
            }

            if keyboardCapture.hasReservedHostShortcuts {
                Toggle(isOn: Binding(
                    get: { keyboardCapture.routesReservedHostShortcutsToVNC },
                    set: { keyboardCapture.routeReservedHostShortcutsToVNC($0) }
                )) {
                    Label("Route Reserved Shortcuts to VNC", systemImage: "keyboard.badge.ellipsis")
                }
            } else {
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
            }

            Menu {
                Section("Mac Specific") {
                    ForEach(RemoteCommand.macSpecific) { command in
                        Button(command.title) {
                            keyboardHandler.handleRemoteCommand(command)
                        }
                    }
                }

                Section("Other Commands") {
                    Button("Dictate") {
                        requestDictation()
                    }

                    ForEach(RemoteCommand.otherCommands) { command in
                        Button(command.title) {
                            keyboardHandler.handleRemoteCommand(command)
                        }
                    }

                    Button("Command-H") {
                        keyboardHandler.handleCommandTap("h")
                    }
                    Button("Command-M") {
                        keyboardHandler.handleCommandTap("m")
                    }
                }
            } label: {
                Label(
                    "Commands",
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

            if let hudMenuExtras {
                hudMenuExtras
            }

            Divider()

            Button {
                requestPasswordSend()
            } label: {
                Label("Type User Password", systemImage: "key.fill")
            }
            .disabled(!session.canSendLoginPassword)

            Divider()

            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Label("Close Connection", systemImage: "xmark.circle")
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

    private func requestPasswordSend() {
        guard session.canSendLoginPassword else { return }
        confirmPasswordSend = true
    }

    private func requestDictation() {
        keyboardCapture.capture()
        keyboardActive = true
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
            case .reconnecting(let attempt, _):
                ProgressView().controlSize(.large)
                Text("Reconnecting (attempt \(attempt))...")
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var recoveryOverlay: some View {
        switch session.connectionState {
        case .reconnecting(let attempt, let delay):
            VStack(spacing: 10) {
                ProgressView()
                Text("Connection interrupted").font(.headline)
                Text(
                    delay > 0
                        ? "Retry \(attempt) starts in about \(Int(ceil(delay))) seconds."
                        : "Reconnecting now…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Stop Reconnecting", role: .destructive) {
                    session.disconnect()
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
            .accessibilityElement(children: .combine)

        case .failed(let reason):
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title)
                Text("Unable to reconnect").font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Try Again") { session.retryConnection() }
                        .buttonStyle(.borderedProminent)
                    Button("Disconnect", role: .destructive) { session.disconnect() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()

        default:
            EmptyView()
        }
    }

    private func updateRemoteDisplaySize(for viewSize: CGSize) {
        session.updateRemoteDisplaySize(
            viewSize: viewSize,
            displayScale: displayScale)
    }

    #if canImport(UIKit)
    private func updateRemoteDisplaySizeFromMeasuredContainer() {
        let size = keyboardAvoidanceMode == .automatic
            ? keyboardViewportMetrics.availableSize
            : keyboardViewportMetrics.containerSize
        guard size.width > 0, size.height > 0 else { return }
        updateRemoteDisplaySize(for: size)
    }
    #endif

    #if !canImport(UIKit)
    private func fallbackTapGesture(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let point = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin) else { return }
                touchHandler.handleTap(x: point.x, y: point.y)
            }
    }

    private func fallbackDragGesture(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let point = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin) else { return }
                fallbackDragRemotePoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                touchHandler.handleDrag(x: point.x, y: point.y)
            }
            .onEnded { value in
                let mapped = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin)
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
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint = .zero
    ) -> (x: UInt16, y: UInt16)? {
        guard let mapped = viewport.framebufferPoint(
            for: point,
            viewSize: viewSize,
            framebufferSize: framebufferSize) else { return nil }
        return (
            UInt16(min(CGFloat(UInt16.max), mapped.x + framebufferOrigin.x)),
            UInt16(min(CGFloat(UInt16.max), mapped.y + framebufferOrigin.y)))
    }
    #endif
}

#if canImport(UIKit)
/// Reports only the space occupied by a keyboard docked to the bottom edge.
/// UIKit collapses this guide for floating, split, and detached keyboards.
private struct DockedKeyboardInsetReader: UIViewRepresentable {
    @Binding var metrics: DockedKeyboardViewportMetrics

    func makeUIView(context: Context) -> DockedKeyboardInsetView {
        let view = DockedKeyboardInsetView()
        view.onMetricsChange = { newMetrics in
            context.coordinator.setMetrics(newMetrics)
        }
        return view
    }

    func updateUIView(
        _ uiView: DockedKeyboardInsetView,
        context: Context
    ) {
        context.coordinator.parent = self
        uiView.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator {
        var parent: DockedKeyboardInsetReader

        init(parent: DockedKeyboardInsetReader) {
            self.parent = parent
        }

        func setMetrics(_ metrics: DockedKeyboardViewportMetrics) {
            guard !parent.metrics.isApproximatelyEqual(to: metrics) else { return }
            parent.metrics = metrics
        }
    }
}

@MainActor
private final class DockedKeyboardInsetView: UIView {
    var onMetricsChange: ((DockedKeyboardViewportMetrics) -> Void)?
    private var lastReportedMetrics: DockedKeyboardViewportMetrics?
    private let keyboardTopProbe = UIView(frame: .zero)
    private var keyboardTransitionInProgress = false
    private var metricsPublishGeneration: UInt = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // The default is already false, but make the intended floating and
        // split-keyboard behavior explicit.
        keyboardLayoutGuide.followsUndockedKeyboard = false
        if #available(iOS 17.0, *) {
            // An absent or detached keyboard should report zero rather than
            // the device's bottom safe-area inset.
            keyboardLayoutGuide.usesBottomSafeArea = false
        }

        keyboardTopProbe.isHidden = true
        keyboardTopProbe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardTopProbe)
        NSLayoutConstraint.activate([
            keyboardTopProbe.topAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor),
            keyboardTopProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardTopProbe.widthAnchor.constraint(equalToConstant: 0),
            keyboardTopProbe.heightAnchor.constraint(equalToConstant: 0),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if !keyboardTransitionInProgress {
            publishCurrentMetrics()
        }
    }

    @objc private func keyboardFrameWillChange() {
        keyboardTransitionInProgress = true
    }

    @objc private func keyboardFrameDidChange() {
        keyboardTransitionInProgress = false
        setNeedsLayout()
        layoutIfNeeded()
        publishCurrentMetrics()
    }

    @objc private func keyboardDidHide() {
        keyboardTransitionInProgress = false
        publishMetrics(keyboardInset: 0)
    }

    private func publishCurrentMetrics() {
        let inset = max(0, bounds.maxY - keyboardTopProbe.frame.minY)
        publishMetrics(keyboardInset: inset)
    }

    private func publishMetrics(keyboardInset: CGFloat) {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: bounds.size,
            keyboardInset: keyboardInset)
        guard lastReportedMetrics?.isApproximatelyEqual(to: metrics) != true else {
            return
        }
        lastReportedMetrics = metrics
        metricsPublishGeneration &+= 1
        let generation = metricsPublishGeneration

        // Avoid publishing SwiftUI state during a UIKit layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.metricsPublishGeneration == generation else { return }
            self.onMetricsChange?(metrics)
        }
    }
}
#endif

/// Owns the hot standard-framebuffer observation so publishing a new image
/// does not invalidate the parent view that owns the HUD Menu.
private struct StandardFramebufferContent: View {
    @Bindable var session: VNCSession

    var body: some View {
        if let image = session.currentImage {
            let displayedImage = cropped(image) ?? image
            Image(decorative: displayedImage, scale: 1)
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Waiting for framebuffer...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cropped(_ image: CGImage) -> CGImage? {
        guard let region = session.presentedFramebufferRegion else { return nil }
        let imageBounds = CGRect(
            x: 0, y: 0,
            width: image.width, height: image.height)
        let crop = region.integral.intersection(imageBounds)
        guard !crop.isEmpty, crop != imageBounds else { return nil }
        return image.cropping(to: crop)
    }
}

#if canImport(UIKit)
/// Keeps each display in its own decoder-backed renderer and positions it in
/// the server's normalized desktop coordinate space.
private struct AdaptiveDisplayView: View {
    let primaryRenderer: VideoBandLayerRenderer
    let secondaryRenderer: VideoBandLayerRenderer
    let displayRegions: [CGRect]

    var body: some View {
        GeometryReader { geometry in
            let regions = displayRegions.isEmpty
                ? [CGRect(origin: .zero, size: geometry.size)]
                : displayRegions
            let union = regions.dropFirst().reduce(regions[0]) { $0.union($1) }
            let scale = min(
                geometry.size.width / max(1, union.width),
                geometry.size.height / max(1, union.height))
            let origin = CGPoint(
                x: (geometry.size.width - union.width * scale) / 2,
                y: (geometry.size.height - union.height * scale) / 2)

            ZStack(alignment: .topLeading) {
                videoDisplay(
                    renderer: primaryRenderer,
                    region: regions[0],
                    scale: scale,
                    origin: origin)
                if regions.count > 1 {
                    videoDisplay(
                        renderer: secondaryRenderer,
                        region: regions[1],
                        scale: scale,
                        origin: origin)
                }
            }
        }
        .background(Color.black)
    }

    private func videoDisplay(
        renderer: VideoBandLayerRenderer,
        region: CGRect,
        scale: CGFloat,
        origin: CGPoint
    ) -> some View {
        VideoBandView(renderer: renderer)
            .frame(
                width: region.width * scale,
                height: region.height * scale)
            .offset(
                x: origin.x + region.minX * scale,
                y: origin.y + region.minY * scale)
    }
}
#endif

#if !canImport(UIKit)
private extension UnitPoint {
    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}
#endif
