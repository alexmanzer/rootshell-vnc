import SwiftUI
import CoreImage
import CoreVideo
import RFBProtocol
import RFBTransport
import RFBRendering
#if canImport(UIKit)
import UIKit
#endif

private actor MediaRecoveryCoordinator {
    private var active = false

    func begin() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }

    func finish() {
        active = false
    }
}

/// Coalesces the transport's per-packet callback into ordered media-queue
/// batches. A fullscreen reference picture can contain thousands of RTP
/// packets; scheduling one Dispatch block for each packet creates avoidable
/// allocator and queue pressure before the demuxer does any useful work.
final class OrderedMediaPacketCoalescer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let consume: @Sendable ([Data]) -> Void
    private let lock = NSLock()
    private var pending: [Data] = []
    private var drainScheduled = false

    init(queue: DispatchQueue, consume: @escaping @Sendable ([Data]) -> Void) {
        self.queue = queue
        self.consume = consume
    }

    func enqueue(_ packet: Data) {
        lock.lock()
        pending.append(packet)
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        lock.unlock()

        if shouldSchedule {
            queue.async { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                drainScheduled = false
                lock.unlock()
                return
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()
            consume(batch)
        }
    }
}

/// Main VNC session observable object for SwiftUI integration.
///
/// `VNCSession` is the primary entry point for consumers of the rootshellVNC
/// framework. It manages the connection lifecycle, framebuffer rendering,
/// and exposes observable state for SwiftUI views.
///
/// Usage:
/// ```swift
/// let session = VNCSession()
/// try await session.connect(credentials: VNCCredentials(
///     host: "192.168.1.100",
///     password: "secret"
/// ))
///
/// // In SwiftUI:
/// RemoteDesktopView(session: session)
/// ```
@MainActor
@Observable
public final class VNCSession {

    // MARK: - Observable State

    /// The current state of the VNC connection.
    public var connectionState: VNCConnectionState = .idle

    /// The name of the remote desktop as reported by the server.
    public var serverName: String = ""

    /// The width of the remote framebuffer in pixels.
    public var framebufferWidth: Int = 0

    /// The height of the remote framebuffer in pixels.
    public var framebufferHeight: Int = 0

    /// The latest rendered framebuffer image, suitable for display.
    public var currentImage: CGImage?

    /// The last protocol error that occurred, if any.
    public var lastError: VNCProtocolError?

    /// Whether the server is using high-performance (HEVC/H.264) mode.
    public var isHighPerformanceMode: Bool = false

    /// The remote cursor shape from the Cursor pseudo-encoding, adopted by
    /// the local system pointer. Nil when the server has not sent a shape
    /// (or sent an explicit empty one) — callers fall back to the default.
    public private(set) var remoteCursor: RemoteCursor?

    // MARK: - Configuration

    /// The configuration for this session.
    public var configuration: VNCConfiguration

    // MARK: - Internal

    private var transportSession: TransportSession?
    /// Credentials for the active connection. Kept private so UI code can
    /// offer credential actions without ever reading or displaying the secret.
    @ObservationIgnored
    private var activeCredentials: VNCCredentials?
    private var framebuffer: Framebuffer?
    private var renderer: FramebufferRenderer?
    private var videoStreamManager: VideoStreamManager?
    @ObservationIgnored
    private var remoteAudioPlayer: AppleRemoteAudioPlayer?
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private var remoteDisplayResizeTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastRequestedClientDisplaySize: RemoteDisplaySize?
    /// Most recent client viewport, retained across connections so Match Client
    /// can be staged before Apple media setup starts. Without this, the server
    /// begins by encoding the physical display and a remote phone must receive
    /// a multi-megabyte reference picture before it can request its virtual
    /// display.
    @ObservationIgnored
    private var preparedClientDisplaySize: RemoteDisplaySize?
    /// Single drain task for the ordered input queue. Gesture callbacks are
    /// synchronous, but transport writes are async; one pump prevents a release
    /// from overtaking its press while coalescing stale movement samples.
    @ObservationIgnored
    private var inputTask: Task<Void, Never>?
    @ObservationIgnored
    private var inputGeneration: UInt64 = 0
    @ObservationIgnored
    private var inputQueue = SessionInputQueue()
    private let diagnostics = ConnectionDiagnostics()
    private let logger = VNCLogger(category: "Session")
    /// GPU renderer for the high-performance HEVC screen bands. The
    /// ``RemoteDesktopView`` displays this directly (zero-copy) instead of
    /// pushing a full-screen CGImage through SwiftUI every frame.
    @ObservationIgnored
    public let videoBandRenderer = VideoBandLayerRenderer()
    /// Serial queue for feeding media packets to the decoder off the main
    /// thread. At ~3000 packets/s, demux + decode submission on the main actor
    /// backed up the whole pipeline; VideoStreamManager is thread-safe and a
    /// serial queue preserves packet order.
    @ObservationIgnored
    private let mediaQueue = DispatchQueue(label: "com.rootshell.vnc.media", qos: .userInitiated)
    /// Serial queue for persistent Zlib/ZRLE decode and framebuffer snapshots.
    /// Keeping it separate from HEVC and the main actor preserves codec order
    /// while input remains responsive during large standard-mode updates.
    @ObservationIgnored
    private let framebufferRenderQueue = DispatchQueue(
        label: "com.rootshell.vnc.framebuffer",
        qos: .userInitiated)
    @ObservationIgnored
    private var lastFramebufferRenderDiagnosticNanos: UInt64 = 0
    /// When the last framebuffer image was published to `currentImage`;
    /// drives the publish-only targetFrameRate throttle.
    @ObservationIgnored
    private var lastImagePublishNanos: UInt64 = 0
    @ObservationIgnored
    private var trailingSnapshotTask: Task<Void, Never>?
    /// Rejects late geometry callbacks from a decoder retired by a newer AVC
    /// negotiation generation.
    @ObservationIgnored
    private var appliedMediaGeometryGeneration: UInt64 = 0
    @ObservationIgnored
    private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored
    private var intentionallyDisconnected = false
    @ObservationIgnored
    private var hasEstablishedConnection = false
    #if canImport(UIKit)
    @ObservationIgnored
    private var backgroundLifecycleTask: Task<Void, Never>?
    @ObservationIgnored
    private var foregroundLifecycleTask: Task<Void, Never>?
    @ObservationIgnored
    private var mediaWasBackgrounded = false
    #endif

    // MARK: - Init

    /// Create a new VNC session with the given configuration.
    ///
    /// - Parameter configuration: Session configuration. Defaults to sensible values.
    public init(configuration: VNCConfiguration = VNCConfiguration()) {
        self.configuration = configuration
        #if canImport(UIKit)
        observeApplicationLifecycle()
        #endif
    }

    deinit {
        reconnectTask?.cancel()
        remoteAudioPlayer?.stop()
        #if canImport(UIKit)
        backgroundLifecycleTask?.cancel()
        foregroundLifecycleTask?.cancel()
        #endif
    }

    // MARK: - Connection

    /// Connect to a VNC server using the provided credentials.
    ///
    /// This method performs the full RFB handshake, including protocol version
    /// negotiation, security type selection, authentication, and ServerInit.
    /// On success, the session begins receiving framebuffer updates.
    ///
    /// - Parameter credentials: The server address, port, and authentication credentials.
    /// - Throws: ``VNCError`` if the connection or handshake fails.
    public func connect(credentials: VNCCredentials) async throws {
        guard connectionState.canConnect else {
            throw VNCError.alreadyConnected
        }

        invalidateInputQueue()
        reconnectTask?.cancel()
        reconnectTask = nil
        intentionallyDisconnected = false
        hasEstablishedConnection = false
        connectionState = .connecting
        activeCredentials = credentials
        lastError = nil
        currentImage = nil
        remoteCursor = nil
        isHighPerformanceMode = false
        trailingSnapshotTask?.cancel()
        trailingSnapshotTask = nil
        lastImagePublishNanos = 0
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = nil
        lastRequestedClientDisplaySize = nil
        diagnostics.isHighPerformanceMode = false
        videoBandRenderer.reset()
        diagnostics.reset()
        diagnostics.connectionStartTime = Date()
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil

        let traceEnabled: Bool
        #if DEBUG
        traceEnabled = true
        #else
        traceEnabled = configuration.enableProtocolTrace
        #endif
        if traceEnabled {
            diagnostics.protocolTrace = ProtocolTrace()
        }

        do {
            try await establishTransport(credentials: credentials)
            logger.info("Connection initiated to \(credentials.host):\(credentials.port)")
        } catch let error as VNCProtocolError {
            if intentionallyDisconnected {
                cleanupTransport(clearCredentials: true)
                connectionState = .disconnected
                throw CancellationError()
            }
            connectionState = .failed(error.localizedDescription)
            lastError = error
            diagnostics.lastError = error
            cleanupTransport(clearCredentials: true)
            throw mapProtocolError(error)
        } catch {
            if intentionallyDisconnected {
                cleanupTransport(clearCredentials: true)
                connectionState = .disconnected
                throw CancellationError()
            }
            let message = error.localizedDescription
            connectionState = .failed(message)
            cleanupTransport(clearCredentials: true)
            throw VNCError.connectionFailed(message)
        }
    }

    /// Disconnect from the current VNC server.
    ///
    /// Cancels all active tasks, closes the transport, and resets the session
    /// state. Safe to call even when not connected.
    public func disconnect() {
        guard connectionState != .idle && connectionState != .disconnected else { return }

        intentionallyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionState = .disconnecting
        logger.info("Disconnecting")

        // Cancel background tasks
        eventTask?.cancel()
        eventTask = nil
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = nil
        lastRequestedClientDisplaySize = nil
        invalidateInputQueue()

        // Close the transport
        if let transport = transportSession {
            Task {
                await transport.disconnect()
            }
        }
        transportSession = nil
        activeCredentials = nil

        // Clear rendering state
        framebuffer = nil
        renderer = nil
        currentImage = nil
        remoteCursor = nil
        isHighPerformanceMode = false
        trailingSnapshotTask?.cancel()
        trailingSnapshotTask = nil
        lastImagePublishNanos = 0
        videoBandRenderer.reset()
        videoStreamManager?.stopStream()
        videoStreamManager = nil
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil

        connectionState = .disconnected
    }

    /// Immediately retry after automatic recovery has exhausted its attempts.
    public func retryConnection() {
        guard reconnectTask == nil,
              activeCredentials != nil,
              connectionState.canConnect else { return }
        intentionallyDisconnected = false
        scheduleReconnect(immediate: true)
    }

    // MARK: - Input Events

    /// Whether the active connection has a password available for the remote
    /// login window. The password itself is intentionally never exposed.
    public var canSendLoginPassword: Bool {
        connectionState.isConnected && !(activeCredentials?.password.isEmpty ?? true)
    }

    /// Type the active connection's password and press Return. This mirrors
    /// the behavior of remote-desktop clients' “Type User Password” action.
    /// Callers should obtain confirmation before invoking this method.
    public func sendLoginPassword() {
        guard canSendLoginPassword, let password = activeCredentials?.password else { return }

        for character in password {
            let keysym = KeyboardInputHandler.keysymForCharacter(character)
            guard keysym != 0 else { continue }
            sendKeyEvent(downFlag: true, key: keysym)
            sendKeyEvent(downFlag: false, key: keysym)
        }
        sendKeyEvent(downFlag: true, key: KeyboardInputHandler.keysymReturn)
        sendKeyEvent(downFlag: false, key: KeyboardInputHandler.keysymReturn)
    }

    /// Send a key press or release event to the VNC server.
    ///
    /// - Parameters:
    ///   - downFlag: `true` for key press, `false` for key release.
    ///   - key: The X11 keysym value for the key.
    public func sendKeyEvent(downFlag: Bool, key: UInt32) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "KeyEvent",
                data: ClientMessage.keyEvent(downFlag: downFlag, key: key).serialize(),
                details: "key=0x\(String(key, radix: 16)) down=\(downFlag)"
            )
        }

        enqueueInput(.key(downFlag: downFlag, keysym: key))
    }

    /// Send a pointer (mouse/touch) event to the VNC server.
    ///
    /// - Parameters:
    ///   - buttonMask: Bitmask of pressed buttons (bit 0 = left, 1 = middle, 2 = right,
    ///     3 = scroll up, 4 = scroll down).
    ///   - x: The X coordinate in framebuffer pixels.
    ///   - y: The Y coordinate in framebuffer pixels.
    public func sendPointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "PointerEvent",
                data: ClientMessage.pointerEvent(buttonMask: buttonMask, x: x, y: y).serialize(),
                details: "buttons=0x\(String(buttonMask, radix: 16)) pos=(\(x),\(y))"
            )
        }

        enqueueInput(.pointer(buttonMask: buttonMask, x: x, y: y))
    }

    /// Send one continuous scroll sample. Apple servers that advertise precise
    /// scrolling receive the full event; all other servers receive ordinary
    /// RFB wheel-button press/release events from the transport fallback.
    public func sendScrollEvent(_ event: AppleScrollEvent) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "ScrollEvent",
                data: ClientMessage.appleScrollEvent(event).serialize(),
                details: "delta=(\(event.pointDeltaX),\(event.pointDeltaY)) phase=\(event.scrollPhase.rawValue) pos=(\(event.x),\(event.y))"
            )
        }

        enqueueInput(.scroll(event))
    }

    /// Send the begin/end envelope around a precise Apple scroll gesture.
    /// The transport ignores it for conventional RFB servers.
    public func sendGestureEvent(_ event: AppleGestureEvent) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "GestureEvent",
                data: ClientMessage.appleGestureEvent(event).serialize(),
                details: "kind=\(event.kind.rawValue) source=\(event.sourceSubtype.rawValue) pos=(\(event.x),\(event.y))"
            )
        }

        enqueueInput(.gesture(event))
    }

    /// Send clipboard text to the VNC server.
    ///
    /// - Parameter text: The text to place on the server's clipboard.
    public func sendClipboardText(_ text: String) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "ClientCutText",
                data: ClientMessage.clientCutText(text).serialize(),
                details: "length=\(text.utf8.count)"
            )
        }

        enqueueInput(.clipboard(text))
    }

    /// Debounce viewport/rotation changes and request a matching remote display
    /// when the user selected Match Client. The transport capability-gates both
    /// Apple's virtual-display command and standard RFB SetDesktopSize.
    func matchingClientDisplaySize(
        viewSize: CGSize,
        displayScale _: CGFloat
    ) -> RemoteDisplaySize? {
        guard configuration.displaySizingMode == .matchClient else { return nil }
        return RemoteDisplaySize.matching(viewSize: viewSize)
    }

    public func updateRemoteDisplaySize(
        viewSize: CGSize,
        displayScale: CGFloat
    ) {
        guard let requested = matchingClientDisplaySize(
            viewSize: viewSize,
            displayScale: displayScale) else { return }

        // ConnectionView supplies the viewport before connecting; the remote
        // desktop view keeps it current for window changes and device rotation.
        preparedClientDisplaySize = requested

        guard connectionState.isConnected,
              let transport = transportSession,
              requested != lastRequestedClientDisplaySize else { return }

        lastRequestedClientDisplaySize = requested
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = Task { [weak self, weak transport] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard let self,
                      let transport,
                      self.transportSession === transport,
                      self.connectionState.isConnected,
                      self.configuration.displaySizingMode == .matchClient else { return }
                let disposition = try await transport.requestRemoteDisplaySize(
                    pixelWidth: requested.pixelWidth,
                    pixelHeight: requested.pixelHeight,
                    pointWidth: requested.pointWidth,
                    pointHeight: requested.pointHeight)
                self.logger.info(
                    "Client-sized display \(requested.pixelWidth)x"
                        + "\(requested.pixelHeight): \(String(describing: disposition))")
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if self.lastRequestedClientDisplaySize == requested {
                    self.lastRequestedClientDisplaySize = nil
                }
                self.logger.warning(
                    "Failed to request client-sized display: "
                        + error.localizedDescription)
            }
        }
    }

    // MARK: - Diagnostics

    /// Get diagnostic information for the current or most recent connection.
    ///
    /// - Returns: A snapshot of connection diagnostics including handshake details,
    ///   timing information, and protocol trace data.
    public func getDiagnostics() -> ConnectionDiagnostics {
        diagnostics
    }

    var liveMediaDebugSnapshot: (submitted: UInt64, outputs: UInt64) {
        let progress = videoStreamManager?.decodeProgress
        return (
            progress?.submittedFrameCount ?? 0,
            progress?.decoderOutputCount ?? 0)
    }

    // MARK: - Private: Event Processing

    private func startEventProcessing(transport: TransportSession) {
        eventTask = Task { [weak self] in
            for await event in transport.events {
                guard let self, !Task.isCancelled,
                      self.transportSession === transport else { break }
                await self.handleSessionEvent(event)
            }
        }
    }

    private func handleSessionEvent(_ event: SessionEvent) async {
        switch event {
        case .stateChanged(let protocolState):
            handleStateChanged(protocolState)

        case .serverInit(let serverInit):
            handleServerInit(serverInit)

        case .framebufferUpdate(let rects):
            // Returning the credit below requests the next incremental frame.
            // Keeping one update in flight prevents stale reference frames
            // from queueing while decode/presentation is busy.
            await handleFramebufferUpdate(rects)

            do {
                guard let updateTransport = transportSession else { break }
                try await updateTransport.finishFramebufferUpdate()
            } catch is CancellationError {
                break
            } catch {
                logger.warning(
                    "Failed to acknowledge framebuffer update: "
                        + error.localizedDescription)
            }

        case .clipboardText(let text):
            logger.debug("Server clipboard: \(text.prefix(100))")
            if isTraceEnabled {
                diagnostics.protocolTrace.recordReceived(
                    type: "ServerCutText",
                    data: Data(text.utf8),
                    details: "length=\(text.utf8.count)"
                )
            }

        case .bell:
            logger.debug("Server bell")

        case .error(let error):
            handleError(error)

        case .encryptionInfo(let info):
            logger.info("Encryption info: cipher=\(info.cipherMode) keyLen=\(info.keyLength)")
            diagnostics.encryptionMode = "Cipher mode \(info.cipherMode), key length \(info.keyLength)"

        case .displayInfo(let info):
            logger.info("Display info: \(info.width)x\(info.height) at (\(info.originX),\(info.originY))")

        case .mediaStreamOffer(let offer):
            logger.info(
                "Media stream offer: stream=\(offer.streamID) type=\(offer.messageType ?? 0) "
                    + "audioPort=\(offer.audioStreamUDPPort ?? 0) "
                    + "videoPort=\(offer.videoStream1UDPPort ?? 0) "
                    + "displays=\(offer.videoStreamDisplayCount ?? 0) "
                    + "payloadBytes=\(offer.rawPayload.count)"
            )
            isHighPerformanceMode = true
            diagnostics.isHighPerformanceMode = true
            await startVideoStream(offer: offer)

        case .udpDatagram(let datagram):
            routeAppleMediaRTPPacket(datagram)

        case .appleMediaRTPPacket(let packet):
            routeAppleMediaRTPPacket(packet)

        case .appleMediaUDPStarted(let localPort):
            logger.info("Apple media UDP started on local port \(localPort)")

        case .appleMediaControlRecord:
            break

        case .disconnected:
            handleDisconnected()
        }
    }

    private func handleStateChanged(_ protocolState: RFBProtocol.ConnectionState) {
        let newState = VNCConnectionState(from: protocolState)
        // Keep the richer retry state visible while a replacement transport
        // progresses through its internal handshake states.
        if reconnectTask != nil {
            guard newState == .connected else { return }
        }
        if hasEstablishedConnection, !intentionallyDisconnected,
           case .failed = newState {
            return
        }
        // Only update if it represents a meaningful change
        // (internal handshake states all map to .connecting)
        if newState != connectionState {
            connectionState = newState
        }
    }

    private func handleServerInit(_ serverInit: ServerInit) {
        logger.info("Connected: \(serverInit.name) (\(serverInit.framebufferWidth)x\(serverInit.framebufferHeight))")

        serverName = serverInit.name
        framebufferWidth = Int(serverInit.framebufferWidth)
        framebufferHeight = Int(serverInit.framebufferHeight)

        // Update diagnostics
        diagnostics.serverInit = serverInit
        diagnostics.handshakeCompleteTime = Date()

        // Must match what the transport sent in SetPixelFormat — decoding
        // with the server's pre-negotiation format would corrupt every rect.
        let pixelFormat = configuration.effectivePixelFormat

        // Create framebuffer and renderer
        let fb = Framebuffer(
            width: Int(serverInit.framebufferWidth),
            height: Int(serverInit.framebufferHeight),
            pixelFormat: pixelFormat
        )
        self.framebuffer = fb
        self.renderer = FramebufferRenderer(framebuffer: fb, pixelFormat: pixelFormat)

        hasEstablishedConnection = true
        lastError = nil
        connectionState = .connected
    }

    private func handleFramebufferUpdate(
        _ rects: [(FramebufferRect, Data)]
    ) async {
        guard let renderer else { return }

        for (rect, data) in rects {
            if isTraceEnabled {
                diagnostics.protocolTrace.recordReceived(
                    type: "FramebufferUpdate",
                    data: data,
                    details: "encoding=\(rect.encoding) rect=(\(rect.x),\(rect.y) \(rect.width)x\(rect.height))"
                )
            }

            if (rect.encoding == .desktopSize
                    || rect.encoding == .extendedDesktopSize),
               !rect.isSuccessfulDesktopResize {
                logger.warning(
                    "Ignoring rejected/invalid desktop resize status=\(rect.y) "
                        + "size=\(rect.width)x\(rect.height)")
            }
        }

        // Publish-only throttle: rects are always applied (persistent codec
        // state) and the transport credit is always returned, but the
        // full-framebuffer snapshot + image publish is capped at
        // targetFrameRate. A trailing snapshot guarantees the final state
        // always renders after a burst.
        let publishInterval = UInt64(
            1_000_000_000 / max(1, configuration.targetFrameRate))
        let renderStarted = DispatchTime.now().uptimeNanoseconds
        let takeSnapshot = renderStarted &- lastImagePublishNanos >= publishInterval
        let result = await withCheckedContinuation { continuation in
            framebufferRenderQueue.async {
                continuation.resume(
                    returning: renderer.applyBatch(rects, snapshot: takeSnapshot))
            }
        }
        let renderFinished = DispatchTime.now().uptimeNanoseconds
        let renderMilliseconds = (renderFinished &- renderStarted) / 1_000_000
        if renderMilliseconds >= 100,
           (lastFramebufferRenderDiagnosticNanos == 0
                || renderFinished &- lastFramebufferRenderDiagnosticNanos
                    >= 1_000_000_000) {
            lastFramebufferRenderDiagnosticNanos = renderFinished
            let payloadBytes = rects.reduce(0) { $0 + $1.1.count }
            let encodings = rects.map { String(describing: $0.0.encoding) }
                .joined(separator: ",")
            logger.info(
                "Framebuffer decode/snapshot=\(renderMilliseconds)ms "
                    + "rects=\(rects.count) payload=\(payloadBytes)B "
                    + "encodings=\(encodings)")
        }

        for issue in result.issues {
            logger.warning("\(issue)")
        }
        if let width = result.resizedWidth,
           let height = result.resizedHeight {
            applyDesktopResizeMetadata(width: width, height: height)
        }
        if let image = result.image {
            trailingSnapshotTask?.cancel()
            trailingSnapshotTask = nil
            currentImage = image
            lastImagePublishNanos = DispatchTime.now().uptimeNanoseconds
        } else {
            scheduleTrailingSnapshot(interval: publishInterval)
        }
        switch result.cursorUpdate {
        case .shape(let cursor):
            remoteCursor = cursor
        case .hidden:
            remoteCursor = nil
        case nil:
            break
        }
    }

    /// Apply one live geometry transition to every consumer of framebuffer
    /// dimensions. The media stream remains connected; new SPS/PPS parameter
    /// sets reconfigure the public VideoToolbox session when they arrive.
    private func applyDesktopResizeMetadata(
        width: UInt16,
        height: UInt16
    ) {
        let newWidth = Int(width)
        let newHeight = Int(height)
        guard newWidth > 0, newHeight > 0 else { return }
        guard newWidth != framebufferWidth || newHeight != framebufferHeight else { return }

        logger.info(
            "Applying desktop resize \(framebufferWidth)x\(framebufferHeight) "
                + "-> \(newWidth)x\(newHeight)")
        framebufferWidth = newWidth
        framebufferHeight = newHeight
        videoBandRenderer.setScreenSize(width: newWidth, height: newHeight)

        if let manager = videoStreamManager {
            mediaQueue.async {
                manager.updateFrameGeometry(width: newWidth, height: newHeight)
            }
        }
    }

    func applyRequestedRemoteDisplayGeometry(_ requested: RemoteDisplaySize) {
        applyDesktopResizeMetadata(
            width: requested.pixelWidth,
            height: requested.pixelHeight)
    }

    /// Apply the full-frame dimensions carried by the one-tile HEVC format.
    /// Apple's resize path can renegotiate AVC without emitting DesktopSize,
    /// so the public codec format is authoritative for both display layout and
    /// input-coordinate bounds in high-performance mode.
    private func applyMediaStreamGeometry(
        _ geometry: VideoFrameGeometry,
        from manager: VideoStreamManager
    ) {
        guard videoStreamManager === manager else { return }
        guard manager.currentMediaGeneration == geometry.mediaGeneration else { return }
        guard geometry.mediaGeneration >= appliedMediaGeometryGeneration else { return }
        guard geometry.width > 0, geometry.height > 0,
              geometry.width <= Int(UInt16.max),
              geometry.height <= Int(UInt16.max) else { return }

        appliedMediaGeometryGeneration = geometry.mediaGeneration
        guard geometry.width != framebufferWidth
                || geometry.height != framebufferHeight else { return }

        logger.info(
            "Applying HEVC media resize \(framebufferWidth)x\(framebufferHeight) "
                + "-> \(geometry.width)x\(geometry.height) "
                + "generation=\(geometry.mediaGeneration)")
        renderer?.handleDesktopResize(
            width: UInt16(geometry.width),
            height: UInt16(geometry.height))
        framebufferWidth = geometry.width
        framebufferHeight = geometry.height
        videoBandRenderer.setScreenSize(
            width: geometry.width,
            height: geometry.height)
    }

    private func handleError(_ error: VNCProtocolError) {
        logger.error("Protocol error: \(error.localizedDescription)")
        lastError = error
        diagnostics.lastError = error
    }

    private func handleDisconnected() {
        logger.info("Disconnected")
        cleanupTransport(clearCredentials: intentionallyDisconnected)

        guard !intentionallyDisconnected,
              hasEstablishedConnection,
              activeCredentials != nil,
              configuration.reconnectionPolicy.isEnabled,
              configuration.reconnectionPolicy.maximumAttempts > 0 else {
            connectionState = .disconnected
            return
        }
        scheduleReconnect()
    }

    // MARK: - Private: Helpers

    private func cleanupTransport(clearCredentials: Bool) {
        eventTask?.cancel()
        eventTask = nil
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = nil
        lastRequestedClientDisplaySize = nil
        invalidateInputQueue()
        transportSession = nil
        if clearCredentials {
            activeCredentials = nil
        }
        videoStreamManager?.stopStream()
        videoStreamManager = nil
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil
    }

    private func establishTransport(credentials: VNCCredentials) async throws {
        let transport = TransportSession(
            host: credentials.host,
            port: credentials.port,
            password: credentials.password,
            username: credentials.username,
            preferredPixelFormat: configuration.effectivePixelFormat,
            preferredEncodings: configuration.effectiveEncodings,
            preferFullQualityVideo: configuration.videoQualityMode == .fullQuality)
        transportSession = transport

        if configuration.displaySizingMode == .matchClient,
           let preparedClientDisplaySize {
            _ = try await transport.requestRemoteDisplaySize(
                pixelWidth: preparedClientDisplaySize.pixelWidth,
                pixelHeight: preparedClientDisplaySize.pixelHeight,
                pointWidth: preparedClientDisplaySize.pointWidth,
                pointHeight: preparedClientDisplaySize.pointHeight)
        }

        startEventProcessing(transport: transport)
        try await transport.connect()
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard reconnectTask == nil, let credentials = activeCredentials else { return }
        let policy = configuration.reconnectionPolicy
        guard policy.maximumAttempts > 0 else {
            connectionState = .failed("Reconnection is disabled for this session.")
            return
        }

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }

            for attempt in 1...policy.maximumAttempts {
                guard !Task.isCancelled, !self.intentionallyDisconnected else { return }
                let delay = immediate && attempt == 1 ? 0 : policy.delay(forAttempt: attempt)
                self.connectionState = .reconnecting(attempt: attempt, delay: delay)
                self.logger.warning(
                    "Connection lost; retry \(attempt)/\(policy.maximumAttempts) in "
                        + String(format: "%.1f", delay) + "s")

                do {
                    if delay > 0 {
                        let nanoseconds = min(
                            delay * 1_000_000_000,
                            Double(Int64.max))
                        try await Task.sleep(
                            for: .nanoseconds(Int64(nanoseconds)))
                    }
                    try Task.checkCancellation()
                    self.cleanupTransport(clearCredentials: false)
                    try await self.establishTransport(credentials: credentials)
                    self.logger.info("Reconnected successfully")
                    return
                } catch is CancellationError {
                    return
                } catch let error as VNCProtocolError {
                    self.lastError = error
                    self.diagnostics.lastError = error
                    self.logger.warning(
                        "Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                    if let transport = self.transportSession {
                        await transport.disconnect()
                    }
                    if !Self.isRetryableConnectionError(error) {
                        self.cleanupTransport(clearCredentials: false)
                        self.connectionState = .failed(error.localizedDescription)
                        return
                    }
                } catch {
                    self.logger.warning(
                        "Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                    if let transport = self.transportSession {
                        await transport.disconnect()
                    }
                }
            }

            self.cleanupTransport(clearCredentials: false)
            self.connectionState = .failed(
                "Couldn’t reconnect after \(policy.maximumAttempts) attempts. Check the network or server, then try again.")
        }
    }

    private static func isRetryableConnectionError(_ error: VNCProtocolError) -> Bool {
        switch error {
        case .connectionClosed, .timeout, .ioError, .protocolViolation,
             .unexpectedMessage:
            return true
        case .authenticationFailed, .unsupportedVersion, .unsupportedEncoding:
            return false
        }
    }

    /// Append input to one ordered, bounded pump. Redundant pointer positions
    /// and queued continuous-scroll samples are coalesced while button/key and
    /// gesture lifecycle transitions remain exact.
    private func enqueueInput(_ event: SessionInputEvent) {
        guard connectionState.isConnected,
              let transport = transportSession else { return }

        inputQueue.enqueue(event)
        guard inputTask == nil else { return }

        let generation = inputGeneration
        inputTask = Task { [weak self, weak transport] in
            guard let self, let transport else { return }
            while !Task.isCancelled,
                  self.inputGeneration == generation,
                  self.transportSession === transport,
                  self.connectionState.isConnected,
                  let event = self.inputQueue.dequeue() {
                switch event {
                case .key, .pointer:
                    // Drain the whole run of basic key/pointer messages that
                    // is already waiting into one socket write; scroll,
                    // gesture, and clipboard boundaries end the run.
                    var batch = [Self.batchableInputEvent(event)!]
                    while batch.count < 64,
                          let next = self.inputQueue.peek(),
                          let batchable = Self.batchableInputEvent(next) {
                        _ = self.inputQueue.dequeue()
                        batch.append(batchable)
                    }
                    try? await transport.sendInputEvents(batch)
                case .scroll(let event):
                    try? await transport.sendScrollEvent(event)
                case .gesture(let event):
                    try? await transport.sendGestureEvent(event)
                case .clipboard(let text):
                    try? await transport.sendClipboardText(text)
                }
            }
            if self.inputGeneration == generation {
                self.inputTask = nil
            }
        }
    }

    private func scheduleTrailingSnapshot(interval: UInt64) {
        guard trailingSnapshotTask == nil else { return }
        let delay = interval &- min(
            interval, DispatchTime.now().uptimeNanoseconds &- lastImagePublishNanos)
        trailingSnapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int64(delay)))
            guard let self, !Task.isCancelled,
                  let renderer = self.renderer else { return }
            let queue = self.framebufferRenderQueue
            let image = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: renderer.snapshot())
                }
            }
            guard !Task.isCancelled else { return }
            if let image {
                self.currentImage = image
                self.lastImagePublishNanos = DispatchTime.now().uptimeNanoseconds
            }
            self.trailingSnapshotTask = nil
        }
    }

    private static func batchableInputEvent(
        _ event: SessionInputEvent
    ) -> ClientInputEvent? {
        switch event {
        case .key(let downFlag, let keysym):
            return .key(downFlag: downFlag, key: keysym)
        case .pointer(let buttonMask, let x, let y):
            return .pointer(buttonMask: buttonMask, x: x, y: y)
        case .scroll, .gesture, .clipboard:
            return nil
        }
    }

    private func invalidateInputQueue() {
        inputGeneration &+= 1
        inputTask?.cancel()
        inputTask = nil
        inputQueue.removeAll()
    }

    #if canImport(UIKit)
    /// UIKit can suspend the process long enough for RTP to advance beyond the
    /// half-range rule normally used to distinguish a late UInt16 sequence.
    /// Preserve the live TCP/media session and mark only receive-side ordering
    /// state at both sides of the suspension boundary.
    private func observeApplicationLifecycle() {
        backgroundLifecycleTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                mediaWasBackgrounded = true
                noteMediaInterruptionBoundary()
            }
        }
        foregroundLifecycleTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.willEnterForegroundNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                guard mediaWasBackgrounded else { continue }
                mediaWasBackgrounded = false
                noteMediaInterruptionBoundary()
            }
        }
    }

    private func noteMediaInterruptionBoundary() {
        guard connectionState.isConnected,
              isHighPerformanceMode,
              let transport = transportSession else { return }
        videoStreamManager?.noteMediaInterruption()
        remoteAudioPlayer?.reset()
        Task { [transport] in
            await transport.noteAppleMediaInterruption()
        }
    }

    #endif

    private var isTraceEnabled: Bool {
        #if DEBUG
        return true
        #else
        return configuration.enableProtocolTrace
        #endif
    }

    private func startVideoStream(offer: AppleMediaStreamOffer) async {
        let manager = videoStreamManager ?? VideoStreamManager()
        videoStreamManager = manager
        videoBandRenderer.reset()

        if configuration.enableRemoteAudio {
            if remoteAudioPlayer == nil {
                do {
                    remoteAudioPlayer = try AppleRemoteAudioPlayer()
                } catch {
                        logger.error("Could not initialize remote audio: \(error.localizedDescription)")
                }
            }
        } else {
            remoteAudioPlayer?.stop()
            remoteAudioPlayer = nil
        }

        let width = framebufferWidth > 0 ? framebufferWidth : Int(offer.width)
        let height = framebufferHeight > 0 ? framebufferHeight : Int(offer.height)
        let initialTileCount = await transportSession?.currentAppleMediaTilesPerFrame
            ?? Int(AppleMediaVideoMode.negotiatedTilesPerFrame)
        videoBandRenderer.setScreenSize(width: width, height: height)
        videoBandRenderer.configureExpectedBandCount(initialTileCount)

        let renderer = videoBandRenderer
        // Coalesced main-thread delivery. A Task per decoded frame has no FIFO
        // guarantee (an older band frame could land after a newer one — visible
        // as flicker/regression) and floods the main thread at 240+ frames/sec
        // across bands. Instead: stage the newest buffer per band under a lock
        // and drain all staged bands in ONE main-queue hop (FIFO by definition);
        // under main-thread load intermediate frames are simply superseded.
        let coalescer = BandFrameCoalescer(
            renderer: renderer,
            expectedSourceCount: initialTileCount)
        // Diagnostic tap: with ROOTSHELL_VNC_FRAME_OUT_DIR set, periodically
        // save the EXACT decoded buffers handed to the renderer, so decode
        // output and on-screen result can be compared for the same session.
        let frameDumper = DiagnosticFrameDumper.fromEnvironment()
        let decodedBands = DecodedBandTracker()
        let callback: VideoStreamManager.FrameCallback = { pixelBuffer, ssrc in
            frameDumper?.maybeDump(pixelBuffer, ssrc: ssrc)
            decodedBands.record(ssrc)
            coalescer.submit(ssrc: ssrc, pixelBuffer: pixelBuffer)
        }

        appliedMediaGeometryGeneration = 1
        manager.onFrameGeometryChange = { [weak self, weak manager] geometry in
            guard let manager else { return }
            Task { @MainActor [weak self, weak manager] in
                guard let self, let manager else { return }
                self.applyMediaStreamGeometry(geometry, from: manager)
            }
        }

        manager.startStream(
            streamID: offer.streamID,
            width: width,
            height: height,
            // Match the initial tiled offer generated by RFBTransport. DON
            // restores the compound frame's global decode order; later media
            // generations can switch between one and multiple tiles.
            usesDecodingOrderNumbers:
                initialTileCount > 1,
            numberOfTiles: initialTileCount,
            frameCallback: callback
        )

        let streamGeneration = manager.decodeProgress.streamGeneration
        let recoveryCoordinator = MediaRecoveryCoordinator()

        // Startup liveness watchdog. Recovery remains in the negotiated media
        // protocol: request a fresh intra picture instead of dirtying the
        // framebuffer or restarting the VNC connection.
        if let transport = transportSession {
            let watchdogManager = manager
            let log = logger
            Task { [weak transport, weak watchdogManager, recoveryCoordinator] in
                var firAttempts = 0
                for _ in 1...20 where firAttempts < 3 {
                    try? await Task.sleep(for: .seconds(1))
                    guard let transport, let m = watchdogManager, m.isStreamActive else { return }
                    let sources = await transport.videoSourceCount
                    let decoded = decodedBands.count
                    if sources > 0 && decoded >= sources {
                        if firAttempts > 0 {
                            log.info("Dead-band watchdog: recovered, \(decoded)/\(sources) bands decoding")
                        }
                        return
                    }
                    guard await transport.isReadyForVideoKeyframeRecovery(),
                          await recoveryCoordinator.begin() else {
                        continue
                    }
                    firAttempts += 1
                    log.warning("Startup media watchdog: \(decoded)/\(sources) sources decoding "
                        + "(attempt \(firAttempts)); requesting native FIR after rate settled")
                    await transport.requestVideoKeyframe()
                    await recoveryCoordinator.finish()
                }
            }
        }

        // Long-running decode-output watchdog. A static desktop naturally
        // produces no decode submissions, so silence by itself is not a fault.
        // If submitted pictures stop producing output, rebuild only the public
        // decoder and request a fresh intra picture on the existing session.
        if let transport = transportSession {
            let watchdogManager = manager
            let log = logger
            let recoveryQueue = mediaQueue
            Task { [weak transport, weak watchdogManager] in
                var detector = DecodeOutputStallDetector()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let transport,
                          let m = watchdogManager,
                          m.isStreamActive else { return }
                    let progress = m.decodeProgress
                    guard progress.streamGeneration == streamGeneration else { return }
                    // Loss recovery deliberately withholds dependent compound
                    // pictures until the base IDR. Rebuilding the decoder here
                    // races the FIR loop and discards every recovery picture.
                    if m.hasGatedBands {
                        detector = DecodeOutputStallDetector()
                        continue
                    }
                    if detector.observe(
                        submittedFrameCount: progress.submittedFrameCount,
                        deliveredFrameCount: decodedBands.frameCount,
                        nowNanos: DispatchTime.now().uptimeNanoseconds
                    ) {
                        log.warning("Decode-output stall while compressed frames continue; "
                            + "rebuilding decoder in media session")
                        recoveryQueue.async { [transport, m] in
                            guard m.recoverDecoderAfterOutputStall() else {
                                return
                            }
                            Task { [transport] in
                                await transport.requestVideoKeyframe()
                            }
                        }
                    }
                }
            }
        }

        // Transport-confirmed RTP loss sends native AFB type-6 feedback before
        // releasing the post-gap packet. If no video is displayed afterwards,
        // AVConference's fail-safe escalates to PSFB FIR and resets expected
        // decoding order. A persistent supervisor keyed off the gate state
        // mirrors that two-stage behavior. It must not be an event-driven
        // task: markLossLocked only fires onLossDetected for a *fresh* latch,
        // so a per-event task that exits with the gate still latched could
        // never be restarted and the display stayed frozen forever.
        if let transport = transportSession {
            let recoveryManager = manager
            let log = logger
            let recoveryQueue = mediaQueue
            let latestLossSSRC = LatestLossSSRC()
            manager.onLossDetected = { [weak transport, latestLossSSRC] ssrc in
                latestLossSSRC.record(ssrc)
                guard let transport else { return }
                // Diagnostic only. A gate latched by the parse/decode-error
                // path has no transport loss report; recovery must still run,
                // so this must never guard the supervisor.
                Task { [transport] in
                    if !(await transport.hasObservedVideoLossFeedback(ssrc: ssrc)) {
                        log.warning("Compressed stream gated without a matching "
                            + "observed RTP loss report")
                    }
                }
            }
            Task { [weak transport, weak recoveryManager, recoveryCoordinator, latestLossSSRC] in
                var escalator = GatedRecoveryEscalator()
                var episodeActive = false
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let transport,
                          let m = recoveryManager,
                          m.isStreamActive else { return }
                    guard m.decodeProgress.streamGeneration == streamGeneration else { return }
                    guard m.hasGatedBands else {
                        // Steady state costs one lock acquisition; skip the
                        // transport actor hop entirely while healthy.
                        if episodeActive {
                            episodeActive = false
                            escalator = GatedRecoveryEscalator()
                            await transport.noteVideoRecoveryComplete()
                            log.info("Recovery gate cleared; capacity restores via normal ramp")
                        }
                        continue
                    }
                    episodeActive = true
                    let ready = await transport.isReadyForVideoKeyframeRecovery(displayGated: true)
                    let action = escalator.observe(
                        gated: true,
                        readyForKeyframe: ready,
                        nowNanos: DispatchTime.now().uptimeNanoseconds)
                    guard action != .none else { continue }
                    // A busy coordinator (startup watchdog mid-FIR) is not a
                    // failure; the uncommitted action is re-offered next tick.
                    guard await recoveryCoordinator.begin() else { continue }
                    let actionNanos = DispatchTime.now().uptimeNanoseconds
                    if action == .rebuildDecoderAndFIR {
                        escalator.noteDecoderRebuilt(nowNanos: actionNanos)
                    }
                    escalator.noteFIRRequested(nowNanos: actionNanos)

                    switch action {
                    case .backoffThenFIR, .rebuildDecoderAndFIR:
                        // Step the advertised bitrate down and give the server
                        // one RCTL interval to apply it, so the retry IDR is
                        // smaller than the burst that was just shredded.
                        await transport.applyVideoRecoveryBackoff()
                        try? await Task.sleep(for: .milliseconds(250))
                    case .none, .requestFIR:
                        break
                    }
                    if action == .rebuildDecoderAndFIR {
                        log.warning("Recovery gate persisted through FIR retries; "
                            + "rebuilding decoder in media session")
                        await withCheckedContinuation { continuation in
                            recoveryQueue.async {
                                _ = m.recoverDecoderAfterOutputStall()
                                continuation.resume()
                            }
                        }
                    }
                    log.warning("No video displayed after RTP loss; applying native FIR "
                        + "fail-safe (attempt \(escalator.firAttempts))")
                    await withCheckedContinuation { continuation in
                        recoveryQueue.async {
                            m.resetExpectedDecodingOrderForRecovery()
                            continuation.resume()
                        }
                    }
                    await transport.requestVideoKeyframe(ssrc: latestLossSSRC.take())
                    await recoveryCoordinator.finish()
                }
            }
        } else {
            manager.onLossDetected = nil
        }

        // VideoToolbox can accept a damaged sample synchronously and report its
        // missing-reference failure later. Rebuild it on the serial media queue,
        // retain the last rendered surface, and use native FIR to refresh it.
        if let transport = transportSession {
            let recoveryQueue = mediaQueue
            let recoveryManager = manager
            manager.onDecoderFailure = { [weak transport, weak recoveryManager] failure in
                guard let transport, let recoveryManager else { return }
                Task { [transport, recoveryManager] in
                    recoveryQueue.async { [transport, recoveryManager] in
                        guard recoveryManager.recoverDecoderInSession() else { return }
                        Task { [transport] in
                            await transport.requestVideoKeyframe(ssrc: failure.ssrc)
                        }
                    }
                }
            }
        } else {
            manager.onDecoderFailure = nil
        }

        // Fast path for the high-rate video RTP: deliver decrypted packets
        // straight from the transport's background executor onto the media queue,
        // bypassing the main-actor `events` stream. Routing ~3000 packets/sec
        // through the main thread both burned CPU and made us fall behind and
        // drop packets.
        //
        // Installed SYNCHRONOUSLY (awaited) inside offer handling, before the
        // event loop touches the next event. The previous fire-and-forget Task
        // raced the stream start: the first packets — parameter sets and the
        // session's initial IRAP — could flow through the (buffered, slower)
        // events path while later packets took the sink path, reordering the
        // stream right at the decoder bootstrap. One scramble there and every
        // band renders garbage for the rest of the session, because this
        // stream could not be recovered without its negotiated loss feedback.
        // This was the GUI-only "macroblock mess": headless probes that
        // awaited the sink install decoded the same stream pixel-perfectly.
        if let transport = transportSession {
            let queue = mediaQueue
            let sinkManager = manager // VideoStreamManager is Sendable
            let sinkAudioPlayer = remoteAudioPlayer
            let generationCoalescer = coalescer
            let generationLog = logger
            let videoPacketCoalescer = OrderedMediaPacketCoalescer(queue: queue) { packets in
                for packet in packets {
                    sinkManager.feedRTPData(packet)
                }
            }
            await transport.setAppleMediaGenerationSink { generation, numberOfTiles in
                queue.async {
                    sinkManager.prepareForStreamReconfiguration(
                        mediaGeneration: generation,
                        numberOfTiles: numberOfTiles)
                    decodedBands.reset()
                    generationCoalescer.beginStreamGeneration(
                        generation,
                        expectedSourceCount: numberOfTiles)

                    // The connection-level startup watchdog cannot validate a
                    // replacement generation: its SSRC set belongs to retired
                    // media. Require every new tile to decode before declaring
                    // this generation live, otherwise the atomic renderer can
                    // retain the old whole-screen frame forever.
                    Task { [weak transport, weak sinkManager, recoveryCoordinator] in
                        for attempt in 1...4 {
                            try? await Task.sleep(for: .seconds(1))
                            guard let transport,
                                  let manager = sinkManager,
                                  manager.isStreamActive,
                                  manager.currentMediaGeneration == generation else { return }
                            let decoded = decodedBands.count
                            if decoded >= numberOfTiles {
                                if attempt > 1 {
                                    generationLog.info(
                                        "Media generation \(generation) ready: "
                                            + "\(decoded)/\(numberOfTiles) tiles decoded")
                                }
                                return
                            }
                            let ready = await transport.isReadyForVideoKeyframeRecovery()
                            guard (ready || attempt == 4),
                                  await recoveryCoordinator.begin() else { continue }
                            generationLog.warning(
                                "Media generation \(generation) has \(decoded)/"
                                    + "\(numberOfTiles) decoded tiles; requesting FIR "
                                    + "attempt \(attempt)")
                            await transport.requestVideoKeyframe()
                            await recoveryCoordinator.finish()
                        }
                    }
                }
                // A media generation installs fresh SRTP keys for audio as
                // well as video. Reset once at that real codec boundary; the
                // repeated stream-offer path above intentionally does not.
                sinkAudioPlayer?.reset()
            }
            await transport.setAppleRemoteDisplaySizeSink { [weak self] width, height in
                Task { @MainActor [weak self] in
                    self?.applyDesktopResizeMetadata(width: width, height: height)
                }
            }
            await transport.setAppleMediaRTPSink { packet in
                if AppleRemoteAudioPlayer.canHandleRTPPacket(packet) {
                    sinkAudioPlayer?.enqueueRTPPacket(packet)
                } else {
                    videoPacketCoalescer.enqueue(packet)
                }
            }
        }
    }

    /// Route decrypted Apple media without allowing system audio to enter the
    /// HEVC demuxer. This also covers the brief event-stream path before the
    /// transport installs its direct high-rate sink.
    private func routeAppleMediaRTPPacket(_ packet: Data) {
        if AppleRemoteAudioPlayer.canHandleRTPPacket(packet) {
            remoteAudioPlayer?.enqueueRTPPacket(packet)
        } else {
            let manager = videoStreamManager
            mediaQueue.async { manager?.feedRTPData(packet) }
        }
    }


    private func mapProtocolError(_ error: VNCProtocolError) -> VNCError {
        switch error {
        case .authenticationFailed(let reason):
            return .authenticationFailed(reason)
        case .connectionClosed:
            return .connectionFailed("Connection closed by server")
        case .timeout:
            return .connectionFailed("Connection timed out")
        case .ioError(let detail):
            return .connectionFailed(detail)
        case .unsupportedVersion:
            return .unsupportedFeature("Server protocol version not supported")
        case .unsupportedEncoding(let id):
            return .unsupportedFeature("Encoding \(id) not supported")
        default:
            return .protocolError(error)
        }
    }
}

/// Carries a decoded pixel buffer across the (main-actor) hop to the renderer.
/// CVPixelBuffer isn't Sendable, but we hand off ownership and only touch it on
/// the main thread.
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Diagnostic: saves periodic PNGs of decoded band buffers exactly as they are
/// handed to the renderer. `ROOTSHELL_VNC_FRAME_OUT_DIR=<dir>` selects an
/// explicit directory; Debug builds otherwise use this app's sandboxed Caches
/// directory so a normal Xcode launch can capture without changing its network
/// execution context.
/// Lets a live GUI session's decode output be compared against what the screen
/// shows, isolating decode-path vs display-path corruption. PNG encoding runs
/// on a background queue so the tap doesn't perturb delivery timing.
final class DiagnosticFrameDumper: @unchecked Sendable {
    private let dir: String
    private let lock = NSLock()
    private var perBandCounter: [UInt32: Int] = [:]
    private var dumpsRemaining = 60
    private let queue = DispatchQueue(label: "com.rootshell.vnc.framedump", qos: .utility)
    private let ciContext = CIContext()

    static func fromEnvironment() -> DiagnosticFrameDumper? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        let root: URL
        if let explicit = environment["ROOTSHELL_VNC_FRAME_OUT_DIR"], !explicit.isEmpty {
            root = URL(fileURLWithPath: explicit, isDirectory: true)
        } else {
            #if DEBUG
            guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            root = caches.appendingPathComponent("rootshellVNC/DecodedFrames", isDirectory: true)
            #else
            return nil
            #endif
        }

        let sessionDirectory = root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true)
        } catch {
            VNCLogger(category: "FrameCapture").warning(
                "Could not create decoded-frame capture directory: \(error.localizedDescription)")
            return nil
        }
        VNCLogger(category: "FrameCapture").info(
            "Capturing decoded frames in \(sessionDirectory.path)")
        return DiagnosticFrameDumper(dir: sessionDirectory.path)
    }

    private init(dir: String) {
        self.dir = dir
    }

    func maybeDump(_ pixelBuffer: CVPixelBuffer, ssrc: UInt32) {
        lock.lock()
        let n = perBandCounter[ssrc, default: 0]
        perBandCounter[ssrc] = n + 1
        // One dump per band every ~2 s of frames, bounded for the session.
        guard n % 120 == 0, dumpsRemaining > 0 else {
            lock.unlock()
            return
        }
        dumpsRemaining -= 1
        lock.unlock()

        let box = SendablePixelBuffer(pixelBuffer)
        let path = "\(dir)/gui_n\(n)_band\(ssrc & 0xffff).png"
        queue.async { [ciContext] in
            let ci = CIImage(cvPixelBuffer: box.buffer)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent),
                  let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

/// Tracks which video sources (bands) have delivered at least one decoded
/// frame; the dead-band watchdog compares this against the transport's count.
final class DecodedBandTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var ssrcs: Set<UInt32> = []
    private var frames: UInt64 = 0

    func record(_ ssrc: UInt32) {
        lock.lock()
        ssrcs.insert(ssrc)
        frames &+= 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        ssrcs.removeAll(keepingCapacity: true)
        frames = 0
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ssrcs.count
    }

    var frameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

/// Detects a decoder/display wedge from progress counters. The detector is
/// deliberately ignorant of pixels: it fires only when new compressed access
/// units are submitted but delivered-frame progress remains unchanged.
struct DecodeOutputStallDetector {
    private var previousSubmittedFrameCount: UInt64 = 0
    private var previousDeliveredFrameCount: UInt64 = 0
    private var stalledSinceNanos: UInt64?
    private var lastRecoveryNanos: UInt64 = 0

    let stallThresholdNanos: UInt64
    let recoveryCooldownNanos: UInt64

    init(
        stallThresholdNanos: UInt64 = 1_000_000_000,
        recoveryCooldownNanos: UInt64 = 2_000_000_000
    ) {
        self.stallThresholdNanos = stallThresholdNanos
        self.recoveryCooldownNanos = recoveryCooldownNanos
    }

    mutating func observe(
        submittedFrameCount: UInt64,
        deliveredFrameCount: UInt64,
        nowNanos: UInt64
    ) -> Bool {
        let submissionsAdvanced = submittedFrameCount > previousSubmittedFrameCount
        let outputAdvanced = deliveredFrameCount > previousDeliveredFrameCount
        previousSubmittedFrameCount = submittedFrameCount
        previousDeliveredFrameCount = deliveredFrameCount

        if outputAdvanced {
            stalledSinceNanos = nil
            return false
        }
        guard submissionsAdvanced else { return false }
        guard let stalledSinceNanos else {
            self.stalledSinceNanos = nowNanos
            return false
        }
        guard nowNanos &- stalledSinceNanos >= stallThresholdNanos else { return false }
        guard lastRecoveryNanos == 0
                || nowNanos &- lastRecoveryNanos >= recoveryCooldownNanos else { return false }
        lastRecoveryNanos = nowNanos
        return true
    }
}

/// Escalation policy for a latched recovery gate. Pure timing state: the
/// caller performs the actions and commits them via the note methods, so an
/// action that could not run (busy recovery coordinator) is re-offered on the
/// next observation instead of being silently consumed.
///
/// Ladder: 2 s grace for NACK/AFB retransmission, first FIR when the rate
/// controller settles (bounded at 4 s — a busy screen may never settle), then
/// escalating retries that first step the advertised bitrate down, and a
/// decoder rebuild as last resort. Every threshold is an absolute bound on
/// gate age; nothing in the ladder can defer recovery indefinitely.
struct GatedRecoveryEscalator {
    enum Action: Equatable {
        case none
        case requestFIR
        case backoffThenFIR
        case rebuildDecoderAndFIR
    }

    private var gateObservedSinceNanos: UInt64?
    private var lastFIRNanos: UInt64?
    private var lastRebuildNanos: UInt64 = 0
    private(set) var firAttempts = 0

    let graceNanos: UInt64
    let forcedFirstFIRNanos: UInt64
    let retryIntervalsNanos: [UInt64]
    let rebuildGateAgeNanos: UInt64
    let rebuildAttemptThreshold: Int
    let rebuildCooldownNanos: UInt64

    init(
        graceNanos: UInt64 = 2_000_000_000,
        forcedFirstFIRNanos: UInt64 = 4_000_000_000,
        retryIntervalsNanos: [UInt64] = [1_500_000_000, 2_000_000_000, 3_000_000_000],
        rebuildGateAgeNanos: UInt64 = 12_000_000_000,
        rebuildAttemptThreshold: Int = 5,
        rebuildCooldownNanos: UInt64 = 10_000_000_000
    ) {
        self.graceNanos = graceNanos
        self.forcedFirstFIRNanos = forcedFirstFIRNanos
        self.retryIntervalsNanos = retryIntervalsNanos
        self.rebuildGateAgeNanos = rebuildGateAgeNanos
        self.rebuildAttemptThreshold = rebuildAttemptThreshold
        self.rebuildCooldownNanos = rebuildCooldownNanos
    }

    mutating func observe(gated: Bool, readyForKeyframe: Bool, nowNanos: UInt64) -> Action {
        guard gated else {
            gateObservedSinceNanos = nil
            lastFIRNanos = nil
            firAttempts = 0
            return .none
        }
        let since: UInt64
        if let existing = gateObservedSinceNanos {
            since = existing
        } else {
            gateObservedSinceNanos = nowNanos
            since = nowNanos
        }
        let gateAge = nowNanos &- since
        guard gateAge >= graceNanos else { return .none }

        guard let lastFIRNanos else {
            // First FIR: prefer waiting for the rate controller to settle,
            // but a busy screen can stay unsettled forever — bound it.
            return (readyForKeyframe || gateAge >= forcedFirstFIRNanos)
                ? .requestFIR
                : .none
        }
        let intervalIndex = min(max(firAttempts - 1, 0), retryIntervalsNanos.count - 1)
        guard nowNanos &- lastFIRNanos >= retryIntervalsNanos[intervalIndex] else {
            return .none
        }
        if gateAge >= rebuildGateAgeNanos || firAttempts >= rebuildAttemptThreshold,
           lastRebuildNanos == 0 || nowNanos &- lastRebuildNanos >= rebuildCooldownNanos {
            return .rebuildDecoderAndFIR
        }
        // Retries do not wait for readiness — the bound is the point. The
        // caller steps the advertised bitrate down first so the retry IDR is
        // smaller and deliverable while motion continues.
        return .backoffThenFIR
    }

    mutating func noteFIRRequested(nowNanos: UInt64) {
        lastFIRNanos = nowNanos
        firAttempts += 1
    }

    /// A rebuild re-enters the retry ladder with a fresh decoder; the FIR
    /// that accompanies it is counted separately via noteFIRRequested.
    mutating func noteDecoderRebuilt(nowNanos: UInt64) {
        lastRebuildNanos = nowNanos
        firAttempts = 0
    }
}

/// Latest loss-affected SSRC handed from the media queue to the recovery
/// supervisor. The recovery gate is global and the server sends its recovery
/// IDR on the base SSRC, so the value is advisory: FIR falls back to the base
/// video channel when no specific SSRC was recorded.
final class LatestLossSSRC: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt32?

    func record(_ ssrc: UInt32?) {
        guard let ssrc else { return }
        lock.lock()
        value = ssrc
        lock.unlock()
    }

    func take() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        let taken = value
        value = nil
        return taken
    }
}

/// Retains a complete compound HEVC surface set. Moving bands are frozen into
/// one coherent publish set; Apple change-gates static tiles, so the bounded
/// fallback may pair a dirty tile with the last displayed static surface.
struct AtomicBandFrameAccumulator<Value> {
    let expectedSourceCount: Int
    private var sources: Set<UInt32> = []
    private var latest: [UInt32: Value] = [:]
    private var pendingSources: Set<UInt32> = []
    /// Freeze a synchronized surface set as soon as every band has advanced.
    /// Later decoder callbacks belong to the next set and must not overwrite
    /// one member of this set before the main thread presents it.
    private var synchronizedFrame: [UInt32: Value]?

    init(expectedSourceCount: Int) {
        self.expectedSourceCount = expectedSourceCount
    }

    mutating func submit(source: UInt32, value: Value) {
        sources.insert(source)
        latest[source] = value
        pendingSources.insert(source)
        promoteSynchronizedFrameIfPossible()
    }

    var hasSynchronizedFrame: Bool {
        synchronizedFrame != nil
    }

    var hasCompletePendingSnapshot: Bool {
        sources.count == expectedSourceCount
            && sources.allSatisfy { latest[$0] != nil }
            && !pendingSources.isEmpty
    }

    mutating func takeSynchronizedFrame() -> [UInt32: Value]? {
        guard let frame = synchronizedFrame else { return nil }
        synchronizedFrame = nil
        promoteSynchronizedFrameIfPossible()
        return frame
    }

    /// Bounded-latency escape hatch for Apple's change-gated tiles. If only a
    /// dirty band emits, publish it with the retained static bands after the
    /// coalescing deadline instead of waiting forever.
    mutating func takeLatestPendingSnapshot() -> [UInt32: Value]? {
        guard synchronizedFrame == nil, hasCompletePendingSnapshot else {
            return nil
        }
        pendingSources.removeAll(keepingCapacity: true)
        return latest.filter { sources.contains($0.key) }
    }

    private mutating func promoteSynchronizedFrameIfPossible() {
        guard synchronizedFrame == nil,
              sources.count == expectedSourceCount,
              pendingSources.count == expectedSourceCount else { return }
        synchronizedFrame = latest.filter { sources.contains($0.key) }
        pendingSources.removeAll(keepingCapacity: true)
    }
}

/// Delivers synchronized decoded screen bands to the main-thread renderer.
/// Complete moving-band sets use one immediate FIFO main-queue hop. A short
/// deadline prevents a genuinely static/change-gated band from adding stalls.
final class BandFrameCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = AtomicBandFrameAccumulator<CVPixelBuffer>(
        expectedSourceCount: Int(AppleMediaVideoMode.negotiatedTilesPerFrame))
    private var immediateHopScheduled = false
    private var fallbackHopScheduled = false
    private var streamGeneration: UInt64 = 0
    private let renderer: VideoBandLayerRenderer
    /// Half a 60 Hz refresh and roughly one 120 Hz refresh. Normally every
    /// moving band arrives first and is presented immediately; this deadline
    /// applies only when the server suppresses an unchanged band.
    private let fallbackDelay = DispatchTimeInterval.milliseconds(8)

    init(
        renderer: VideoBandLayerRenderer,
        expectedSourceCount: Int = Int(AppleMediaVideoMode.negotiatedTilesPerFrame)
    ) {
        self.renderer = renderer
        accumulator = AtomicBandFrameAccumulator(
            expectedSourceCount: expectedSourceCount)
    }

    /// Drop decoded values staged from the retired media generation and queue
    /// the visual handoff before any subsequently submitted frame can queue its
    /// own main-thread hop. The renderer keeps showing its last committed
    /// surfaces until that first replacement frame exists.
    func beginStreamGeneration(
        _ generation: UInt64,
        expectedSourceCount: Int
    ) {
        lock.lock()
        streamGeneration = generation
        accumulator = AtomicBandFrameAccumulator<CVPixelBuffer>(
            expectedSourceCount: expectedSourceCount)
        immediateHopScheduled = false
        fallbackHopScheduled = false
        lock.unlock()

        DispatchQueue.main.async { [renderer] in
            MainActor.assumeIsolated {
                renderer.beginStreamGeneration(
                    expectedBandCount: expectedSourceCount)
            }
        }
    }

    func submit(ssrc: UInt32, pixelBuffer: CVPixelBuffer) {
        lock.lock()
        accumulator.submit(source: ssrc, value: pixelBuffer)
        let shouldScheduleImmediate = accumulator.hasSynchronizedFrame
            && !immediateHopScheduled
        let shouldScheduleFallback = accumulator.hasCompletePendingSnapshot
            && !fallbackHopScheduled
        let generation = streamGeneration
        if shouldScheduleImmediate { immediateHopScheduled = true }
        if shouldScheduleFallback { fallbackHopScheduled = true }
        lock.unlock()

        if shouldScheduleImmediate {
            scheduleImmediateRendererHop(generation: generation)
        }
        if shouldScheduleFallback {
            scheduleFallbackRendererHop(generation: generation)
        }
    }

    private func scheduleImmediateRendererHop(generation: UInt64) {
        DispatchQueue.main.async { [self] in
            lock.lock()
            guard generation == streamGeneration else {
                // This hop was queued by the retired media generation. Its
                // accumulator was deliberately discarded; leave the new
                // generation's scheduled-hop state untouched.
                lock.unlock()
                return
            }
            let frames = accumulator.takeSynchronizedFrame()
            immediateHopScheduled = false
            let scheduleNext = accumulator.hasSynchronizedFrame
            if scheduleNext { immediateHopScheduled = true }
            let scheduleFallback = accumulator.hasCompletePendingSnapshot
                && !fallbackHopScheduled
            if scheduleFallback { fallbackHopScheduled = true }
            lock.unlock()
            if let frames, !frames.isEmpty {
                MainActor.assumeIsolated {
                    renderer.setBands(frames)
                }
            }
            if scheduleNext {
                scheduleImmediateRendererHop(generation: generation)
            }
            if scheduleFallback {
                scheduleFallbackRendererHop(generation: generation)
            }
        }
    }

    private func scheduleFallbackRendererHop(generation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { [self] in
            lock.lock()
            guard generation == streamGeneration else {
                lock.unlock()
                return
            }
            let frames = accumulator.takeLatestPendingSnapshot()
            fallbackHopScheduled = false
            lock.unlock()
            guard let frames, !frames.isEmpty else { return }
            MainActor.assumeIsolated {
                renderer.setBands(frames)
            }
        }
    }
}
