import SwiftUI
import CoreImage
import CoreVideo
import RFBProtocol
import RFBTransport
import RFBRendering

/// Main VNC session observable object for SwiftUI integration.
///
/// `VNCSession` is the primary entry point for consumers of the RootShellVNC
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

    // MARK: - Configuration

    /// The configuration for this session.
    public var configuration: VNCConfiguration

    // MARK: - Internal

    private var transportSession: TransportSession?
    private var framebuffer: Framebuffer?
    private var renderer: FramebufferRenderer?
    private var videoStreamManager: VideoStreamManager?
    private var eventTask: Task<Void, Never>?
    private var frameRequestTask: Task<Void, Never>?
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

    // MARK: - Init

    /// Create a new VNC session with the given configuration.
    ///
    /// - Parameter configuration: Session configuration. Defaults to sensible values.
    public init(configuration: VNCConfiguration = VNCConfiguration()) {
        self.configuration = configuration
    }

    deinit {
        // Deinit for @MainActor class — tasks are cancelled by their own cancellation.
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

        connectionState = .connecting
        lastError = nil
        diagnostics.reset()
        diagnostics.connectionStartTime = Date()

        let traceEnabled: Bool
        #if DEBUG
        traceEnabled = true
        #else
        traceEnabled = configuration.enableProtocolTrace
        #endif
        if traceEnabled {
            diagnostics.protocolTrace = ProtocolTrace()
        }

        let transport = TransportSession(
            host: credentials.host,
            port: credentials.port,
            password: credentials.password,
            username: credentials.username,
            preferredPixelFormat: configuration.preferredPixelFormat ?? .bgra8888,
            preferredEncodings: configuration.effectiveEncodings,
            preferFullQualityVideo: configuration.videoQualityMode == .fullQuality
        )
        self.transportSession = transport

        // Start processing events before connecting so we don't miss any
        startEventProcessing(transport: transport)

        do {
            try await transport.connect()
            logger.info("Connection initiated to \(credentials.host):\(credentials.port)")
        } catch let error as VNCProtocolError {
            connectionState = .failed(error.localizedDescription)
            lastError = error
            diagnostics.lastError = error
            cleanupTransport()
            throw mapProtocolError(error)
        } catch {
            let message = error.localizedDescription
            connectionState = .failed(message)
            cleanupTransport()
            throw VNCError.connectionFailed(message)
        }
    }

    /// Disconnect from the current VNC server.
    ///
    /// Cancels all active tasks, closes the transport, and resets the session
    /// state. Safe to call even when not connected.
    public func disconnect() {
        guard connectionState == .connecting || connectionState == .connected else {
            return
        }

        connectionState = .disconnecting
        logger.info("Disconnecting")

        // Cancel background tasks
        eventTask?.cancel()
        eventTask = nil

        // Close the transport
        if let transport = transportSession {
            Task {
                await transport.disconnect()
            }
        }
        transportSession = nil

        // Clear rendering state
        framebuffer = nil
        renderer = nil
        videoStreamManager?.stopStream()
        videoStreamManager = nil

        connectionState = .disconnected
    }

    // MARK: - Input Events

    /// Send a key press or release event to the VNC server.
    ///
    /// - Parameters:
    ///   - downFlag: `true` for key press, `false` for key release.
    ///   - key: The X11 keysym value for the key.
    public func sendKeyEvent(downFlag: Bool, key: UInt32) {
        guard connectionState.isConnected, let transport = transportSession else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "KeyEvent",
                data: ClientMessage.keyEvent(downFlag: downFlag, key: key).serialize(),
                details: "key=0x\(String(key, radix: 16)) down=\(downFlag)"
            )
        }

        Task {
            try? await transport.sendKeyEvent(downFlag: downFlag, key: key)
        }
    }

    /// Send a pointer (mouse/touch) event to the VNC server.
    ///
    /// - Parameters:
    ///   - buttonMask: Bitmask of pressed buttons (bit 0 = left, 1 = middle, 2 = right,
    ///     3 = scroll up, 4 = scroll down).
    ///   - x: The X coordinate in framebuffer pixels.
    ///   - y: The Y coordinate in framebuffer pixels.
    public func sendPointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) {
        guard connectionState.isConnected, let transport = transportSession else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "PointerEvent",
                data: ClientMessage.pointerEvent(buttonMask: buttonMask, x: x, y: y).serialize(),
                details: "buttons=0x\(String(buttonMask, radix: 16)) pos=(\(x),\(y))"
            )
        }

        Task {
            try? await transport.sendPointerEvent(buttonMask: buttonMask, x: x, y: y)
        }
    }

    /// Send clipboard text to the VNC server.
    ///
    /// - Parameter text: The text to place on the server's clipboard.
    public func sendClipboardText(_ text: String) {
        guard connectionState.isConnected, let transport = transportSession else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "ClientCutText",
                data: ClientMessage.clientCutText(text).serialize(),
                details: "length=\(text.utf8.count)"
            )
        }

        Task {
            try? await transport.sendClipboardText(text)
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

    // MARK: - Private: Event Processing

    private func startEventProcessing(transport: TransportSession) {
        eventTask = Task { [weak self] in
            for await event in transport.events {
                guard let self, !Task.isCancelled else { break }
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
            handleFramebufferUpdate(rects)

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
            let manager = videoStreamManager
            mediaQueue.async { manager?.feedUDPData(datagram) }

        case .appleMediaRTPPacket(let packet):
            let manager = videoStreamManager
            mediaQueue.async { manager?.feedRTPData(packet) }

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

        // Determine pixel format to use
        let pixelFormat = configuration.preferredPixelFormat ?? serverInit.pixelFormat

        // Create framebuffer and renderer
        let fb = Framebuffer(
            width: Int(serverInit.framebufferWidth),
            height: Int(serverInit.framebufferHeight),
            pixelFormat: pixelFormat
        )
        self.framebuffer = fb
        self.renderer = FramebufferRenderer(framebuffer: fb, pixelFormat: pixelFormat)

        connectionState = .connected
    }

    private func handleFramebufferUpdate(_ rects: [(FramebufferRect, Data)]) {
        guard let renderer else { return }

        for (rect, data) in rects {
            if isTraceEnabled {
                diagnostics.protocolTrace.recordReceived(
                    type: "FramebufferUpdate",
                    data: data,
                    details: "encoding=\(rect.encoding) rect=(\(rect.x),\(rect.y) \(rect.width)x\(rect.height))"
                )
            }

            switch rect.encoding {
            case .copyRect:
                guard data.count >= 4 else { continue }
                let srcX = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
                let srcY = UInt16(data[data.startIndex + 2]) << 8 | UInt16(data[data.startIndex + 3])
                renderer.applyCopyRect(rect: rect, srcX: srcX, srcY: srcY)

            case .desktopSize, .extendedDesktopSize:
                guard rect.isSuccessfulDesktopResize else {
                    logger.warning(
                        "Ignoring rejected/invalid desktop resize status=\(rect.y) "
                            + "size=\(rect.width)x\(rect.height)")
                    continue
                }
                applyDesktopResize(width: rect.width, height: rect.height, renderer: renderer)

            case .cursor:
                // Cursor pseudo-encoding: handled at the rendering layer if needed
                break

            case .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer:
                // Pseudo-encodings handled via dedicated SessionEvent cases
                break

            default:
                do {
                    try renderer.applyRect(rect: rect, data: data)
                } catch {
                    logger.warning("Failed to apply rect (\(rect.encoding)): \(error.localizedDescription)")
                }
            }
        }

        // Update the displayed image
        currentImage = renderer.snapshot()
    }

    /// Apply one live geometry transition to every consumer of framebuffer
    /// dimensions. The media stream remains connected; new SPS/PPS parameter
    /// sets reconfigure the public VideoToolbox session when they arrive.
    private func applyDesktopResize(
        width: UInt16,
        height: UInt16,
        renderer: FramebufferRenderer
    ) {
        let newWidth = Int(width)
        let newHeight = Int(height)
        guard newWidth > 0, newHeight > 0 else { return }
        guard newWidth != framebufferWidth || newHeight != framebufferHeight else { return }

        logger.info(
            "Applying desktop resize \(framebufferWidth)x\(framebufferHeight) "
                + "-> \(newWidth)x\(newHeight)")
        renderer.handleDesktopResize(width: width, height: height)
        framebufferWidth = newWidth
        framebufferHeight = newHeight
        videoBandRenderer.setScreenSize(width: newWidth, height: newHeight)

        if let manager = videoStreamManager {
            mediaQueue.async {
                manager.updateFrameGeometry(width: newWidth, height: newHeight)
            }
        }
    }

    private func handleError(_ error: VNCProtocolError) {
        logger.error("Protocol error: \(error.localizedDescription)")
        lastError = error
        diagnostics.lastError = error

        if error == .connectionClosed {
            handleDisconnected()
        }
    }

    private func handleDisconnected() {
        logger.info("Disconnected")

        transportSession = nil
        videoStreamManager?.stopStream()
        videoStreamManager = nil

        if connectionState != .disconnecting {
            connectionState = .disconnected
        } else {
            connectionState = .disconnected
        }
    }

    // MARK: - Private: Helpers

    private func cleanupTransport() {
        eventTask?.cancel()
        eventTask = nil
        transportSession = nil
    }

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

        let width = framebufferWidth > 0 ? framebufferWidth : Int(offer.width)
        let height = framebufferHeight > 0 ? framebufferHeight : Int(offer.height)
        videoBandRenderer.setScreenSize(width: width, height: height)

        let renderer = videoBandRenderer
        // Coalesced main-thread delivery. A Task per decoded frame has no FIFO
        // guarantee (an older band frame could land after a newer one — visible
        // as flicker/regression) and floods the main thread at 240+ frames/sec
        // across bands. Instead: stage the newest buffer per band under a lock
        // and drain all staged bands in ONE main-queue hop (FIFO by definition);
        // under main-thread load intermediate frames are simply superseded.
        let coalescer = BandFrameCoalescer(renderer: renderer)
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

        manager.startStream(
            streamID: offer.streamID,
            width: width,
            height: height,
            // Match the offer generated by RFBTransport. The public default is
            // a conventional one-tile stream without DONL; the four-tile path
            // is an explicit diagnostic experiment until its reference-picture
            // remapping is reproduced portably.
            usesDecodingOrderNumbers:
                AppleMediaVideoMode.usesExperimentalTiledHEVC,
            frameCallback: callback
        )

        let streamGeneration = manager.decodeProgress.streamGeneration

        // Startup liveness watchdog. Recovery remains in the negotiated media
        // protocol: repeat an observed AVConference frame-loss report instead
        // of dirtying the framebuffer or restarting the VNC connection.
        if let transport = transportSession {
            let watchdogManager = manager
            let log = logger
            Task { [weak transport, weak watchdogManager] in
                for attempt in 1...3 {
                    try? await Task.sleep(for: .milliseconds(2500))
                    guard let transport, let m = watchdogManager, m.isStreamActive else { return }
                    let sources = await transport.videoSourceCount
                    let decoded = decodedBands.count
                    if sources > 0 && decoded >= sources {
                        if attempt > 1 { log.info("Dead-band watchdog: recovered, \(decoded)/\(sources) bands decoding") }
                        return
                    }
                    log.warning("Startup media watchdog: \(decoded)/\(sources) sources decoding "
                        + "(attempt \(attempt)); repeating observed frame-loss feedback")
                    await transport.repeatLastVideoLossFeedback()
                }
            }
        }

        // Long-running decode-output watchdog. A static desktop naturally
        // produces no decode submissions, so silence by itself is not a fault.
        // If submitted pictures stop producing output, rebuild only the public
        // decoder and repeat real loss feedback on the existing media session.
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
                    if detector.observe(
                        submittedFrameCount: progress.submittedFrameCount,
                        deliveredFrameCount: decodedBands.frameCount,
                        nowNanos: DispatchTime.now().uptimeNanoseconds
                    ) {
                        log.warning("Decode-output stall while compressed frames continue; "
                            + "rebuilding decoder in media session")
                        guard await transport.hasObservedVideoLossFeedback() else {
                            log.warning("Decoder stall has no observed RTP loss report; "
                                + "leaving the current media session untouched")
                            continue
                        }
                        recoveryQueue.async { [transport, m] in
                            guard m.recoverDecoderAfterOutputStall() else {
                                return
                            }
                            Task { [transport] in
                                await transport.repeatLastVideoLossFeedback()
                            }
                        }
                    }
                }
            }
        }

        // Transport-confirmed RTP loss already sends native AFB type-6 feedback
        // before releasing the post-gap packet. Do not layer PLI/FIR or full
        // framebuffer updates on top; those were the source of quality pulses.
        manager.onLossDetected = nil

        // VideoToolbox can accept a damaged sample synchronously and report its
        // missing-reference failure later. Rebuild it on the serial media queue,
        // retain the last rendered surface, and repeat the observed loss report.
        if let transport = transportSession {
            let recoveryQueue = mediaQueue
            let recoveryManager = manager
            manager.onDecoderFailure = { [weak transport, weak recoveryManager] failure in
                guard let transport, let recoveryManager else { return }
                Task { [transport, recoveryManager] in
                    guard await transport.hasObservedVideoLossFeedback(ssrc: failure.ssrc) else {
                        return
                    }
                    recoveryQueue.async { [transport, recoveryManager] in
                        guard recoveryManager.recoverDecoderInSession() else { return }
                        Task { [transport] in
                            await transport.repeatLastVideoLossFeedback(ssrc: failure.ssrc)
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
            await transport.setAppleMediaRTPSink { packet in
                queue.async { sinkManager.feedRTPData(packet) }
            }
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
            root = caches.appendingPathComponent("RootShellVNC/DecodedFrames", isDirectory: true)
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

/// Accumulates the newest decoded value for every source since the last display
/// drain. Screen bands are independent dirty-region streams: a static band can
/// legitimately emit fewer frames than a busy band, so no all-band barrier is
/// valid here.
struct LatestBandFrameAccumulator<Value> {
    private var staged: [UInt32: Value] = [:]

    mutating func submit(source: UInt32, value: Value) {
        staged[source] = value
    }

    mutating func takeAll() -> [UInt32: Value] {
        let latest = staged
        staged.removeAll(keepingCapacity: true)
        return latest
    }
}

/// Delivers the latest independently decoded screen bands to the main-thread
/// renderer. One FIFO main-queue hop coalesces bursts across sources; a newer
/// frame supersedes an older pending frame for the same band, so the UI cannot
/// fall behind the decoder.
final class BandFrameCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = LatestBandFrameAccumulator<CVPixelBuffer>()
    private var hopScheduled = false
    private let renderer: VideoBandLayerRenderer

    init(renderer: VideoBandLayerRenderer) {
        self.renderer = renderer
    }

    func submit(ssrc: UInt32, pixelBuffer: CVPixelBuffer) {
        lock.lock()
        accumulator.submit(source: ssrc, value: pixelBuffer)
        let shouldScheduleHop = !hopScheduled
        if shouldScheduleHop { hopScheduled = true }
        lock.unlock()

        if shouldScheduleHop { scheduleRendererHop() }
    }

    private func scheduleRendererHop() {
        DispatchQueue.main.async { [self] in
            lock.lock()
            let frames = accumulator.takeAll()
            hopScheduled = false
            lock.unlock()
            guard !frames.isEmpty else { return }
            MainActor.assumeIsolated {
                renderer.setBands(frames)
            }
        }
    }
}
