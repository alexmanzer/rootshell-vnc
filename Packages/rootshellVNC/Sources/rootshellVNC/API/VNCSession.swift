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

/// Union the selected leading displays and translate the result into the
/// framebuffer's normalized coordinate space.
func normalizedSelectedDisplayRegion(
    _ regions: [CGRect],
    displayCount: Int
) -> CGRect? {
    guard let first = regions.first else { return nil }
    let all = regions.dropFirst().reduce(first) { $0.union($1) }
    let count = min(max(1, displayCount), regions.count)
    let selected = regions.prefix(count).dropFirst().reduce(first) {
        $0.union($1)
    }
    return selected.offsetBy(dx: -all.minX, dy: -all.minY)
}

/// Edge detector for Apple Login Window announcements. DisplayInfo2 is sent
/// repeatedly while a layout is stable, but a password prompt should only be
/// offered once per entry into the login or lock-screen state.
struct AppleLoginPromptTransitionTracker {
    private(set) var isLoginActive = false

    mutating func update(
        isLoginActive newValue: Bool,
        promptEnabled: Bool,
        canSendPassword: Bool
    ) -> Bool {
        let enteredLogin = newValue && !isLoginActive
        isLoginActive = newValue
        return enteredLogin && promptEnabled && canSendPassword
    }

    mutating func reset() {
        isLoginActive = false
    }
}

/// Holds one user-approved password-send intent across Match Client display
/// transitions. A token is valid only for the latest requested display target
/// and latest complete High Performance media generation.
struct LoginPasswordSendStabilityGate {
    struct Token: Sendable, Equatable {
        let displayRevision: UInt64
        let mediaGeneration: UInt64
    }

    private(set) var isPending = false
    private(set) var displayRevision: UInt64 = 0
    private(set) var stableCandidate: Token?
    private(set) var isTransportSettled = false

    mutating func requestSend() -> Token? {
        isPending = true
        return isTransportSettled ? stableCandidate : nil
    }

    mutating func displayTargetChanged() {
        displayRevision &+= 1
        isTransportSettled = false
        stableCandidate = nil
    }

    mutating func transportSettled(_ settled: Bool) {
        guard settled != isTransportSettled else { return }
        isTransportSettled = settled
        // A frame committed before the transport finished draining queued
        // resize commands may belong to the capture graph being retired.
        displayRevision &+= 1
        stableCandidate = nil
    }

    mutating func noteEligibleFrame(mediaGeneration: UInt64) -> Token? {
        guard isTransportSettled else { return nil }
        let token = Token(
            displayRevision: displayRevision,
            mediaGeneration: mediaGeneration)
        stableCandidate = token
        return isPending ? token : nil
    }

    mutating func consume(_ token: Token) -> Bool {
        guard isPending, stableCandidate == token else { return false }
        isPending = false
        return true
    }

    mutating func reset() {
        isPending = false
        isTransportSettled = false
        displayRevision &+= 1
        stableCandidate = nil
    }
}

private enum AppleLoginVisionFrame: @unchecked Sendable {
    case image(CGImage)
    case pixelBuffer(CVPixelBuffer)
}

private struct AppleLoginVisionOutcome: Sendable {
    let analysis: AppleLoginTextAnalysis?
    let errorDescription: String?
    let elapsedMilliseconds: UInt64
}

/// Tracks the portions of Apple DCT type-0 base images that have not yet been
/// covered by type-1 refinement rectangles. A large base is commonly followed
/// by many horizontal bands, not one refinement message.
struct AppleDCTRefinementTracker {
    private(set) var uncoveredRegions: [CGRect] = []

    var isAwaitingRefinement: Bool { !uncoveredRegions.isEmpty }

    mutating func reset() {
        uncoveredRegions.removeAll(keepingCapacity: true)
    }

    @discardableResult
    mutating func ingest(
        _ rects: [(FramebufferRect, Data)]
    ) -> Bool {
        for (rect, payload) in rects {
            let region = CGRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height))
            guard !region.isEmpty else { continue }

            if rect.encoding == .appleMultiVariantScreenshare,
               payload.count >= 5 {
                switch payload[payload.startIndex + 4] {
                case 0: markBase(region)
                case 1: markRefined(region)
                default: break
                }
                continue
            }

            switch rect.encoding {
            case .raw, .zlib, .zrle, .tight, .copyRect:
                // A portable pixel rectangle supersedes any coarse DCT pixels
                // in the same region and needs no progressive refinement.
                markRefined(region)
            case .desktopSize, .extendedDesktopSize:
                reset()
            default:
                break
            }
        }
        return isAwaitingRefinement
    }

    private mutating func markBase(_ region: CGRect) {
        // A newer base replaces any older pending pixels in its area.
        uncoveredRegions = uncoveredRegions.flatMap {
            Self.subtract(region, from: $0)
        }
        uncoveredRegions.append(region)
    }

    private mutating func markRefined(_ region: CGRect) {
        uncoveredRegions = uncoveredRegions.flatMap {
            Self.subtract(region, from: $0)
        }
    }

    private static func subtract(
        _ coverage: CGRect,
        from source: CGRect
    ) -> [CGRect] {
        let intersection = source.intersection(coverage)
        guard !intersection.isNull, !intersection.isEmpty else {
            return [source]
        }
        guard intersection != source else { return [] }

        var remainder: [CGRect] = []
        if source.minY < intersection.minY {
            remainder.append(CGRect(
                x: source.minX, y: source.minY,
                width: source.width,
                height: intersection.minY - source.minY))
        }
        if intersection.maxY < source.maxY {
            remainder.append(CGRect(
                x: source.minX, y: intersection.maxY,
                width: source.width,
                height: source.maxY - intersection.maxY))
        }
        if source.minX < intersection.minX {
            remainder.append(CGRect(
                x: source.minX, y: intersection.minY,
                width: intersection.minX - source.minX,
                height: intersection.height))
        }
        if intersection.maxX < source.maxX {
            remainder.append(CGRect(
                x: intersection.maxX, y: intersection.minY,
                width: source.maxX - intersection.maxX,
                height: intersection.height))
        }
        return remainder
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
    public var connectionState: VNCConnectionState = .idle {
        didSet {
            guard oldValue != connectionState else { return }
            // Snapshot so an observer can remove itself while handling the
            // transition without mutating the dictionary being iterated.
            for observer in Array(connectionStateObservers.values) {
                observer(connectionState)
            }
        }
    }

    /// Human-readable description of the current connection-establishment
    /// phase (dialing, negotiating security, authenticating, …). `nil` once
    /// operational or when no attempt is in flight. Drives the connecting
    /// status overlay, which needs more granularity than the collapsed
    /// `.connecting` state.
    public private(set) var connectionPhaseDescription: String?

    /// Host label for status UI while a connection attempt is in flight.
    public var connectingHostLabel: String? { activeCredentials?.host }

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

    /// Native Apple clipboard controls negotiated for this connection.
    public private(set) var supportsRemoteClipboardRequest = false
    public private(set) var supportsRemoteSharedClipboardControl = false

    /// Number of independently decoded Apple video displays in the current
    /// media generation.
    public private(set) var activeVideoDisplayCount: Int = 1

    /// Server display rectangles, normalized into framebuffer coordinates and
    /// ordered as announced by the server (primary first). Standard mode uses
    /// these to present only the number of displays selected by the user.
    private(set) var remoteDisplayRegions: [CGRect] = []
    @ObservationIgnored
    private var remoteDisplayRegionByID: [UInt32: CGRect] = [:]
    @ObservationIgnored
    private var remoteDisplayRegionOrder: [UInt32] = []

    /// The remote cursor shape from the Cursor pseudo-encoding, adopted by
    /// the local system pointer. Nil when the server has not sent a shape
    /// (or sent an explicit empty one) — callers fall back to the default.
    public private(set) var remoteCursor: RemoteCursor?

    /// Whether the server has requested a one-shot password confirmation for
    /// the current Apple Login Window episode. This remains pending until a
    /// host UI consumes it, so an event received during navigation is not lost.
    public private(set) var loginPasswordPromptPending = false

    // MARK: - Configuration

    /// The configuration for this session.
    public var configuration: VNCConfiguration

    // MARK: - Host Hooks

    /// Invoked on the main actor when the server publishes clipboard text via
    /// RFB ServerCutText or Apple's packed pasteboard extension. Container
    /// applications set this to route the
    /// remote clipboard into their own pasteboard handling; leaving it `nil`
    /// (the default) keeps the log-only behavior.
    @ObservationIgnored
    public var onServerClipboardText: ((String) -> Void)?

    /// Internal multicast used by package features such as shared clipboard.
    /// The public single callback above remains source-compatible for hosts
    /// that already consume raw ServerCutText events themselves.
    @ObservationIgnored
    private var serverClipboardObservers: [UUID: (String) -> Void] = [:]
    @ObservationIgnored
    private var connectionStateObservers: [UUID: (VNCConnectionState) -> Void] = [:]

    /// While `true`, Match Client display-size requests are deferred instead
    /// of sent. Container apps set this when the hosting view is occluded
    /// (hidden tab, backgrounded window) so transient layout changes never
    /// round-trip a resize to the server; clearing it applies the latest
    /// deferred size once, deduplicated against the last request.
    @ObservationIgnored
    public var suspendsRemoteDisplaySizeUpdates: Bool = false {
        didSet {
            guard oldValue, !suspendsRemoteDisplaySizeUpdates,
                  let deferred = deferredDisplaySizeUpdate else { return }
            deferredDisplaySizeUpdate = nil
            updateRemoteDisplaySize(
                viewSize: deferred.viewSize,
                displayScale: deferred.displayScale)
        }
    }

    // MARK: - Internal

    private var transportSession: TransportSession?
    /// Credentials for the active connection. Kept private so UI code can
    /// offer credential actions without ever reading or displaying the secret.
    @ObservationIgnored
    private var activeCredentials: VNCCredentials?
    @ObservationIgnored
    private var appleLoginPromptTracker = AppleLoginPromptTransitionTracker()
    @ObservationIgnored
    private var appleLoginVisionTask: Task<Void, Never>?
    @ObservationIgnored
    private var appleLoginVisionRetryTask: Task<Void, Never>?
    @ObservationIgnored
    private var appleLoginVisionStabilityTask: Task<Void, Never>?
    @ObservationIgnored
    private var appleLoginVisionLatestFrame: (
        frame: AppleLoginVisionFrame,
        source: String,
        highPerformanceGeneration: UInt64?
    )?
    @ObservationIgnored
    private var appleLoginVisionAttemptCount = 0
    @ObservationIgnored
    private var appleLoginVisionLastAttemptNanos: UInt64 = 0
    @ObservationIgnored
    private var appleLoginVisionGeneration: UInt64 = 0
    @ObservationIgnored
    private var appleLoginVisionDetected = false
    @ObservationIgnored
    private var appleLoginVisionPromptOffered = false
    @ObservationIgnored
    private var appleLoginVisionHighPerformanceGeneration: UInt64?
    @ObservationIgnored
    private var appleServerProtocolObserved = false
    @ObservationIgnored
    private var loginPasswordSendGate = LoginPasswordSendStabilityGate()
    @ObservationIgnored
    private var loginPasswordSendStabilityTask: Task<Void, Never>?
    @ObservationIgnored
    private var loginPasswordSendScheduledToken:
        LoginPasswordSendStabilityGate.Token?
    private var framebuffer: Framebuffer?
    private var renderer: FramebufferRenderer?
    private var videoStreamManager: VideoStreamManager?
    private var secondaryVideoStreamManager: VideoStreamManager?
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
    /// Latest viewport reported while size updates were suspended.
    @ObservationIgnored
    private var deferredDisplaySizeUpdate: (viewSize: CGSize, displayScale: CGFloat)?
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
    /// Independent renderer for the second Apple media stream. A second
    /// display is a separate HEVC reference chain, not another band of display
    /// one, and must never share its decoder or band compositor.
    @ObservationIgnored
    public let secondaryVideoBandRenderer = VideoBandLayerRenderer()
    var primaryVideoDecodeProgress: VideoStreamManager.DecodeProgress? {
        videoStreamManager?.decodeProgress
    }
    var secondaryVideoDecodeProgress: VideoStreamManager.DecodeProgress? {
        secondaryVideoStreamManager?.decodeProgress
    }
    func activeTransportVideoSourceCount() async -> Int {
        await transportSession?.videoSourceCount ?? 0
    }
    func activeTransportVideoReceiverIndexes() async -> [Int] {
        await transportSession?.videoSourceReceiverIndexes ?? []
    }
    func activeTransportMediaAnswerStreamLengths() async -> [Int] {
        await transportSession?.mediaAnswerStreamLengths ?? []
    }
    func activeTransportMediaControlDiagnostic() async -> String? {
        await transportSession?.mediaControlDiagnostic
    }
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
    @ObservationIgnored
    private var dctRefinementTracker = AppleDCTRefinementTracker()
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
    /// Sticky across automatic reconnects for this connection attempt. If a
    /// server accepts a one-picture offer but never starts a video source, the
    /// replacement transport retries its known native four-source profile.
    @ObservationIgnored
    private var appleMediaTilesPerFrameOverride: UInt64?
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
        videoBandRenderer.onFrameCommitted = {
            [weak self] pixelBuffer, streamGeneration in
            self?.noteHighPerformanceFrameForPendingLoginPassword(
                pixelBuffer,
                mediaGeneration: streamGeneration)
            self?.considerAppleLoginVisionFrame(
                .pixelBuffer(pixelBuffer),
                source: "High Performance full frame",
                highPerformanceGeneration: streamGeneration)
        }
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

        // Belt-and-braces: the configuration self-heals this combination in
        // its property observers, so reaching this guard means a bug upstream.
        if configuration.transportProvider != nil,
           configuration.videoQualityMode == .adaptive {
            throw VNCError.unsupportedFeature(
                String(localized: "High Performance mode requires a direct network connection and is unavailable over a tunneled transport.", bundle: .module))
        }

        invalidateInputQueue()
        reconnectTask?.cancel()
        reconnectTask = nil
        intentionallyDisconnected = false
        hasEstablishedConnection = false
        connectionState = .connecting
        connectionPhaseDescription = String(localized: "Opening connection…", bundle: .module)
        activeCredentials = credentials
        resetAppleLoginPromptState()
        logger.debug(
            "Apple login prompt configured: enabled="
                + "\(configuration.promptForLoginPasswordAtLoginWindow) "
                + "passwordAvailable=\(!credentials.password.isEmpty) "
                + "quality=\(configuration.videoQualityMode.rawValue) "
                + "displayInfo2Requested="
                + "\(configuration.effectiveEncodings.contains(.unknown(1105)))")
        appleMediaTilesPerFrameOverride = nil
        lastError = nil
        currentImage = nil
        remoteCursor = nil
        isHighPerformanceMode = false
        supportsRemoteClipboardRequest = false
        supportsRemoteSharedClipboardControl = false
        activeVideoDisplayCount = 1
        remoteDisplayRegions = []
        remoteDisplayRegionByID = [:]
        remoteDisplayRegionOrder = []
        trailingSnapshotTask?.cancel()
        trailingSnapshotTask = nil
        dctRefinementTracker.reset()
        lastImagePublishNanos = 0
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = nil
        lastRequestedClientDisplaySize = nil
        diagnostics.isHighPerformanceMode = false
        videoBandRenderer.reset()
        secondaryVideoBandRenderer.reset()
        diagnostics.reset()
        diagnostics.connectionStartTime = Date()
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil

        if configuration.enableProtocolTrace {
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
        resetAppleLoginPromptState()

        // Clear rendering state
        framebuffer = nil
        renderer = nil
        currentImage = nil
        remoteCursor = nil
        isHighPerformanceMode = false
        supportsRemoteClipboardRequest = false
        supportsRemoteSharedClipboardControl = false
        activeVideoDisplayCount = 1
        remoteDisplayRegions = []
        remoteDisplayRegionByID = [:]
        remoteDisplayRegionOrder = []
        trailingSnapshotTask?.cancel()
        trailingSnapshotTask = nil
        dctRefinementTracker.reset()
        lastImagePublishNanos = 0
        videoBandRenderer.reset()
        secondaryVideoBandRenderer.reset()
        videoStreamManager?.stopStream()
        videoStreamManager = nil
        secondaryVideoStreamManager?.stopStream()
        secondaryVideoStreamManager = nil
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil

        connectionPhaseDescription = nil
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

    /// Reconnect an active session using a replacement configuration while
    /// retaining the credentials already held by the session.
    ///
    /// This is intended for UI actions that change handshake-level options,
    /// such as the video transport or remote display sizing mode. The
    /// transition deliberately avoids `.disconnected`, so container apps can
    /// distinguish a configuration restart from an intentional close.
    ///
    /// - Returns: `true` when the restart was accepted. A session must be
    ///   connected, have retained credentials, and not already be reconnecting.
    @discardableResult
    public func reconnect(with configuration: VNCConfiguration) -> Bool {
        guard connectionState.isConnected,
              activeCredentials != nil,
              reconnectTask == nil else { return false }

        self.configuration = configuration
        intentionallyDisconnected = false

        // Mirror the proven media-bootstrap recovery path: close the old
        // transport while the reconnect task performs ordered cleanup and
        // establishes a fresh transport with the replacement configuration.
        let transport = transportSession
        Task { await transport?.disconnect() }
        scheduleReconnect(immediate: true, minimumAttempts: 1)
        return true
    }

    // MARK: - Input Events

    /// Whether the active connection has a password available for the remote
    /// login window. The password itself is intentionally never exposed.
    public var canSendLoginPassword: Bool {
        connectionState.isConnected && !(activeCredentials?.password.isEmpty ?? true)
    }

    /// Apple may publish Login Window state just before its media offer. Treat
    /// that short negotiation window as High Performance too, otherwise an
    /// immediate confirmation can type into the display about to be retired.
    private var shouldDeferLoginPasswordForMatchClientStability: Bool {
        guard configuration.displaySizingMode == .matchClient else {
            return false
        }
        return isHighPerformanceMode
            || (configuration.videoQualityMode == .adaptive
                && appleServerProtocolObserved)
    }

    /// Consume a pending Apple Login Window password prompt.
    ///
    /// Returns `true` exactly once for each pending request. Consuming a
    /// request does not send input; the caller should first present its own
    /// confirmation UI and invoke ``sendLoginPassword()`` only if accepted.
    @discardableResult
    public func consumeLoginPasswordPromptRequest() -> Bool {
        guard loginPasswordPromptPending, canSendLoginPassword else {
            logger.debug(
                "Apple login prompt was not consumed: pending="
                    + "\(loginPasswordPromptPending) "
                    + "canSendPassword=\(canSendLoginPassword)")
            loginPasswordPromptPending = false
            return false
        }
        loginPasswordPromptPending = false
        logger.debug("Apple login prompt consumed by host UI")
        return true
    }

    /// Type the active connection's password and press Return. This mirrors
    /// the behavior of remote-desktop clients' “Type User Password” action.
    /// Callers should obtain confirmation before invoking this method.
    public func sendLoginPassword() {
        guard canSendLoginPassword, let password = activeCredentials?.password else { return }

        guard shouldDeferLoginPasswordForMatchClientStability else {
            sendLoginPasswordNow(password)
            return
        }

        let wasPending = loginPasswordSendGate.isPending
        let token = loginPasswordSendGate.requestSend()
        if let token {
            scheduleLoginPasswordSendAfterStability(token: token)
        }
        if !wasPending {
            logger.info(
                "Password send queued until Match Client display is stable")
        }
    }

    private func sendLoginPasswordNow(_ password: String) {
        logger.info("Sending approved login password input")

        let focusX = UInt16(clamping: framebufferWidth / 2)
        let focusY = UInt16(clamping: framebufferHeight / 2)
        let events = Self.loginPasswordFocusInputEvents(x: focusX, y: focusY)
            + Self.loginPasswordInputEvents(password: password)
        for event in events {
            switch event {
            case .key(let downFlag, let keysym):
                sendKeyEvent(downFlag: downFlag, key: keysym)
            case .pause:
                enqueueInput(event)
            case .pointer(let buttonMask, let x, let y):
                sendPointerEvent(buttonMask: buttonMask, x: x, y: y)
            case .scroll, .gesture, .clipboard, .clipboardRequest,
                 .sharedClipboard:
                assertionFailure("Unexpected event in login password sequence")
            }
        }
    }

    /// Focus macOS Login Window before typing. Pointer events and the pause
    /// share the ordered input queue with the password, so no key can overtake
    /// the click that establishes the secure field's first responder.
    nonisolated static func loginPasswordFocusInputEvents(
        x: UInt16,
        y: UInt16
    ) -> [SessionInputEvent] {
        [
            .pointer(buttonMask: 0, x: x, y: y),
            .pointer(buttonMask: 1, x: x, y: y),
            .pointer(buttonMask: 0, x: x, y: y),
            .pause(nanoseconds: 150_000_000),
        ]
    }

    /// Construct the exact ordered input sequence used by
    /// ``sendLoginPassword()``. Modifier releases prevent a locally held or
    /// remotely latched modifier from changing the password, while a small
    /// delay after each complete key tap gives login windows time to process
    /// secure text input without separating a key-down from its key-up.
    nonisolated static func loginPasswordInputEvents(
        password: String
    ) -> [SessionInputEvent] {
        let modifierKeysyms: [UInt32] = [
            KeyboardInputHandler.keysymCapsLock,
            KeyboardInputHandler.keysymShiftL,
            KeyboardInputHandler.keysymSuperL,
            KeyboardInputHandler.keysymAltL,
            KeyboardInputHandler.keysymControlL,
            KeyboardInputHandler.keysymControlR,
            KeyboardInputHandler.keysymSuperR,
            KeyboardInputHandler.keysymAltR,
            KeyboardInputHandler.keysymShiftR,
        ]
        let interKeyDelayNanoseconds: UInt64 = 5_000_000
        var events = modifierKeysyms.map {
            SessionInputEvent.key(downFlag: false, keysym: $0)
        }

        func appendKeyTap(_ keysym: UInt32) {
            guard keysym != 0 else { return }
            events.append(.key(downFlag: true, keysym: keysym))
            events.append(.key(downFlag: false, keysym: keysym))
            events.append(.pause(nanoseconds: interKeyDelayNanoseconds))
        }

        for character in password {
            appendKeyTap(KeyboardInputHandler.keysymForCharacter(character))
        }
        appendKeyTap(KeyboardInputHandler.keysymReturn)
        return events
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

    /// Request the current remote clipboard from a capable Apple server.
    public func requestRemoteClipboard() {
        guard connectionState.isConnected,
              transportSession != nil,
              supportsRemoteClipboardRequest else { return }
        enqueueInput(.clipboardRequest)
    }

    /// Control Apple's server-side automatic pasteboard notifications.
    public func setRemoteSharedClipboardEnabled(_ enabled: Bool) {
        guard connectionState.isConnected,
              transportSession != nil,
              supportsRemoteSharedClipboardControl else { return }
        enqueueInput(.sharedClipboard(enabled))
    }

    func addServerClipboardObserver(
        _ observer: @escaping (String) -> Void
    ) -> UUID {
        let id = UUID()
        serverClipboardObservers[id] = observer
        return id
    }

    func removeServerClipboardObserver(_ id: UUID) {
        serverClipboardObservers.removeValue(forKey: id)
    }

    func addConnectionStateObserver(
        _ observer: @escaping (VNCConnectionState) -> Void
    ) -> UUID {
        let id = UUID()
        connectionStateObservers[id] = observer
        return id
    }

    func removeConnectionStateObserver(_ id: UUID) {
        connectionStateObservers.removeValue(forKey: id)
    }

    /// Debounce viewport/rotation changes and request a matching remote display
    /// when the user selected Match Client. The transport capability-gates both
    /// Apple's virtual-display command and standard RFB SetDesktopSize.
    func matchingClientDisplaySize(
        viewSize: CGSize,
        displayScale _: CGFloat
    ) -> RemoteDisplaySize? {
        guard configuration.displaySizingMode == .matchClient,
              ProcessInfo.processInfo.environment[
                "ROOTSHELL_VNC_DISABLE_MATCH_CLIENT"] != "1" else { return nil }
        let size = RemoteDisplaySize.matching(viewSize: viewSize)
        if RenderCommitStats.shared != nil, let size {
            VNCLogger(category: "RenderStats").debug(
                "DISPLAYREQ pixels=\(size.pixelWidth)x\(size.pixelHeight) "
                    + "points=\(size.pointWidth)x\(size.pointHeight)")
        }
        return size
    }

    public func updateRemoteDisplaySize(
        viewSize: CGSize,
        displayScale: CGFloat
    ) {
        if suspendsRemoteDisplaySizeUpdates {
            deferredDisplaySizeUpdate = (viewSize, displayScale)
            return
        }
        guard let requested = matchingClientDisplaySize(
            viewSize: viewSize,
            displayScale: displayScale) else { return }

        // ConnectionView supplies the viewport before connecting; the remote
        // desktop view keeps it current for window changes and device rotation.
        let displayTargetChanged = preparedClientDisplaySize != requested
        preparedClientDisplaySize = requested

        if displayTargetChanged,
           isHighPerformanceMode || loginPasswordSendGate.isPending {
            loginPasswordSendGate.displayTargetChanged()
            cancelScheduledLoginPasswordSend()
        }

        guard connectionState.isConnected,
              let transport = transportSession,
              requested != lastRequestedClientDisplaySize else { return }

        if isHighPerformanceMode {
            restartAppleLoginVisionForDisplayTransition(
                reason: "Match Client target changed")
        }
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
                await self.handleSessionEvent(event, from: transport)
            }
        }
    }

    private func handleSessionEvent(
        _ event: SessionEvent,
        from transport: TransportSession
    ) async {
        switch event {
        case .stateChanged(let protocolState):
            handleStateChanged(protocolState)

        case .serverInit(let serverInit):
            supportsRemoteClipboardRequest =
                await transport.supportsRemoteClipboardRequest
            supportsRemoteSharedClipboardControl =
                await transport.supportsRemoteSharedClipboardControl
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
            if isTraceEnabled {
                diagnostics.protocolTrace.recordReceived(
                    type: "ServerCutText",
                    data: Data(text.utf8),
                    details: "length=\(text.utf8.count)"
                )
            }
            onServerClipboardText?(text)
            // Snapshot the callbacks so observers may invalidate themselves
            // safely while handling an event.
            for observer in Array(serverClipboardObservers.values) {
                observer(text)
            }

        case .bell:
            logger.debug("Server bell")

        case .error(let error):
            handleError(error)

        case .encryptionInfo(let info):
            logger.info("Encryption info: cipher=\(info.cipherMode) keyLen=\(info.keyLength)")
            diagnostics.encryptionMode = "Cipher mode \(info.cipherMode), key length \(info.keyLength)"

        case .displayInfo(let info):
            appleServerProtocolObserved = true
            logger.info("Display info: \(info.width)x\(info.height) at (\(info.originX),\(info.originY))")
            updateRemoteDisplayRegion(
                id: info.displayIndex,
                x: Int(info.originX),
                y: Int(info.originY),
                width: Int(info.width),
                height: Int(info.height))

        case .appleRemoteSessionState(let state):
            appleServerProtocolObserved = true
            handleAppleRemoteSessionState(state)

        case .desktopLayout(let layout):
            updateRemoteDisplayRegions(layout.screens)

        case .mediaStreamOffer(let offer):
            appleServerProtocolObserved = true
            logger.info(
                "Media stream offer: stream=\(offer.streamID) type=\(offer.messageType ?? 0) "
                    + "audioPort=\(offer.audioStreamUDPPort ?? 0) "
                    + "videoPort=\(offer.videoStream1UDPPort ?? 0) "
                    + "displays=\(offer.videoStreamDisplayCount ?? 0) "
                    + "payloadBytes=\(offer.rawPayload.count)"
            )
            isHighPerformanceMode = true
            activeVideoDisplayCount = configuration.displaySizingMode == .matchClient
                ? min(configuration.displayCount,
                      offer.videoStreamDisplayCount ?? 1)
                : 1
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
        // Track the phase before the guards below: reconnect keeps the public
        // state pinned to .reconnecting while the replacement handshake
        // advances, but the overlay still wants the live phase text.
        connectionPhaseDescription = Self.phaseDescription(for: protocolState)
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

    private static func phaseDescription(
        for protocolState: RFBProtocol.ConnectionState
    ) -> String? {
        switch protocolState {
        case .connecting:
            return String(localized: "Opening connection…", bundle: .module)
        case .waitingForProtocolVersion:
            return String(localized: "Negotiating protocol…", bundle: .module)
        case .waitingForSecurityTypes:
            return String(localized: "Negotiating security…", bundle: .module)
        case .authenticating:
            return String(localized: "Authenticating…", bundle: .module)
        case .waitingForAuthResult:
            return String(localized: "Verifying credentials…", bundle: .module)
        case .waitingForServerInit:
            return String(localized: "Starting remote session…", bundle: .module)
        case .idle, .operational, .disconnecting, .disconnected, .failed:
            return nil
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

    private func updateRemoteDisplayRegion(
        id: UInt32,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        guard width > 0, height > 0 else { return }
        if remoteDisplayRegionByID[id] == nil {
            remoteDisplayRegionOrder.append(id)
        }
        remoteDisplayRegionByID[id] = CGRect(
            x: x, y: y, width: width, height: height)
        remoteDisplayRegions = remoteDisplayRegionOrder.compactMap {
            remoteDisplayRegionByID[$0]
        }
        applyDiscoveredRemoteMediaGeometry()
    }

    private func updateRemoteDisplayRegions(_ screens: [RFBScreenLayout]) {
        guard !screens.isEmpty else { return }
        remoteDisplayRegionByID.removeAll(keepingCapacity: true)
        remoteDisplayRegionOrder = screens.map(\.id)
        remoteDisplayRegions = screens.map {
            let region = CGRect(
                x: Int($0.x), y: Int($0.y),
                width: Int($0.width), height: Int($0.height))
            remoteDisplayRegionByID[$0.id] = region
            return region
        }
        applyDiscoveredRemoteMediaGeometry()
    }

    /// ServerInit is the full physical desktop union, while Apple's media
    /// receiver targets the selected single or combined topology. Apply
    /// DisplayInfo as soon as it arrives so the band compositor and input
    /// aspect use the receiver's real geometry on first connections as well as
    /// reconnects.
    private func applyDiscoveredRemoteMediaGeometry() {
        guard isHighPerformanceMode,
              configuration.displaySizingMode == .remoteDisplay,
              let manager = videoStreamManager,
              !remoteDisplayRegions.isEmpty else { return }

        let selectedCount = min(
            max(1, configuration.displayCount),
            remoteDisplayRegions.count)
        guard let first = remoteDisplayRegions.first else { return }
        let selected = remoteDisplayRegions.prefix(selectedCount)
            .dropFirst()
            .reduce(first) { $0.union($1) }
        let width = Int(selected.width)
        let height = Int(selected.height)
        guard width > 0, height > 0 else { return }

        videoBandRenderer.setScreenSize(width: width, height: height)
        let queue = mediaQueue
        queue.async {
            manager.updateFrameGeometry(width: width, height: height)
        }
    }

    /// Selected framebuffer rectangle in the server's normalized desktop
    /// coordinates. Nil means the server has not described its monitor layout.
    var presentedFramebufferRegion: CGRect? {
        // Match Client replaces the physical monitor topology with equal-sized
        // virtual displays. DisplayInfo from the pre-reconfiguration desktop
        // can remain in flight, so its rectangles are not authoritative here.
        guard !(isHighPerformanceMode
                && configuration.displaySizingMode == .matchClient) else {
            return nil
        }
        return normalizedSelectedDisplayRegion(
            remoteDisplayRegions,
            displayCount: configuration.displayCount)
    }

    var presentedFramebufferSize: CGSize {
        presentedFramebufferRegion?.size ?? CGSize(
            width: framebufferWidth,
            height: framebufferHeight)
    }

    var presentedVideoDisplayRegions: [CGRect] {
        let count = max(1, activeVideoDisplayCount)
        if configuration.displaySizingMode != .matchClient,
           remoteDisplayRegions.count >= count {
            if count == 1,
               configuration.displayCount > 1,
               remoteDisplayRegions.count >= configuration.displayCount {
                // Apple's physical "All Displays" mode is one HEVC stream
                // whose format is the union of the selected monitor regions.
                // Present that stream once at the composite aspect ratio.
                let selected = Array(
                    remoteDisplayRegions.prefix(configuration.displayCount))
                guard let first = selected.first else { return [] }
                let union = selected.dropFirst().reduce(first) { $0.union($1) }
                return [CGRect(origin: .zero, size: union.size)]
            }
            let selected = Array(remoteDisplayRegions.prefix(count))
            guard let first = selected.first else { return [] }
            let union = selected.dropFirst().reduce(first) { $0.union($1) }
            return selected.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }
        }

        let totalWidth = max(1, framebufferWidth)
        let width = CGFloat(totalWidth) / CGFloat(count)
        let height = CGFloat(max(1, framebufferHeight))
        return (0..<count).map {
            CGRect(x: CGFloat($0) * width, y: 0, width: width, height: height)
        }
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
        let publishDue = renderStarted &- lastImagePublishNanos >= publishInterval
        let wasAwaitingDCTRefinement =
            dctRefinementTracker.isAwaitingRefinement
        let awaitsDCTRefinement = dctRefinementTracker.ingest(rects)
        let completedDCTRefinement =
            wasAwaitingDCTRefinement && !awaitsDCTRefinement
        let takeSnapshot = publishDue && !awaitsDCTRefinement
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
            considerAppleLoginVisionFrame(
                .image(image),
                source: "Standard framebuffer snapshot")
        } else {
            if awaitsDCTRefinement || completedDCTRefinement {
                // Pending bases replace cadence-only snapshots so they cannot
                // publish coarse pixels. Completion replaces the longer
                // safety timeout with the ordinary presentation cadence.
                trailingSnapshotTask?.cancel()
                trailingSnapshotTask = nil
            }
            scheduleTrailingSnapshot(
                interval: publishInterval,
                minimumDelay: awaitsDCTRefinement ? 50_000_000 : 0,
                resetsDCTRefinement: awaitsDCTRefinement)
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
        func mediaDisplaySize(at index: Int) -> (width: Int, height: Int) {
            if isHighPerformanceMode,
               configuration.displaySizingMode != .matchClient,
               remoteDisplayRegions.indices.contains(index) {
                if index == 0,
                   activeVideoDisplayCount == 1,
                   configuration.displayCount > 1,
                   remoteDisplayRegions.count >= configuration.displayCount {
                    let selected = remoteDisplayRegions.prefix(
                        configuration.displayCount)
                    if let first = selected.first {
                        let union = selected.dropFirst().reduce(first) {
                            $0.union($1)
                        }
                        return (Int(union.width), Int(union.height))
                    }
                }
                let region = remoteDisplayRegions[index]
                return (Int(region.width), Int(region.height))
            }
            let width = activeVideoDisplayCount > 1
                ? newWidth / activeVideoDisplayCount
                : newWidth
            return (width, newHeight)
        }
        let primarySize = mediaDisplaySize(at: 0)
        videoBandRenderer.setScreenSize(
            width: primarySize.width,
            height: primarySize.height)
        if activeVideoDisplayCount > 1 {
            let secondarySize = mediaDisplaySize(at: 1)
            secondaryVideoBandRenderer.setScreenSize(
                width: secondarySize.width,
                height: secondarySize.height)
        }

        if let manager = videoStreamManager {
            let secondaryManager = secondaryVideoStreamManager
            let secondarySize = mediaDisplaySize(at: 1)
            mediaQueue.async {
                manager.updateFrameGeometry(
                    width: primarySize.width,
                    height: primarySize.height)
                secondaryManager?.updateFrameGeometry(
                    width: secondarySize.width,
                    height: secondarySize.height)
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
        if configuration.displaySizingMode != .matchClient,
           configuration.displayCount > 1,
           remoteDisplayRegions.count >= configuration.displayCount {
            // In Apple's physical All Displays mode the codec raster can stay
            // at the primary encoder size. ScreenConfiguration is the native
            // authority for the combined canvas and pointer coordinates.
            let selected = remoteDisplayRegions.prefix(
                configuration.displayCount)
            if let first = selected.first {
                let union = selected.dropFirst().reduce(first) {
                    $0.union($1)
                }
                videoBandRenderer.setScreenSize(
                    width: Int(union.width),
                    height: Int(union.height))
            }
            return
        }
        videoBandRenderer.setScreenSize(
            width: geometry.width,
            height: geometry.height)

        // A physical multi-display session can contain unequal monitors. Its
        // server layout remains authoritative for the aggregate canvas; the
        // primary stream's format only describes display zero.
        guard activeVideoDisplayCount == 1
                || configuration.displaySizingMode == .matchClient else {
            return
        }
        let aggregateWidth = geometry.width * activeVideoDisplayCount
        guard aggregateWidth <= Int(UInt16.max) else { return }
        guard aggregateWidth != framebufferWidth
                || geometry.height != framebufferHeight else { return }

        logger.info(
            "Applying HEVC media resize \(framebufferWidth)x\(framebufferHeight) "
                + "-> \(aggregateWidth)x\(geometry.height) "
                + "generation=\(geometry.mediaGeneration)")
        renderer?.handleDesktopResize(
            width: UInt16(aggregateWidth),
            height: UInt16(geometry.height))
        framebufferWidth = aggregateWidth
        framebufferHeight = geometry.height
    }

    private func handleError(_ error: VNCProtocolError) {
        logger.error("Protocol error: \(error.localizedDescription)")
        lastError = error
        diagnostics.lastError = error
    }

    private func handleDisconnected() {
        logger.info("Disconnected")
        cleanupTransport(clearCredentials: intentionallyDisconnected)

        // A manual configuration restart or media-bootstrap recovery already
        // owns the replacement attempt. Do not publish `.disconnected` (which
        // host apps interpret as an intentional close) or enqueue a duplicate
        // reconnect when the retired transport reports its shutdown.
        if reconnectTask != nil { return }

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
        resetAppleLoginPromptState()

        // These values describe the retired transport's negotiated media and
        // display topology. Keeping them across a configuration reconnect can
        // leave SwiftUI rendering the High Performance video path after the
        // replacement connection has negotiated Standard framebuffer mode.
        isHighPerformanceMode = false
        supportsRemoteClipboardRequest = false
        supportsRemoteSharedClipboardControl = false
        activeVideoDisplayCount = 1
        remoteDisplayRegions = []
        remoteDisplayRegionByID = [:]
        remoteDisplayRegionOrder = []
        remoteCursor = nil
        diagnostics.isHighPerformanceMode = false

        videoStreamManager?.stopStream()
        videoStreamManager = nil
        secondaryVideoStreamManager?.stopStream()
        secondaryVideoStreamManager = nil
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil
    }

    private func handleAppleRemoteSessionState(
        _ state: AppleRemoteSessionState
    ) {
        let promptEnabled =
            configuration.promptForLoginPasswordAtLoginWindow
        let passwordAvailable = canSendLoginPassword
        let shouldPrompt = appleLoginPromptTracker.update(
            isLoginActive: state.requiresLogin,
            promptEnabled: promptEnabled,
            canSendPassword: passwordAvailable)
        logger.debug(
            "Apple login state reached session: loginWindow="
                + "\(state.loginWindowActive) "
                + "lockScreen=\(state.loginWindowLockScreenActive) "
                + "enabled=\(promptEnabled) "
                + "canSendPassword=\(passwordAvailable) "
                + "willPrompt=\(shouldPrompt)")
        if !state.requiresLogin {
            // Ordinary user locks deliberately arrive as false here. Preserve
            // a prompt established from the full-frame visual fallback.
            if !appleLoginVisionDetected {
                loginPasswordPromptPending = false
            }
        } else if shouldPrompt {
            appleLoginVisionAttemptCount = Self.appleLoginVisionMaximumAttempts
            appleLoginVisionRetryTask?.cancel()
            appleLoginVisionRetryTask = nil
            loginPasswordPromptPending = true
            logger.info("Apple server entered Login Window state")
        }
    }

    private func resetAppleLoginPromptState() {
        appleLoginPromptTracker.reset()
        appleLoginVisionTask?.cancel()
        appleLoginVisionTask = nil
        appleLoginVisionRetryTask?.cancel()
        appleLoginVisionRetryTask = nil
        appleLoginVisionStabilityTask?.cancel()
        appleLoginVisionStabilityTask = nil
        appleLoginVisionLatestFrame = nil
        appleLoginVisionAttemptCount = 0
        appleLoginVisionLastAttemptNanos = 0
        appleLoginVisionGeneration &+= 1
        appleLoginVisionDetected = false
        appleLoginVisionPromptOffered = false
        appleLoginVisionHighPerformanceGeneration = nil
        appleServerProtocolObserved = false
        cancelScheduledLoginPasswordSend()
        loginPasswordSendGate.reset()
        loginPasswordPromptPending = false
    }

    private static let appleLoginVisionMaximumAttempts = 3
    private static let appleLoginVisionMinimumIntervalNanos: UInt64 = 700_000_000
    private static let appleLoginVisionHighPerformanceStabilityDelay =
        Duration.milliseconds(350)
    /// Transport settlement plus a final-size frame gates the send. The
    /// ordered center click establishes Login Window focus without a fixed
    /// multi-second delay.
    private static let loginPasswordPostResizeInputReadinessDelay =
        Duration.zero

    private func noteHighPerformanceFrameForPendingLoginPassword(
        _ pixelBuffer: CVPixelBuffer,
        mediaGeneration: UInt64
    ) {
        guard isHighPerformanceMode,
              configuration.displaySizingMode == .matchClient,
              isEligibleHighPerformanceLoginVisionFrame(pixelBuffer),
              let token = loginPasswordSendGate.noteEligibleFrame(
                mediaGeneration: mediaGeneration) else { return }
        scheduleLoginPasswordSendAfterStability(token: token)
    }

    private func noteRemoteDisplayResizeSettled(_ settled: Bool) {
        loginPasswordSendGate.transportSettled(settled)
        let pending = loginPasswordSendGate.isPending
        logger.debug(
            "Match Client resize transport settled=\(settled) "
                + "passwordPending=\(pending)")
        if !settled {
            cancelScheduledLoginPasswordSend()
        }
    }

    private func scheduleLoginPasswordSendAfterStability(
        token: LoginPasswordSendStabilityGate.Token
    ) {
        if loginPasswordSendScheduledToken == token,
           loginPasswordSendStabilityTask != nil {
            return
        }
        cancelScheduledLoginPasswordSend()
        let displayRevision = token.displayRevision
        let mediaGeneration = token.mediaGeneration
        logger.debug(
            "Final Match Client frame eligible for password send; "
                + "waiting for remote input readiness: "
                + "displayRevision=\(displayRevision) "
                + "mediaGeneration=\(mediaGeneration)")
        loginPasswordSendScheduledToken = token
        loginPasswordSendStabilityTask = Task { [weak self] in
            try? await Task.sleep(
                for: Self.loginPasswordPostResizeInputReadinessDelay)
            guard let self, !Task.isCancelled else { return }
            self.loginPasswordSendStabilityTask = nil
            self.loginPasswordSendScheduledToken = nil
            guard self.isHighPerformanceMode,
                  self.configuration.displaySizingMode == .matchClient,
                  self.canSendLoginPassword,
                  self.loginPasswordSendGate.consume(token),
                  let password = self.activeCredentials?.password else { return }
            self.sendLoginPasswordNow(password)
        }
    }

    private func cancelScheduledLoginPasswordSend() {
        loginPasswordSendStabilityTask?.cancel()
        loginPasswordSendStabilityTask = nil
        loginPasswordSendScheduledToken = nil
    }

    /// Inspect only a few initial, already-composited full frames. The cheap
    /// guards run on the main actor; Vision itself runs at utility priority.
    private func considerAppleLoginVisionFrame(
        _ frame: AppleLoginVisionFrame,
        source: String,
        highPerformanceGeneration: UInt64? = nil
    ) {
        guard configuration.promptForLoginPasswordAtLoginWindow,
              canSendLoginPassword,
              appleServerProtocolObserved else { return }

        if let highPerformanceGeneration {
            let previousGeneration = appleLoginVisionHighPerformanceGeneration
            if previousGeneration != highPerformanceGeneration {
                appleLoginVisionHighPerformanceGeneration =
                    highPerformanceGeneration
                if previousGeneration != nil {
                    restartAppleLoginVisionForDisplayTransition(
                        reason: "High Performance media generation changed")
                }
            }

            guard case .pixelBuffer(let pixelBuffer) = frame,
                  isEligibleHighPerformanceLoginVisionFrame(pixelBuffer)
            else { return }

            appleLoginVisionLatestFrame = (
                frame, source, highPerformanceGeneration)
            scheduleAppleLoginVisionAfterHighPerformanceStability(
                mediaGeneration: highPerformanceGeneration)
            return
        }

        appleLoginVisionLatestFrame = (frame, source, nil)
        startAppleLoginVision(frame, source: source)
    }

    /// A Match Client resize can publish the old complete surface while a new
    /// virtual display is being negotiated. Never spend OCR work on a surface
    /// whose dimensions differ from the newest requested display.
    func isEligibleHighPerformanceLoginVisionFrame(
        _ pixelBuffer: CVPixelBuffer
    ) -> Bool {
        guard configuration.displaySizingMode == .matchClient,
              let expected = lastRequestedClientDisplaySize
                ?? preparedClientDisplaySize else { return true }
        return CVPixelBufferGetWidth(pixelBuffer) == Int(expected.pixelWidth)
            && CVPixelBufferGetHeight(pixelBuffer) == Int(expected.pixelHeight)
    }

    /// The first committed frame of a replacement generation is complete, but
    /// Match Client may immediately supersede that generation during window or
    /// display transitions. A short generation-scoped delay keeps Vision off
    /// those transient surfaces without requiring a second video frame from a
    /// static lock screen.
    private func scheduleAppleLoginVisionAfterHighPerformanceStability(
        mediaGeneration: UInt64
    ) {
        guard appleLoginVisionStabilityTask == nil,
              appleLoginVisionTask == nil,
              appleLoginVisionRetryTask == nil,
              appleLoginVisionAttemptCount
                < Self.appleLoginVisionMaximumAttempts else { return }
        let generation = appleLoginVisionGeneration
        appleLoginVisionStabilityTask = Task { [weak self] in
            try? await Task.sleep(
                for: Self.appleLoginVisionHighPerformanceStabilityDelay)
            guard let self, !Task.isCancelled,
                  generation == self.appleLoginVisionGeneration,
                  mediaGeneration
                    == self.appleLoginVisionHighPerformanceGeneration,
                  let latest = self.appleLoginVisionLatestFrame,
                  latest.highPerformanceGeneration == mediaGeneration else {
                return
            }
            self.appleLoginVisionStabilityTask = nil
            self.startAppleLoginVision(latest.frame, source: latest.source)
        }
    }

    private func restartAppleLoginVisionForDisplayTransition(reason: String) {
        guard !appleLoginPromptTracker.isLoginActive,
              !appleLoginVisionDetected,
              !appleLoginVisionPromptOffered else { return }
        appleLoginVisionTask?.cancel()
        appleLoginVisionTask = nil
        appleLoginVisionRetryTask?.cancel()
        appleLoginVisionRetryTask = nil
        appleLoginVisionStabilityTask?.cancel()
        appleLoginVisionStabilityTask = nil
        appleLoginVisionLatestFrame = nil
        appleLoginVisionAttemptCount = 0
        appleLoginVisionLastAttemptNanos = 0
        appleLoginVisionGeneration &+= 1
        logger.debug("Restarting Apple login Vision after \(reason)")
    }

    private func startAppleLoginVision(
        _ frame: AppleLoginVisionFrame,
        source: String
    ) {

        guard !appleLoginPromptTracker.isLoginActive,
              !appleLoginVisionDetected,
              !appleLoginVisionPromptOffered,
              appleLoginVisionAttemptCount
                < Self.appleLoginVisionMaximumAttempts,
              appleLoginVisionTask == nil else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        guard appleLoginVisionLastAttemptNanos == 0
                || now &- appleLoginVisionLastAttemptNanos
                    >= Self.appleLoginVisionMinimumIntervalNanos else {
            return
        }

        appleLoginVisionAttemptCount += 1
        appleLoginVisionRetryTask?.cancel()
        appleLoginVisionRetryTask = nil
        appleLoginVisionLastAttemptNanos = now
        let attempt = appleLoginVisionAttemptCount
        let generation = appleLoginVisionGeneration
        logger.debug(
            "Apple login Vision attempt \(attempt)/"
                + "\(Self.appleLoginVisionMaximumAttempts) source=\(source)")

        appleLoginVisionTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                let started = DispatchTime.now().uptimeNanoseconds
                do {
                    let analysis: AppleLoginTextAnalysis
                    switch frame {
                    case .image(let image):
                        analysis = try AppleLoginScreenDetector.recognize(
                            cgImage: image)
                    case .pixelBuffer(let pixelBuffer):
                        analysis = try AppleLoginScreenDetector.recognize(
                            pixelBuffer: pixelBuffer)
                    }
                    return AppleLoginVisionOutcome(
                        analysis: analysis,
                        errorDescription: nil,
                        elapsedMilliseconds:
                            (DispatchTime.now().uptimeNanoseconds &- started)
                                / 1_000_000)
                } catch {
                    return AppleLoginVisionOutcome(
                        analysis: nil,
                        errorDescription: error.localizedDescription,
                        elapsedMilliseconds:
                            (DispatchTime.now().uptimeNanoseconds &- started)
                                / 1_000_000)
                }
            }.value

            guard let self, !Task.isCancelled,
                  generation == self.appleLoginVisionGeneration else { return }
            self.appleLoginVisionTask = nil

            guard let analysis = outcome.analysis else {
                let errorText = outcome.errorDescription ?? "unknown error"
                self.logger.warning(
                    "Apple login Vision attempt \(attempt) failed after "
                        + "\(outcome.elapsedMilliseconds)ms: "
                        + errorText)
                self.scheduleAppleLoginVisionRetry(generation: generation)
                return
            }
            self.logger.debug(
                "Apple login Vision result attempt=\(attempt) "
                    + "detected=\(analysis.isLoginScreen) "
                    + "lines=\(analysis.recognizedLineCount) "
                    + "evidence=\(analysis.evidence) "
                    + "elapsed=\(outcome.elapsedMilliseconds)ms")

            if analysis.isLoginScreen {
                self.appleLoginVisionDetected = true
                self.appleLoginVisionPromptOffered = true
                self.loginPasswordPromptPending = true
                self.logger.info(
                    "Apple lock screen detected from full-frame Vision; "
                        + "password confirmation prompt dispatched")
            } else if attempt == Self.appleLoginVisionMaximumAttempts {
                self.logger.debug(
                    "Apple login Vision exhausted initial full-frame attempts "
                        + "without a high-confidence lock-screen match")
            } else {
                self.scheduleAppleLoginVisionRetry(generation: generation)
            }
        }
    }

    private func scheduleAppleLoginVisionRetry(generation: UInt64) {
        guard appleLoginVisionAttemptCount < Self.appleLoginVisionMaximumAttempts,
              appleLoginVisionRetryTask == nil else { return }
        appleLoginVisionRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled,
                  generation == self.appleLoginVisionGeneration,
                  let latest = self.appleLoginVisionLatestFrame else { return }
            self.appleLoginVisionRetryTask = nil
            self.startAppleLoginVision(
                latest.frame, source: latest.source + " retry")
        }
    }

    /// Escalation of last resort for a video bootstrap that never produced a
    /// decoded frame: some servers never re-send an IRAP for FIR, so a
    /// startup burst damaged by packet loss leaves the stream permanently
    /// dead. Only a fresh connection renegotiates media. (Deliberately no
    /// capacity reduction on retry: the server ignores our advertised rate
    /// during bootstrap, and a lowered controller origin destabilizes large
    /// framebuffers.)
    private func noteMediaBootstrapHealthy() {
        // Bootstrap health currently needs no state; kept as the single hook
        // point for future per-connection learning.
    }

    private func forceMediaBootstrapReconnect(
        reason: String,
        retryTilesPerFrame: UInt64? = nil
    ) {
        guard connectionState.isConnected,
              reconnectTask == nil,
              activeCredentials != nil,
              configuration.reconnectionPolicy.isEnabled,
              configuration.reconnectionPolicy.maximumAttempts > 0 else {
            logger.error(
                "Video bootstrap failed (\(reason)) but automatic reconnection "
                    + "is unavailable; leaving the session as-is")
            return
        }
        if let retryTilesPerFrame {
            appleMediaTilesPerFrameOverride = retryTilesPerFrame
            logger.warning(
                "Retrying Apple media with tilesPerFrame=\(retryTilesPerFrame)")
        }
        logger.error("Video bootstrap failed (\(reason)); reconnecting")
        let transport = transportSession
        Task { await transport?.disconnect() }
        scheduleReconnect(immediate: true)
    }

    private func establishTransport(credentials: VNCCredentials) async throws {
        // A custom transport is built fresh here for every attempt: the
        // reconnect loop lands on this path per retry, and the provider
        // contract requires a usable tunnel each time.
        let customConnection: (any RFBConnection)?
        if let provider = configuration.transportProvider {
            customConnection = try await provider(credentials.host, credentials.port)
        } else {
            customConnection = nil
        }
        let transport = TransportSession(
            host: credentials.host,
            port: credentials.port,
            password: credentials.password,
            username: credentials.username,
            preferredPixelFormat: configuration.effectivePixelFormat,
            preferredEncodings: configuration.effectiveEncodings,
            preferFullQualityVideo: configuration.videoQualityMode == .fullQuality,
            targetFrameRate: configuration.targetFrameRate,
            displayCount: configuration.displayCount,
            requestsVirtualDisplays:
                configuration.displaySizingMode == .matchClient,
            appleMediaTilesPerFrameOverride:
                appleMediaTilesPerFrameOverride,
            connection: customConnection,
            securityPolicy: configuration.securityPolicy,
            certificateValidationHandler: configuration.certificateValidationHandler)
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

    private func scheduleReconnect(
        immediate: Bool = false,
        minimumAttempts: Int = 0
    ) {
        guard reconnectTask == nil, let credentials = activeCredentials else { return }
        let policy = configuration.reconnectionPolicy
        let maximumAttempts = max(policy.maximumAttempts, minimumAttempts)
        guard maximumAttempts > 0 else {
            connectionState = .failed(String(
                localized: "Reconnection is disabled for this session.",
                bundle: .module))
            return
        }

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }

            for attempt in 1...maximumAttempts {
                guard !Task.isCancelled, !self.intentionallyDisconnected else { return }
                let delay = immediate && attempt == 1 ? 0 : policy.delay(forAttempt: attempt)
                self.connectionState = .reconnecting(attempt: attempt, delay: delay)
                self.logger.warning(
                    "Connection lost; retry \(attempt)/\(maximumAttempts) in "
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
                String(
                    localized: "Couldn’t reconnect after \(maximumAttempts) attempts. Check the network or server, then try again.",
                    bundle: .module))
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
        startInputPumpIfNeeded(transport: transport)
    }

    private func startInputPumpIfNeeded(transport: TransportSession) {
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
                case .pause(let nanoseconds):
                    try? await Task.sleep(
                        for: .nanoseconds(Int64(clamping: nanoseconds)))
                case .scroll(let event):
                    try? await transport.sendScrollEvent(event)
                case .gesture(let event):
                    try? await transport.sendGestureEvent(event)
                case .clipboard(let text):
                    do {
                        try await transport.sendClipboardText(text)
                    } catch {
                        self.logger.warning(
                            "Failed to send clipboard: "
                                + error.localizedDescription)
                    }
                case .clipboardRequest:
                    do {
                        try await transport.requestRemoteClipboard()
                    } catch {
                        self.logger.warning(
                            "Failed to request remote clipboard: "
                                + error.localizedDescription)
                    }
                case .sharedClipboard(let enabled):
                    do {
                        try await transport.setSharedClipboardEnabled(enabled)
                    } catch {
                        self.logger.warning(
                            "Failed to update shared clipboard state: "
                                + error.localizedDescription)
                    }
                }
            }
            if self.inputGeneration == generation {
                self.inputTask = nil
                // An event can be enqueued after the loop observes an empty
                // queue but before this task clears itself. Close that lost-
                // wakeup window so clipboard control messages cannot remain
                // stranded until the next pointer or keyboard event.
                if !self.inputQueue.isEmpty,
                   self.transportSession === transport,
                   self.connectionState.isConnected {
                    self.startInputPumpIfNeeded(transport: transport)
                }
            }
        }
    }

    private func scheduleTrailingSnapshot(
        interval: UInt64,
        minimumDelay: UInt64 = 0,
        resetsDCTRefinement: Bool = false
    ) {
        guard trailingSnapshotTask == nil else { return }
        let cadenceDelay = interval &- min(
            interval,
            DispatchTime.now().uptimeNanoseconds &- lastImagePublishNanos)
        let delay = max(cadenceDelay, minimumDelay)
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
                self.considerAppleLoginVisionFrame(
                    .image(image),
                    source: "Standard trailing snapshot")
                if resetsDCTRefinement {
                    self.dctRefinementTracker.reset()
                }
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
        case .pause, .scroll, .gesture, .clipboard, .clipboardRequest,
             .sharedClipboard:
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
                noteMediaInterruptionBoundary(requestRefresh: false)
            }
        }
        foregroundLifecycleTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.willEnterForegroundNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                guard mediaWasBackgrounded else { continue }
                mediaWasBackgrounded = false
                noteMediaInterruptionBoundary(requestRefresh: true)
            }
        }
    }

    private func noteMediaInterruptionBoundary(requestRefresh: Bool) {
        guard connectionState.isConnected,
              let transport = transportSession else { return }

        if isHighPerformanceMode {
            videoStreamManager?.noteMediaInterruption()
            secondaryVideoStreamManager?.noteMediaInterruption()
            remoteAudioPlayer?.reset()
        }

        Task { [transport] in
            if self.isHighPerformanceMode {
                await transport.noteAppleMediaInterruption()
            }
            guard requestRefresh else { return }

            // A suspended connection can remain nominally alive while its
            // receive/media pipeline has stopped making progress. Do not wait
            // for a new RTP packet to initiate recovery: a static desktop may
            // not produce one. Explicitly solicit fresh state on foreground.
            if self.isHighPerformanceMode {
                await transport.requestVideoKeyframe()
            }
            try? await transport.requestFramebufferUpdate(incremental: false)
        }
    }

    #endif

    private var isTraceEnabled: Bool {
        configuration.enableProtocolTrace
    }

    private func startVideoStream(offer: AppleMediaStreamOffer) async {
        let manager = videoStreamManager ?? VideoStreamManager()
        videoStreamManager = manager
        videoBandRenderer.reset()
        secondaryVideoBandRenderer.reset()

        if configuration.effectiveRemoteAudioEnabled {
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

        let fallbackWidth = framebufferWidth > 0 ? framebufferWidth : Int(offer.width)
        let fallbackHeight = framebufferHeight > 0 ? framebufferHeight : Int(offer.height)
        func displaySize(at index: Int) -> (width: Int, height: Int) {
            if index == 0,
               activeVideoDisplayCount == 1,
               configuration.displaySizingMode != .matchClient,
               configuration.displayCount > 1,
               remoteDisplayRegions.count >= configuration.displayCount {
                let selected = remoteDisplayRegions.prefix(
                    configuration.displayCount)
                if let first = selected.first {
                    let union = selected.dropFirst().reduce(first) {
                        $0.union($1)
                    }
                    return (Int(union.width), Int(union.height))
                }
            }
            if remoteDisplayRegions.indices.contains(index) {
                let region = remoteDisplayRegions[index]
                return (Int(region.width), Int(region.height))
            }
            if configuration.displaySizingMode == .matchClient,
               let preparedClientDisplaySize {
                return (
                    Int(preparedClientDisplaySize.pixelWidth),
                    Int(preparedClientDisplaySize.pixelHeight))
            }
            return (fallbackWidth, fallbackHeight)
        }
        let primarySize = displaySize(at: 0)
        let width = primarySize.width
        let height = primarySize.height
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

        let secondaryManager: VideoStreamManager?
        let secondaryCoalescer: BandFrameCoalescer?
        let secondaryDecodedBands: DecodedBandTracker?
        if activeVideoDisplayCount > 1 {
            let secondManager = secondaryVideoStreamManager ?? VideoStreamManager()
            secondaryVideoStreamManager = secondManager
            let secondSize = displaySize(at: 1)
            secondaryVideoBandRenderer.setScreenSize(
                width: secondSize.width,
                height: secondSize.height)
            secondaryVideoBandRenderer.configureExpectedBandCount(initialTileCount)
            let secondCoalescer = BandFrameCoalescer(
                renderer: secondaryVideoBandRenderer,
                expectedSourceCount: initialTileCount)
            let secondDecodedBands = DecodedBandTracker()
            secondManager.onFrameGeometryChange = { [weak self] geometry in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.secondaryVideoBandRenderer.setScreenSize(
                        width: geometry.width,
                        height: geometry.height)
                }
            }
            secondManager.startStream(
                streamID: offer.streamID,
                width: secondSize.width,
                height: secondSize.height,
                usesDecodingOrderNumbers: initialTileCount > 1,
                numberOfTiles: initialTileCount
            ) { pixelBuffer, ssrc in
                secondDecodedBands.record(ssrc)
                secondCoalescer.submit(ssrc: ssrc, pixelBuffer: pixelBuffer)
            }
            secondaryManager = secondManager
            secondaryCoalescer = secondCoalescer
            secondaryDecodedBands = secondDecodedBands
        } else {
            secondaryVideoStreamManager?.stopStream()
            secondaryVideoStreamManager = nil
            secondaryManager = nil
            secondaryCoalescer = nil
            secondaryDecodedBands = nil
        }

        let streamGeneration = manager.decodeProgress.streamGeneration
        let recoveryCoordinator = MediaRecoveryCoordinator()

        // Startup liveness watchdog. Recovery stays in the negotiated media
        // protocol first (FIR for a fresh intra picture); if the bootstrap is
        // still dead after the retries — some servers never answer FIR with
        // an IRAP, so a damaged startup burst is unrecoverable in-session —
        // escalate to a reconnect with a reduced initial capacity.
        if let transport = transportSession {
            let watchdogManager = manager
            let log = logger
            Task { [weak self, weak transport, weak watchdogManager, recoveryCoordinator] in
                var firAttempts = 0
                var lastStatus = (decoded: 0, sources: 0)
                for tick in 1...14 {
                    try? await Task.sleep(for: .seconds(1))
                    guard let transport, let m = watchdogManager, m.isStreamActive else { return }
                    // This watchdog owns display zero's decoder. The transport
                    // source count includes every negotiated display, so use
                    // this display's negotiated band count here.
                    let sources = initialTileCount
                    let decoded = decodedBands.count
                    lastStatus = (decoded, sources)
                    if sources > 0 && decoded >= sources {
                        if firAttempts > 0 {
                            log.info("Dead-band watchdog: recovered, \(decoded)/\(sources) bands decoding")
                        }
                        self?.noteMediaBootstrapHealthy()
                        return
                    }
                    // Some servers accept tilesPerFrame=1 in message 2 but
                    // never instantiate a video RTP source for it. This is a
                    // profile rejection, not packet loss, so FIR cannot help.
                    // Retry quickly with the native compound capability.
                    if sources == 1, decoded == 0, tick >= 3,
                       await transport.videoSourceCount == 0 {
                        self?.forceMediaBootstrapReconnect(
                            reason: "one-picture profile produced no video source",
                            retryTilesPerFrame: 4)
                        return
                    }
                    guard firAttempts < 3,
                          await transport.isReadyForVideoKeyframeRecovery() || tick >= 6,
                          await recoveryCoordinator.begin() else {
                        continue
                    }
                    firAttempts += 1
                    log.warning("Startup media watchdog: \(decoded)/\(sources) sources decoding "
                        + "(attempt \(firAttempts)); requesting native FIR after rate settled")
                    await transport.requestVideoKeyframe()
                    await recoveryCoordinator.finish()
                }
                guard let self,
                      let m = watchdogManager, m.isStreamActive,
                      m.decodeProgress.streamGeneration == streamGeneration else { return }
                self.forceMediaBootstrapReconnect(
                    reason: "\(lastStatus.decoded)/\(lastStatus.sources) bands decoding "
                        + "after \(firAttempts) FIR attempts",
                    retryTilesPerFrame:
                        lastStatus.sources == 1 && lastStatus.decoded == 0 ? 4 : nil)
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
        // The media fail-safe escalates to PSFB FIR and resets expected
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
                Task { [transport] in
                    // By the time the demuxer sees a sequence gap, transport
                    // retransmission has already failed. The server answers a
                    // keyframe request with a recovery IDR_N_LP + parameter
                    // sets (verified live 2026-07-12), which the surviving
                    // decoder session picks up directly — no rebuild needed.
                    // The transport rate-limits repeated requests.
                    await transport.requestVideoKeyframe(ssrc: ssrc)
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
                // The rebuild is paced by VideoStreamManager's cooldown: a
                // session rebuilt mid-reference-loss fails every dependent
                // picture until intra refresh completes, so hammering rebuilds
                // per failure churned 30+ VT sessions a second. Retry on a
                // timer instead until either the rebuild lands or the latch
                // clears with the stream still healthy.
                Task { [weak transport, weak recoveryManager] in
                    for attempt in 1...8 {
                        guard let transport,
                              let recoveryManager,
                              recoveryManager.isStreamActive,
                              recoveryManager.hasLatchedDecoderFailure else { return }
                        let rebuilt = await withCheckedContinuation { continuation in
                            recoveryQueue.async {
                                continuation.resume(
                                    returning: recoveryManager.recoverDecoderInSession())
                            }
                        }
                        if rebuilt {
                            await transport.requestVideoKeyframe(ssrc: failure.ssrc)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(150 * attempt))
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
                if let stats = RenderCommitStats.shared {
                    for packet in packets {
                        stats.noteVideoPacket(bytes: packet.count)
                        let result = sinkManager.feedRTPData(packet)
                        stats.noteSubmittedAccessUnits(result.decodedNALUnitCount)
                    }
                } else {
                    for packet in packets {
                        sinkManager.feedRTPData(packet)
                    }
                }
            }
            let secondaryVideoPacketCoalescer = secondaryManager.map { manager in
                OrderedMediaPacketCoalescer(queue: queue) { packets in
                    for packet in packets {
                        manager.feedRTPData(packet)
                    }
                }
            }
            secondaryManager?.onLossDetected = { [weak transport] ssrc in
                guard let transport else { return }
                Task { await transport.requestVideoKeyframe(ssrc: ssrc) }
            }
            secondaryManager?.onDecoderFailure = { [weak transport, weak secondaryManager] failure in
                guard let transport, let secondaryManager else { return }
                queue.async {
                    _ = secondaryManager.recoverDecoderInSession()
                    Task { await transport.requestVideoKeyframe(ssrc: failure.ssrc) }
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
                    if let secondaryManager,
                       let secondaryCoalescer,
                       let secondaryDecodedBands {
                        secondaryManager.prepareForStreamReconfiguration(
                            mediaGeneration: generation,
                            numberOfTiles: numberOfTiles)
                        secondaryDecodedBands.reset()
                        secondaryCoalescer.beginStreamGeneration(
                            generation,
                            expectedSourceCount: numberOfTiles)
                    }

                    // The connection-level startup watchdog cannot validate a
                    // replacement generation: its SSRC set belongs to retired
                    // media. Require every new tile to decode before declaring
                    // this generation live, otherwise the atomic renderer can
                    // retain the old whole-screen frame forever.
                    Task { [weak self, weak transport, weak sinkManager, recoveryCoordinator] in
                        for attempt in 1...8 {
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
                                await MainActor.run { [weak self] in
                                    self?.noteMediaBootstrapHealthy()
                                }
                                return
                            }
                            if numberOfTiles == 1, decoded == 0, attempt >= 3,
                               await transport.videoSourceCount == 0 {
                                await MainActor.run { [weak self] in
                                    self?.forceMediaBootstrapReconnect(
                                        reason: "one-picture reconfiguration produced no video source",
                                        retryTilesPerFrame: 4)
                                }
                                return
                            }
                            let ready = await transport.isReadyForVideoKeyframeRecovery()
                            guard (ready || attempt >= 4),
                                  await recoveryCoordinator.begin() else { continue }
                            generationLog.warning(
                                "Media generation \(generation) has \(decoded)/"
                                    + "\(numberOfTiles) decoded tiles; requesting FIR "
                                    + "attempt \(attempt)")
                            await transport.requestVideoKeyframe()
                            await recoveryCoordinator.finish()
                        }
                        // Still dead after the FIR ladder: this generation's
                        // bootstrap was lost and the server will not replace
                        // it in-session. Reconnect with a gentler burst.
                        guard let manager = sinkManager,
                              manager.isStreamActive,
                              manager.currentMediaGeneration == generation else { return }
                        let decoded = decodedBands.count
                        guard decoded < numberOfTiles else { return }
                        await MainActor.run { [weak self] in
                            self?.forceMediaBootstrapReconnect(
                                reason: "generation \(generation): \(decoded)/"
                                    + "\(numberOfTiles) tiles decoding",
                                retryTilesPerFrame:
                                    numberOfTiles == 1 && decoded == 0 ? 4 : nil)
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
            await transport.setAppleRemoteDisplayResizeSettledSink {
                [weak self] settled in
                Task { @MainActor [weak self] in
                    self?.noteRemoteDisplayResizeSettled(settled)
                }
            }
            await transport.setAppleMediaRoutedRTPSink { packet, displayIndex in
                if AppleRemoteAudioPlayer.canHandleRTPPacket(packet) {
                    sinkAudioPlayer?.enqueueRTPPacket(packet)
                } else if displayIndex == 1,
                          let secondaryVideoPacketCoalescer {
                    secondaryVideoPacketCoalescer.enqueue(packet)
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
            return .connectionFailed(String(localized: "Connection closed by server", bundle: .module))
        case .timeout:
            return .connectionFailed(String(localized: "Connection timed out", bundle: .module))
        case .ioError(let detail):
            return .connectionFailed(detail)
        case .unsupportedVersion:
            return .unsupportedFeature(String(localized: "Server protocol version not supported", bundle: .module))
        case .unsupportedEncoding(let id):
            return .unsupportedFeature(String(localized: "Encoding \(id) not supported", bundle: .module))
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
/// handed to the renderer. Capture is strictly opt-in through
/// `ROOTSHELL_VNC_FRAME_OUT_DIR=<dir>`; ordinary Debug and Release sessions do
/// not write screen contents to disk.
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
        guard let root = configuredRoot(environment: environment) else { return nil }

        let sessionDirectory = root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            VNCLogger(category: "FrameCapture").warning(
                "Could not create decoded-frame capture directory: \(error.localizedDescription)")
            return nil
        }
        VNCLogger(category: "FrameCapture").info(
            "Capturing decoded frames in \(sessionDirectory.path)")
        return DiagnosticFrameDumper(dir: sessionDirectory.path)
    }

    static func configuredRoot(environment: [String: String]) -> URL? {
        #if DEBUG
        guard let explicit = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_FRAME_OUT_DIR",
            environment: environment) else { return nil }
        return URL(fileURLWithPath: explicit, isDirectory: true)
        #else
        nil
        #endif
    }

    private init(dir: String) {
        self.dir = dir
    }

    func maybeDump(_ pixelBuffer: CVPixelBuffer, ssrc: UInt32) {
        #if DEBUG
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
            guard FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]) else { return }
            let ci = CIImage(cvPixelBuffer: box.buffer)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent),
                  let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
        #endif
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
/// IDR on the base SSRC, so the value is advisory: transport always routes FIR
/// to the base video channel while retaining this value for diagnostics.
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

/// Env-gated (`ROOTSHELL_VNC_RENDER_STATS=1`) per-second render-path telemetry.
/// Prints decoded-frame arrivals, commit counts by path, main-thread hop
/// latency, and `setBands` duration — the GUI-only stretch of the pipeline
/// that headless probes cannot observe.
final class RenderCommitStats: @unchecked Sendable {
    static let shared: RenderCommitStats? =
        VNCDiagnostics.isEnabled("ROOTSHELL_VNC_RENDER_STATS")
            ? RenderCommitStats()
            : nil

    private let lock = NSLock()
    private var framesIn = 0
    private var immediateCommits = 0
    private var fallbackCommits = 0
    private var committedBands = 0
    private var hopLatenciesNanos: [UInt64] = []
    private var setBandsDurationsNanos: [UInt64] = []
    private var videoPackets = 0
    private var videoBytes = 0
    private var submittedAccessUnits = 0
    private var tick = 0
    private let timer: DispatchSourceTimer

    private init() {
        timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.rootshell.vnc.render-stats"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
    }

    func noteFrameIn() {
        lock.lock(); framesIn += 1; lock.unlock()
    }

    func noteVideoPacket(bytes: Int) {
        lock.lock(); videoPackets += 1; videoBytes += bytes; lock.unlock()
    }

    func noteSubmittedAccessUnits(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); submittedAccessUnits += count; lock.unlock()
    }

    func noteCommit(
        immediate: Bool,
        bandCount: Int,
        hopLatencyNanos: UInt64,
        setBandsNanos: UInt64
    ) {
        lock.lock()
        if immediate { immediateCommits += 1 } else { fallbackCommits += 1 }
        committedBands += bandCount
        if hopLatenciesNanos.count < 4096 { hopLatenciesNanos.append(hopLatencyNanos) }
        if setBandsDurationsNanos.count < 4096 { setBandsDurationsNanos.append(setBandsNanos) }
        lock.unlock()
    }

    private func emit() {
        lock.lock()
        tick += 1
        let t = tick
        let frames = framesIn
        let immediate = immediateCommits
        let fallback = fallbackCommits
        let bands = committedBands
        let hops = hopLatenciesNanos.sorted()
        let durations = setBandsDurationsNanos.sorted()
        let packets = videoPackets
        let kilobytes = videoBytes / 1024
        let submitted = submittedAccessUnits
        framesIn = 0
        immediateCommits = 0
        fallbackCommits = 0
        committedBands = 0
        videoPackets = 0
        videoBytes = 0
        submittedAccessUnits = 0
        hopLatenciesNanos.removeAll(keepingCapacity: true)
        setBandsDurationsNanos.removeAll(keepingCapacity: true)
        lock.unlock()

        func ms(_ sorted: [UInt64], _ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
            return Double(sorted[idx]) / 1_000_000
        }
        VNCLogger(category: "RenderStats").debug(String(
            format: "RSTAT t=%03d pkts=%d kB=%d sub=%d in=%d commits=%d (imm=%d fb=%d) bands=%d "
                + "hop p50=%.1fms p95=%.1fms max=%.1fms "
                + "setBands p50=%.2fms max=%.2fms",
            t, packets, kilobytes, submitted,
            frames, immediate + fallback, immediate, fallback, bands,
            ms(hops, 0.5), ms(hops, 0.95), ms(hops, 1.0),
            ms(durations, 0.5), ms(durations, 1.0)))
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
        RenderCommitStats.shared?.noteFrameIn()
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
        let scheduledNanos = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [self] in
            let hopLatency = DispatchTime.now().uptimeNanoseconds &- scheduledNanos
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
                let started = DispatchTime.now().uptimeNanoseconds
                MainActor.assumeIsolated {
                    renderer.setBands(frames)
                }
                RenderCommitStats.shared?.noteCommit(
                    immediate: true,
                    bandCount: frames.count,
                    hopLatencyNanos: hopLatency,
                    setBandsNanos: DispatchTime.now().uptimeNanoseconds &- started)
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
        let deadlineNanos = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(8_000_000)
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            let hopLatency = now > deadlineNanos ? now &- deadlineNanos : 0
            lock.lock()
            guard generation == streamGeneration else {
                lock.unlock()
                return
            }
            let frames = accumulator.takeLatestPendingSnapshot()
            fallbackHopScheduled = false
            lock.unlock()
            guard let frames, !frames.isEmpty else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            MainActor.assumeIsolated {
                renderer.setBands(frames)
            }
            RenderCommitStats.shared?.noteCommit(
                immediate: false,
                bandCount: frames.count,
                hopLatencyNanos: hopLatency,
                setBandsNanos: DispatchTime.now().uptimeNanoseconds &- started)
        }
    }
}
