import Foundation
import RFBProtocol
import Security

/// Decode the stable display records in Apple's DisplayInfo2 (encoding 1105).
/// The payload includes its two-byte length prefix. Version 5 stores the
/// display count at byte 20 and places each 56-byte record's UInt16 display ID
/// at byte 40. Rectangles are `(minY, minX, maxY, maxX)`; the second rectangle
/// is in framebuffer pixels and is therefore used for rendering and input.
func appleDisplayInfo2Records(_ payload: Data) -> [AppleDisplayInfo] {
    guard payload.count >= 40 else { return [] }
    let start = payload.startIndex
    func uint16(at offset: Int) -> UInt16 {
        UInt16(payload[start + offset]) << 8
            | UInt16(payload[start + offset + 1])
    }
    let count = Int(uint16(at: 20))
    guard count > 0, count <= 16 else { return [] }

    return (0..<count).compactMap { index in
        let idOffset = 40 + index * 56
        guard idOffset + 21 < payload.count else { return nil }
        let id = UInt32(uint16(at: idOffset))
        let minY = Int(uint16(at: idOffset + 10))
        let minX = Int(uint16(at: idOffset + 12))
        let maxY = Int(uint16(at: idOffset + 14))
        let maxX = Int(uint16(at: idOffset + 16))
        guard maxX > minX, maxY > minY else { return nil }
        let flags = UInt32(uint16(at: idOffset + 18)) << 16
            | UInt32(uint16(at: idOffset + 20))
        return AppleDisplayInfo(
            displayIndex: id,
            originX: Int32(minX),
            originY: Int32(minY),
            width: UInt32(maxX - minX),
            height: UInt32(maxY - minY),
            flags: flags)
    }
}

/// Events emitted by the transport session for consumption by the UI layer.
public enum SessionEvent: Sendable {
    /// The connection state has changed.
    case stateChanged(ConnectionState)

    /// A framebuffer update with rectangle headers and associated pixel data.
    case framebufferUpdate([(FramebufferRect, Data)])

    /// The server rang the bell.
    case bell

    /// The server's clipboard text changed.
    case clipboardText(String)

    /// The handshake completed and the server sent its init message.
    case serverInit(ServerInit)

    /// A protocol error occurred.
    case error(VNCProtocolError)

    /// Apple encryption info pseudo-encoding received.
    case encryptionInfo(AppleEncryptionInfo)

    /// Apple display info pseudo-encoding received.
    case displayInfo(AppleDisplayInfo)

    /// Standard RFB multi-screen layout received.
    case desktopLayout(ExtendedDesktopSizePayload)

    /// Apple media stream offer pseudo-encoding received.
    case mediaStreamOffer(AppleMediaStreamOffer)

    /// A UDP datagram from Apple's accelerated media stream path.
    case udpDatagram(Data)

    /// An RTP-shaped packet recovered from Apple's TCP media stream fallback.
    case appleMediaRTPPacket(Data)

    /// The Apple media UDP receive socket was opened.
    case appleMediaUDPStarted(localPort: UInt16)

    /// A TCP control stream chunk observed after accepting Apple's media stream.
    case appleMediaControlRecord(encryptedLength: Int, encryptedPrefix: Data, plaintextPrefix: Data?, decryptError: String?)

    /// The connection was closed.
    case disconnected
}

/// How a client-sized remote display request was handled by the transport.
public enum RemoteDisplayResizeDisposition: Sendable, Equatable {
    /// Apple's negotiated virtual-display command was sent.
    case appleVirtualDisplay
    /// Standard RFB SetDesktopSize was sent after capability announcement.
    case standardSetDesktopSize
    /// The request is retained until the server announces support.
    case waitingForServerSupport
}

private struct PendingRemoteDisplaySize: Sendable, Equatable {
    let pixelWidth: UInt16
    let pixelHeight: UInt16
    let pointWidth: UInt16
    let pointHeight: UInt16
}

/// Resolve the number of Apple media receiver streams without ever asking for
/// a display the server did not offer. Kept outside the actor so the negotiation
/// rule can be verified without a live VNC server.
func selectedAppleMediaDisplayCount(
    offered: Int?,
    requested: Int
) -> Int {
    min(max(1, offered ?? 1), min(2, max(1, requested)))
}

/// A basic key or pointer message eligible for single-write batching.
public enum ClientInputEvent: Sendable, Equatable {
    case key(downFlag: Bool, key: UInt32)
    case pointer(buttonMask: UInt8, x: UInt16, y: UInt16)
}

/// An actor that manages the full lifecycle of a VNC connection.
///
/// `TransportSession` owns an ``RFBConnection`` for network I/O (a direct
/// `TCPConnection` by default, or a host-injected tunnel), a
/// `ConnectionStateMachine` for protocol logic, and drives the RFB handshake
/// by reading from the connection, feeding events to the state machine, and
/// executing the resulting actions.
///
/// Consumers observe the session through the `events` `AsyncStream`.
public actor TransportSession {

    // MARK: - Properties

    private let tcp: any RFBConnection
    /// Whether the connection was injected by the host instead of the default
    /// direct TCP path. Apple's High Performance media mode needs direct UDP
    /// reachability and is refused over a custom transport.
    private let usesCustomTransport: Bool
    private var stateMachine: ConnectionStateMachine
    private let host: String
    private let password: String
    private let username: String?
    /// Environment-backed diagnostics and experiment switches are launch-time
    /// configuration. Materializing ProcessInfo.environment copies and bridges
    /// the complete process environment, so never do it on the RTP hot path.
    private nonisolated let runtimeEnvironment: [String: String]
    private nonisolated let appleMediaDecodedRTPDumpPath: String?
    private nonisolated let appleMediaDecodedRTPDumpIncludesTimestamps: Bool
    private nonisolated let appleMediaUDPDatagramDumpPath: String?
    private nonisolated let appleMediaOutgoingRTCPDumpPath: String?
    private let rctlEnabled: Bool
    private let rateControlEnabled: Bool
    private var continuation: AsyncStream<SessionEvent>.Continuation?
    /// Single ordered handoff for all decrypted media RTP. It buffers startup
    /// packets until the decoder sink is ready and drains them atomically, so
    /// the former AsyncStream/direct-path boundary cannot reorder the IRAP burst.
    private var appleMediaPacketHandoff = AppleMediaPacketHandoff()
    /// Ordered notification for a fresh AVC media generation. The app installs
    /// this beside the RTP sink so its decoder reset is queued before any RTP
    /// from the new keys/SSRC can overtake it.
    private var appleMediaGenerationSink: (@Sendable (UInt64, Int) -> Void)?
    private var appleRemoteDisplaySizeSink: (@Sendable (UInt16, UInt16) -> Void)?
    private var activeAppleMediaTilesPerFrame = Int(
        AppleMediaVideoMode.negotiatedTilesPerFrame)
    /// Physical or virtual screen geometry announced by Apple's encrypted
    /// DisplayInfo2 control record, in the server's display order.
    private var appleMediaDisplayInfos: [AppleDisplayInfo] = []
    /// Per-SSRC packet jitter buffer. UDP reordering is repaired here before an
    /// HEVC fragmentation unit reaches the decoder.
    private var appleMediaRTPReorderBuffer = AppleMediaRTPReorderBuffer()
    private var appleMediaRTPReorderFlushTask: Task<Void, Never>?
    private var appleMediaRTPReorderScheduledDeadlineNanos: UInt64?
    private var readTask: Task<Void, Never>?
    private var handshakeComplete = false
    private var isDisconnecting = false
    private var terminalDisconnectHandled = false
    private var framebufferRequestSentNanos: UInt64 = 0

    /// Updates yielded to the consumer but not yet acknowledged via
    /// finishFramebufferUpdate(). Bounds the undecoded backlog: persistent
    /// Zlib/ZRLE streams mean updates can never be dropped, so backpressure
    /// comes from withholding the next request instead.
    private var unacknowledgedUpdates = 0
    /// Set when an update finished reading while the pipeline was full; the
    /// deferred incremental request goes out on the next acknowledgement.
    private var deferredUpdateRequest = false
    /// Whether this connection negotiated Apple's adaptive DCT encoding.
    private let appleDCTRequested: Bool
    private let appleClassicAutoUpdateRequested: Bool
    /// A control-only quantization update commonly precedes the initial DCT
    /// image. Keep requesting a complete reference until that image arrives;
    /// refinements and cache references are only valid after this boundary.
    private var awaitingAppleDCTInitialReference: Bool
    private var pendingAppleDCTAutoUpdateActivation = false
    private var appleDCTAutoUpdateActive = false
    private var appleDCTAutoUpdateRefreshTask: Task<Void, Never>?
    /// Auto-update delivery still retains exactly one decode credit. Pausing
    /// socket reads at this boundary applies TCP backpressure to the encoder,
    /// which both bounds stale-frame latency and gives the server an honest
    /// bandwidth signal for its DCT quality controller.
    private var framebufferCreditWaiter: CheckedContinuation<Void, Never>?
    private let maxUnacknowledgedUpdates = 1
    /// Latched once an Apple media stream offer arrives: media negotiation
    /// switches this channel to encrypted control records, so no further
    /// framebuffer update requests may be sent.
    private var framebufferRequestsSuppressed = false
    private var udpReadTasks: [Task<Void, Never>] = []
    private var udpChannels: [PosixUDPChannel] = []
    private let log = VNCLogger(category: "TransportSession")
    private let requestAppleMediaStream: Bool
    /// Legacy direct-transport switch for disabling adaptive rate control. The
    /// public Full Quality mode never enters the lossy media path at all.
    private var appleMediaNetworkProfile: AppleMediaNetworkProfile = .unknown
    // NOTE (2026-07-12): do NOT scale the initial advertised capacity by
    // framebuffer area. The server ignores the RCTL estimate while sending its
    // bootstrap IRAP, but the reduced value still leaks into
    // keyframe-recovery readiness and the ramp origin — at 5K it slowed and
    // destabilized the bootstrap the scaling was meant to protect.
    private var sentAppleMediaStreamConfiguration = false
    private var sentAppleMediaServerConfiguration = false
    private var sentAppleMediaPostAcceptEncodings = false
    private var sentAppleMediaPostAcceptViewerInfo = false
    private var sentAppleMediaPostAnswerViewerInfo = false
    private var sentAppleMediaReconfigurationRequest = false
    private var sentAppleMediaInitialSetDisplay = false
    private var sentAppleMediaAutoFrameUpdate = false
    private var appleMediaGenerationTracker = AppleMediaNegotiationGenerationTracker()
    private var acceptedAppleMediaStream = false
    private var drainedAppleMediaControlBytes = 0
    private var appleMediaControlBuffer = Data()
    private var appleDecryptedRFBBuffer = Data()
    private var emittedAppleMediaControlDiagnostics = 0
    private var latestAppleMediaControlDiagnostic: String?
    private var appleSessionKey: Data?
    private var appleEncryptedControlChannel: AESCBCChannel?
    private var appleMediaComCryptionChannel: AppleComCryptionChannel?
    private var applePreviousMediaComCryptionChannel: AppleComCryptionChannel?
    private var applePreviousMediaServerPacketID: UInt32 = 0
    private var appleMediaServerPacketID: UInt32 = 0
    private var appleMediaClientPacketID: UInt32 = 0
    private var pendingAppleMediaRTPStream: PendingAppleMediaRTPStream?
    private var confirmedAppleMediaRTPStream: ConfirmedAppleMediaRTPStream?
    private var appleMediaSRTPKeys: AppleMediaSRTPKeys?
    /// SRTP receive contexts for every server-to-viewer key (audio, video,
    /// video2). Incoming datagrams are matched to a context by SSRC.
    private var appleMediaSRTPContexts: [AppleSRTPContext] = []
    private var appleMediaSRTPContextBySSRC: [UInt32: AppleSRTPContext] = [:]
    private struct AppleMediaFeedbackRoute {
        let receiveContext: AppleSRTPContext
        let sendRTCPContext: AppleSRTCPContext
        let receiveRTCPContext: AppleSRTCPContext
        let localSSRC: UInt32
        let streamIndex: Int
    }

    /// Each negotiated display has independent SRTP/SRTCP keys and its own
    /// receiver SSRC. Remember the receive context that authenticated an
    /// incoming source so feedback uses that display's matching send context.
    private var appleMediaFeedbackRoutes: [AppleMediaFeedbackRoute] = []
    private var appleMediaFeedbackRouteByRemoteSSRC: [UInt32: AppleMediaFeedbackRoute] = [:]
    private var appleMediaVideoLocalSSRCs: [UInt32] = []
    /// Audio, video-one, and video-two offer lengths returned by the most
    /// recent native AVC message two. Kept as a live-probe diagnostic so a
    /// rejected second offer is distinguishable from RTP routing failure.
    private var appleMediaAnswerStreamLengths: [Int] = []
    /// Primary receiver SSRC retained as a plaintext/debugging fallback.
    private var appleMediaLocalSSRC: UInt32 = 0
    /// Video SSRCs seen on the media path and the channel each arrived on, so
    /// keyframe requests go back on the right connected socket.
    private var appleMediaVideoSSRCChannels: [UInt32: PosixUDPChannel] = [:]
    private var appleLastKeyframeRequestNanos: UInt64 = 0
    /// Most recent native frame-loss report for each source. This lets the
    /// decoder confirm that its gated source corresponds to observed RTP loss.
    private var appleMediaLastFrameLossFeedback: [UInt32: AppleMediaFrameLossFeedback] = [:]
    private var appleMediaMostRecentFrameLossSSRC: UInt32?
    /// RTP-shaped datagrams no configured SRTP key could authenticate (dropped).
    private var appleMediaUnprotectFailures: UInt64 = 0
    /// True once the session is known to be encrypted (ComCryption configured),
    /// i.e. SRTP keys WILL arrive on the control channel.
    private var appleMediaExpectsSRTP = false
    /// Media datagrams that arrived before the SRTP keys did (bounded ring),
    /// replayed in order the moment the contexts are configured.
    private var appleMediaPreKeyDatagrams: [(Data, PosixUDPChannel)] = []
    private var appleKeyframeRequestTask: Task<Void, Never>?
    /// Per-SSRC reception stats for Receiver Reports sent back through the
    /// matching display feedback route.
    private var appleMediaReceptionStats: [UInt32: AppleMediaReceptionStats] = [:]
    private var appleMediaLastSRLSR: UInt32 = 0
    private var appleMediaLastSRArrivalNanos: UInt64 = 0
    /// Low-precision form of the standard RTP timestamp echoed by RCTL.
    /// This is unrelated to the RTP media-control extension and RTCP LSR.
    private var appleMediaLastRTPEchoTimestampQ10: UInt16 = 0
    private var appleRCTLPreviousRTPTimestamp: UInt32?
    private var appleRCTLEchoTimestampArrivalNanos: UInt64 = 0
    private var appleRCTLTotalPacketsReceived: UInt32 = 0
    /// RTCP APP "RCTL" rate-control feedback (drives the server's adaptive
    /// encoder bitrate). This profile sends it at approximately 20 Hz; without
    /// it the server encodes at a constant maximum bitrate. The burst-loss
    /// accumulator resets after each report; the receive count is cumulative.
    private var appleRCTLFeedbackTask: Task<Void, Never>?
    private var appleRCTLPacketsInterval: Int = 0
    private var appleRCTLLostInterval: Int = 0
    private var appleRCTLBurstLostInterval: Int = 0
    private var appleRCTLLastDiagnosticNanos: UInt64 = 0
    private var appleMediaIngressPacketsSinceDiagnostic = 0
    private var appleMediaIngressProcessingNanosSinceDiagnostic: UInt64 = 0
    private var appleMediaIngressMaximumBatchSinceDiagnostic = 0
    /// Receiver-side capacity estimator used to populate RCTL. Apple's
    /// feedback-only screen receiver sends RCTL by itself.
    private var appleMediaRateController: AppleMediaRateController?
    private var appleRTCPReportTask: Task<Void, Never>?

    private struct AppleMediaReceptionStats {
        var baseSeq: UInt32 = 0
        var maxSeq: UInt16 = 0
        var cycles: UInt32 = 0
        var received: UInt32 = 0
        var expectedPrior: UInt32 = 0
        var receivedPrior: UInt32 = 0
        var recentSequences = BoundedRTPSequenceHistory(capacity: 256)
        var initialized = false
    }
    private var appleMediaDisplayCount: Int = 1
    /// User-selected upper bound shared by Apple display selection, HEVC
    /// receiver negotiation, and virtual display configuration.
    private let requestedDisplayCount: Int
    /// Whether the selected mode asks Apple to create client-sized virtual
    /// displays. Physical "All Displays" is one combined receiver; multiple
    /// independent receivers belong to this virtual-display path.
    private let requestsVirtualDisplays: Bool
    /// Message-1 bit advertised by the server. The native viewer only adds the
    /// HDR capability option to its video negotiator when this bit is present.
    private var appleMediaSupportsHDR = false
    private var appleMediaUDPBindings: [AppleMediaUDPBinding] = []
    private let appleMediaControlBufferLimit = 64 * 1024

    private struct AppleMediaUDPBinding: Equatable {
        let localPort: UInt16?
        let remotePort: UInt16
    }

    private struct AppleMediaRTPHeader {
        let payloadType: UInt8
        let sequenceNumber: UInt16
        let timestamp: UInt32
        let ssrc: UInt32
        let marker: Bool
    }

    private struct PendingAppleMediaRTPStream {
        let payloadType: UInt8
        let ssrc: UInt32
        var lastSequenceNumber: UInt16
        var packets: [Data]
    }

    private struct ConfirmedAppleMediaRTPStream {
        let payloadType: UInt8
        let ssrc: UInt32
        var lastSequenceNumber: UInt16
    }

    private struct AppleMediaSRTPKeys {
        let audioViewerToServer: Data
        let audioServerToViewer: Data
        let videoViewerToServer: Data
        let videoServerToViewer: Data
        let video2ViewerToServer: Data?
        let video2ServerToViewer: Data?
    }

    /// The current framebuffer width (set after ServerInit).
    private var fbWidth: UInt16 = 0
    /// The current framebuffer height (set after ServerInit).
    private var fbHeight: UInt16 = 0
    /// The negotiated pixel format.
    private var pixelFormat: PixelFormat = .bgra8888
    /// Structured command support advertised by an Apple RFB 3.889 server.
    /// This remains nil for regular RFB servers, which therefore use standard
    /// wheel-button input.
    private var appleServerCapabilities: AppleServerCapabilities?
    /// A regular RFB server may receive SetDesktopSize only after it sends an
    /// ExtendedDesktopSize rectangle. Retain that screen identity and any
    /// early client-size request until the announcement arrives.
    private var standardDesktopLayout: ExtendedDesktopSizePayload?
    private var pendingRemoteDisplaySize: PendingRemoteDisplaySize?
    private var lastSentRemoteDisplaySize: PendingRemoteDisplaySize?
    /// Command 29 starts a complete AVC generation. Sending another command
    /// before every expected RTP source from that generation is live makes the
    /// server retire its capture graph mid-startup. Keep only the newest drag
    /// size queued until the current generation proves ready.
    private var appleDisplayReconfigurationGeneration: UInt64?
    /// Stable virtual-display capability envelope. Changing these maxima in
    /// the same command that installs a mode can renegotiate the backing scale;
    /// requests wider than the old 3840 value intermittently
    /// landed on a 1× surface even though the mode explicitly described 2×.
    private let appleVirtualDisplayMaximumPixelWidth: UInt32 = 8_192
    private let appleVirtualDisplayMaximumPixelHeight: UInt32 = 8_192
    /// A staged virtual-display replacement must wait until the initial Apple
    /// media graph emits video. Message 2 only completes control negotiation;
    /// replacing the display before the first RTP packet can retire the
    /// physical capture graph before it has installed a source.
    private var completedInitialAppleMediaNegotiation = false
    /// Non-wheel pointer buttons currently held, preserved across fallback
    /// wheel press/release pairs just like the native client.
    private var pointerButtonMask: UInt8 = 0

    /// The async stream of session events for consumers.
    public nonisolated let events: AsyncStream<SessionEvent>

    // MARK: - Init

    /// Create a transport session for the given server.
    ///
    /// - Parameters:
    ///   - host: The server hostname or IP address.
    ///   - port: The server port (typically 5900).
    ///   - password: The VNC password for authentication.
    ///   - username: Optional username for Apple DH/SRP authentication.
    ///   - connection: Optional host-provided transport (an SSH or tssh
    ///     tunnel). When `nil`, a direct `TCPConnection` to `host:port` is
    ///     used. Apple's High Performance (UDP media) mode is refused over a
    ///     custom transport.
    public init(
        host: String,
        port: UInt16,
        password: String,
        username: String? = nil,
        preferredPixelFormat: PixelFormat = .bgra8888,
        preferredEncodings: [Encoding]? = nil,
        preferFullQualityVideo: Bool = false,
        displayCount: Int = 1,
        requestsVirtualDisplays: Bool = false,
        connection: (any RFBConnection)? = nil
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.runtimeEnvironment = environment
        self.appleMediaDecodedRTPDumpPath = environment["ROOTSHELL_VNC_DUMP_DECODED_RTP"]
        self.appleMediaDecodedRTPDumpIncludesTimestamps =
            environment["ROOTSHELL_VNC_DUMP_RTP_TIMED"] == "1"
        self.appleMediaUDPDatagramDumpPath = environment["ROOTSHELL_VNC_DUMP_MEDIA_UDP"]
        self.appleMediaOutgoingRTCPDumpPath = environment["ROOTSHELL_VNC_DUMP_OUTGOING_RTCP"]
        self.rctlEnabled = environment["ROOTSHELL_VNC_DISABLE_RCTL"] != "1"
        self.rateControlEnabled = !preferFullQualityVideo
            && environment["ROOTSHELL_VNC_DISABLE_RATE_CONTROL"] != "1"
        // Force IPv4 for "localhost": it resolves to both ::1 and 127.0.0.1, and
        // if TCP connects over IPv6 the server sends UDP media to ::1 while our
        // media socket is IPv4-only — so no video arrives. Pin both to 127.0.0.1.
        // A custom transport dials the host itself, so the pin only applies to
        // the default direct path.
        let resolvedHost = (host == "localhost") ? "127.0.0.1" : host
        self.usesCustomTransport = connection != nil
        self.tcp = connection ?? TCPConnection(host: resolvedHost, port: port)
        let configuredEncodings =
            preferredEncodings ?? ConnectionStateMachine.defaultPreferredEncodings
        let shouldUseAppleDCT =
            configuredEncodings.contains(.appleMultiVariantScreenshare)
                && !configuredEncodings.contains(.appleH264)
        let shouldUseAppleClassicAutoUpdate =
            !configuredEncodings.contains(.appleH264)
                && configuredEncodings.contains(.unknown(1105))
                && configuredEncodings.contains(.unknown(1104))
        self.stateMachine = ConnectionStateMachine(
            preferredPixelFormat: preferredPixelFormat,
            preferredEncodings: configuredEncodings
        )
        self.host = resolvedHost
        self.password = password
        self.username = username
        self.requestedDisplayCount = min(2, max(1, displayCount))
        self.requestsVirtualDisplays = requestsVirtualDisplays
        self.requestAppleMediaStream = configuredEncodings.contains(.appleH264)
        self.appleDCTRequested = shouldUseAppleDCT
        self.appleClassicAutoUpdateRequested = shouldUseAppleClassicAutoUpdate
        self.awaitingAppleDCTInitialReference = shouldUseAppleDCT

        var cont: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream<SessionEvent> { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    // MARK: - Public API

    /// Start the connection and perform the RFB protocol handshake.
    ///
    /// After a successful handshake, a background read loop is started that
    /// processes incoming server messages and emits events.
    public func connect() async throws {
        log.info("Starting connection")

        if usesCustomTransport, requestAppleMediaStream {
            throw VNCProtocolError.protocolViolation(
                "High Performance (UDP media) mode cannot run over a custom transport")
        }

        isDisconnecting = false
        terminalDisconnectHandled = false
        handshakeComplete = false
        await tcp.setDisconnectHandler { [weak self] error in
            Task { await self?.handleUnexpectedTCPDisconnect(error) }
        }

        // Transition state machine
        stateMachine.beginConnecting()
        emitState()

        // Establish TCP
        try await tcp.connect()
        appleMediaNetworkProfile = AppleMediaNetworkProfile.detect(
            from: await tcp.pathCharacteristics(),
            remoteHost: host)
        log.info(
            "Apple media bearer=\(appleMediaNetworkProfile.name) "
                + "initialBWE=\(Int(appleMediaNetworkProfile.initialCapacityBps / 1_000))kbps "
                + "screenTransport=local")
        let actions = stateMachine.handle(event: .connected)
        emitState()
        try await executeActions(actions)

        // Perform handshake
        try await performHandshake()
        handshakeComplete = true

        // Start the message read loop
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Send a key event to the server.
    public func sendKeyEvent(downFlag: Bool, key: UInt32) async throws {
        let msg = ClientMessage.keyEvent(downFlag: downFlag, key: key)
        try await sendClientPayload(msg.serialize())
    }

    /// Send a run of key/pointer events as one socket write. The queue-side
    /// coalescing already bounds the run length; batching what remains keeps
    /// a burst (typed text, pointer transitions) to a single send instead of
    /// one awaited write per 6-8 byte message.
    public func sendInputEvents(_ events: [ClientInputEvent]) async throws {
        guard !events.isEmpty else { return }
        var payload = Data()
        for event in events {
            switch event {
            case .key(let downFlag, let key):
                payload.append(ClientMessage.keyEvent(
                    downFlag: downFlag, key: key).serialize())
            case .pointer(let buttonMask, let x, let y):
                pointerButtonMask = buttonMask
                payload.append(ClientMessage.pointerEvent(
                    buttonMask: buttonMask, x: x, y: y).serialize())
            }
        }
        try await sendClientPayload(payload)
    }

    /// Send a pointer (mouse/touch) event to the server.
    public func sendPointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) async throws {
        pointerButtonMask = buttonMask
        let msg = ClientMessage.pointerEvent(buttonMask: buttonMask, x: x, y: y)
        try await sendClientPayload(msg.serialize())
    }

    /// Send precise scrolling when the Apple server explicitly advertises the
    /// command. Apple's Standard `0x1` ServerInit omits the structured command
    /// bitmap, but an RFB 3.889 server still implements the same precise-input
    /// extension used by its media connection. Conventional servers retain
    /// ordinary RFB wheel-button events.
    public func sendScrollEvent(_ event: AppleScrollEvent) async throws {
        if supportsApplePreciseInput {
            var payload = ClientMessage.appleScrollEvent(event).serialize()
            if event.momentumPhase == .none, event.scrollPhase != .none {
                payload.append(ClientMessage.appleGestureScrollEvent(
                    AppleGestureScrollEvent(
                        deltaX: Float(event.pointDeltaX),
                        deltaY: Float(event.pointDeltaY),
                        naturalScrolling: true,
                        gesturePhase: event.scrollPhase,
                        x: event.x,
                        y: event.y)
                ).serialize())
            }
            try await sendClientPayload(payload)
            return
        }

        let isAppleServer = stateMachine.negotiatedVersion?.isApple == true
        let wheelMasks = AppleScrollFallback.wheelButtonMasks(
            for: event,
            includeHorizontal: isAppleServer)
        guard !wheelMasks.isEmpty else { return }

        // RFB messages are self-framing on the TCP byte stream. Batch this
        // sample's press/release pairs so accelerated scrolling does not turn
        // into dozens of actor hops and socket writes while retaining every
        // individual wheel transition on the wire.
        var payload = Data(capacity: wheelMasks.count * 12)
        for wheelMask in wheelMasks {
            payload.append(ClientMessage.pointerEvent(
                buttonMask: pointerButtonMask | wheelMask,
                x: event.x,
                y: event.y).serialize())
            payload.append(ClientMessage.pointerEvent(
                buttonMask: pointerButtonMask,
                x: event.x,
                y: event.y).serialize())
        }
        try await sendClientPayload(payload)
    }

    /// Send the native begin/end gesture envelope for both Apple Standard and
    /// media connections. Conventional RFB servers have no equivalent message;
    /// their wheel fallback remains unchanged.
    public func sendGestureEvent(_ event: AppleGestureEvent) async throws {
        guard supportsApplePreciseInput else { return }
        try await sendClientPayload(
            ClientMessage.appleGestureEvent(event).serialize())
    }

    private var supportsApplePreciseInput: Bool {
        Self.shouldUseApplePreciseInput(
            serverVersion: stateMachine.negotiatedVersion,
            capabilities: appleServerCapabilities)
    }

    static func shouldUseApplePreciseInput(
        serverVersion: ProtocolVersion?,
        capabilities: AppleServerCapabilities?
    ) -> Bool {
        capabilities?.supportsServerCommand(
            AppleServerCapabilities.preciseScrollCommand) == true
            || serverVersion?.isApple == true
    }

    /// Send clipboard text to the server.
    public func sendClipboardText(_ text: String) async throws {
        let msg = ClientMessage.clientCutText(text)
        try await sendClientPayload(msg.serialize())
    }

    /// Number of distinct video RTP sources (screen bands) seen this session.
    public var videoSourceCount: Int {
        appleMediaVideoSSRCChannels.count
    }

    /// Diagnostic mapping from authenticated remote video SSRCs to negotiated
    /// receiver numbers (1 or 2).
    public var videoSourceReceiverIndexes: [Int] {
        appleMediaFeedbackRouteByRemoteSSRC.values
            .map(\.streamIndex)
            .sorted()
    }

    public var mediaAnswerStreamLengths: [Int] {
        appleMediaAnswerStreamLengths
    }

    public var mediaControlDiagnostic: String? {
        latestAppleMediaControlDiagnostic
    }

    public var currentAppleMediaTilesPerFrame: Int {
        activeAppleMediaTilesPerFrame
    }

    /// Install the in-session media-generation boundary callback. This is
    /// separate from connection state: a display resize renegotiates AVC while
    /// the RFB session and its input/control channel remain alive.
    public func setAppleMediaGenerationSink(
        _ sink: (@Sendable (UInt64, Int) -> Void)?
    ) {
        appleMediaGenerationSink = sink
    }

    public func setAppleRemoteDisplaySizeSink(
        _ sink: (@Sendable (UInt16, UInt16) -> Void)?
    ) {
        appleRemoteDisplaySizeSink = sink
    }

    /// Request a framebuffer update from the server.
    public func requestFramebufferUpdate(incremental: Bool) async throws {
        if appleDCTAutoUpdateActive {
            // A type-3 request competes with the active type-9 subscription and
            // can make the server enqueue a second reference frame. Renewing
            // the subscription requests current geometry without creating a
            // parallel polling loop.
            try await sendAppleDCTAutoFrameUpdate()
            return
        }
        let msg = ClientMessage.framebufferUpdateRequest(
            incremental: incremental,
            x: 0, y: 0,
            width: fbWidth,
            height: fbHeight
        )
        try await sendClientPayload(msg.serialize())
        framebufferRequestSentNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// Acknowledge that the consumer finished decoding and presenting one
    /// framebuffer update. Standard RFB encodings carry persistent codec
    /// state, so updates must not be dropped; this credit return is the
    /// backpressure that bounds the undecoded backlog. With a single
    /// standard-RFB credit, the next request is deliberately
    /// deferred until this acknowledgement so stale frames cannot queue.
    public func finishFramebufferUpdate() async throws {
        unacknowledgedUpdates = max(0, unacknowledgedUpdates - 1)
        defer { resumeFramebufferCreditWaiterIfPossible() }

        if pendingAppleDCTAutoUpdateActivation {
            pendingAppleDCTAutoUpdateActivation = false
            appleDCTAutoUpdateActive = true
            deferredUpdateRequest = false
            try await sendAppleDCTAutoFrameUpdate()
            startAppleDCTAutoUpdateRefreshTask()
            log.info("Enabled Apple DCT adaptive auto updates")
            return
        }

        if appleDCTAutoUpdateActive {
            deferredUpdateRequest = false
            return
        }

        if appleDCTRequested,
           awaitingAppleDCTInitialReference,
           stateMachine.negotiatedVersion?.isApple == true {
            deferredUpdateRequest = false
            try await requestFramebufferUpdate(incremental: false)
            return
        }

        guard deferredUpdateRequest, !framebufferRequestsSuppressed else { return }
        deferredUpdateRequest = false
        try await requestFramebufferUpdate(incremental: true)
    }

    /// Request one remote display matching the client viewport. Apple servers
    /// use the capability-gated virtual-display command behind Dynamic
    /// Resolution; regular servers use standard SetDesktopSize only after
    /// announcing ExtendedDesktopSize support.
    public func requestRemoteDisplaySize(
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        pointWidth: UInt16,
        pointHeight: UInt16
    ) async throws -> RemoteDisplayResizeDisposition {
        let requested = PendingRemoteDisplaySize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pointWidth: pointWidth,
            pointHeight: pointHeight)
        guard requested != lastSentRemoteDisplaySize else {
            return appleServerCapabilities?.supportsServerCommand(
                AppleServerCapabilities.displayConfigurationCommand) == true
                ? .appleVirtualDisplay
                : .standardSetDesktopSize
        }

        pendingRemoteDisplaySize = requested
        if appleServerCapabilities?.supportsServerCommand(
            AppleServerCapabilities.displayConfigurationCommand) == true {
            if requestAppleMediaStream,
               !completedInitialAppleMediaNegotiation {
                log.info(
                    "Deferring staged virtual display \(pixelWidth)x\(pixelHeight) "
                        + "until initial Apple media negotiation completes")
                return .appleVirtualDisplay
            }
            if appleDisplayReconfigurationGeneration != nil {
                log.info(
                    "Coalescing virtual display \(pixelWidth)x\(pixelHeight) "
                        + "while media reconfiguration is in flight")
                return .appleVirtualDisplay
            }
            try await sendAppleVirtualDisplaySize(requested)
            return .appleVirtualDisplay
        }
        if standardDesktopLayout != nil {
            try await sendStandardDesktopSize(requested)
            return .standardSetDesktopSize
        }

        log.info(
            "Retaining client-sized display request \(pixelWidth)x\(pixelHeight) "
                + "until the server announces resize support")
        return .waitingForServerSupport
    }

    /// Disconnect from the server.
    public func disconnect() async {
        log.info("Disconnecting")
        isDisconnecting = true
        terminalDisconnectHandled = true
        readTask?.cancel()
        readTask = nil
        appleDCTAutoUpdateRefreshTask?.cancel()
        appleDCTAutoUpdateRefreshTask = nil
        framebufferCreditWaiter?.resume()
        framebufferCreditWaiter = nil
        appleMediaGenerationSink = nil
        appleRemoteDisplaySizeSink = nil
        await stopAppleMediaUDP()
        await tcp.close()
        let actions = stateMachine.handle(event: .userRequestedDisconnect)
        emitState()
        for action in actions {
            await executeActionNoThrow(action)
        }
        continuation?.yield(.disconnected)
        continuation?.finish()
    }

    // MARK: - Handshake

    private func performHandshake() async throws {
        // Step 1: Read server protocol version (12 bytes)
        let versionData = try await tcp.read(exactly: ProtocolVersion.wireSize)
        let serverVersion = try ProtocolVersion(data: versionData)
        log.info("Server version: \(serverVersion)")

        let actions1 = stateMachine.handle(event: .receivedProtocolVersion(serverVersion))
        emitState()
        try await executeActions(actions1)

        // Step 2: Read security types
        if serverVersion.isAtLeast(.v3_7) || serverVersion.isApple {
            try await readSecurityTypes37()
        } else {
            try await readSecurityTypes33()
        }

        // Step 3: Read security result
        // Apple auth types (30, 33) handle their own result internally or
        // go straight to ServerInit. Only standard VNC types need a separate
        // SecurityResult message.
        let selectedType = stateMachine.selectedSecurityType
        if selectedType == .macAuthentication {
            // Type 33: MacAuthenticator reads its own auth result internally.
            // The server also sends a second VNC SecurityResult afterward.
            try await readSecurityResult(canReadReason: false)
        } else if selectedType == .apple30 {
            // Type 30 DH: server sends a 4-byte result after the DH exchange
            try await readSecurityResult(canReadReason: false)
        } else {
            let negotiatedVersion = stateMachine.negotiatedVersion ?? .v3_8
            if negotiatedVersion.isAtLeast(.v3_8) {
                try await readSecurityResult(canReadReason: true)
            } else if selectedType == .vncAuthentication {
                try await readSecurityResult(canReadReason: false)
            } else {
                // No auth result for .none on < 3.8
                let actions = stateMachine.handle(event: .authenticationSucceeded)
                emitState()
                try await executeActions(actions)
            }
        }

        // Step 4: Read ServerInit
        // Note: ClientInit (shared=1 byte) is sent by executeAction(.requestServerInit)
        // which is triggered by the state machine's authenticationSucceeded action.
        // We must NOT send it again here.
        try await readServerInit()
    }

    private func readSecurityTypes37() async throws {
        let countData = try await tcp.read(exactly: 1)
        let count = Int(countData[countData.startIndex])

        if count == 0 {
            // Server rejected us; read the reason string
            let reason = try await readReasonString()
            throw VNCProtocolError.authenticationFailed(reason)
        }

        let typesData = try await tcp.read(exactly: count)
        let types = typesData.map { SecurityType(rawValue: $0) }
        log.info("Server offers security types: \(types)")

        let actions = stateMachine.handle(event: .receivedSecurityTypes(types))
        emitState()
        try await executeActions(actions)

        // If we selected an authenticating type, perform the auth now
        if case .authenticating(let secType) = stateMachine.state {
            try await performAuthentication(secType)
        }
    }

    /// Whether the security type byte for the current auth has already been sent.
    /// For Type 33, the MacAuthenticator combines it with the first message.
    private var securityTypeSentSeparately = true

    private func readSecurityTypes33() async throws {
        let secData = try await tcp.read(exactly: 4)
        var reader = MessageReader(data: secData)
        let secTypeRaw = try reader.readUInt32()

        if secTypeRaw == 0 {
            let reason = try await readReasonString()
            throw VNCProtocolError.authenticationFailed(reason)
        }

        let secType = SecurityType(rawValue: UInt8(secTypeRaw & 0xFF))
        let actions = stateMachine.handle(event: .receivedSecurityTypes([secType]))
        emitState()
        try await executeActions(actions)

        if case .authenticating(let st) = stateMachine.state {
            try await performAuthentication(st)
        }
    }

    private func performAuthentication(_ securityType: SecurityType) async throws {
        let authenticator: Authenticator

        switch securityType {
        case .vncAuthentication:
            authenticator = VNCAuthenticator(password: password)
        case .apple30:
            authenticator = DHAuthenticator(
                username: username ?? "user",
                password: password
            )
        case .macAuthentication:
            var macAuth = MacAuthenticator(
                username: username ?? "user",
                password: password
            )
            macAuth.securityTypeAlreadySent = securityTypeSentSeparately
            authenticator = macAuth
        case .srp:
            authenticator = SRPAuthenticator(
                username: username ?? "user",
                password: password
            )
        case .none:
            // No authentication needed
            return
        default:
            throw VNCProtocolError.authenticationFailed(
                "Unsupported security type for authentication: \(securityType)")
        }

        let authResult = try await authenticator.authenticate(connection: tcp)
        appleSessionKey = authResult.appleSessionKey
        log.info("Authentication completed for \(securityType)")
    }

    private func readSecurityResult(canReadReason: Bool) async throws {
        let resultData = try await tcp.read(exactly: 4)
        var reader = MessageReader(data: resultData)
        let result = try reader.readUInt32()

        if result == 0 {
            let actions = stateMachine.handle(event: .authenticationSucceeded)
            emitState()
            try await executeActions(actions)
        } else {
            var reason = "Authentication failed (result=\(result))"
            if canReadReason {
                if let reasonStr = try? await readReasonString() {
                    reason = reasonStr
                }
            }
            let actions = stateMachine.handle(event: .authenticationFailed(reason))
            emitState()
            for action in actions {
                await executeActionNoThrow(action)
            }
            throw VNCProtocolError.authenticationFailed(reason)
        }
    }

    private func sendClientInit() async throws {
        // Apple's capability-bearing 0xc1 mode and virtual displays belong to
        // its media connection, not to a Zlib/ZRLE Standard session. Forcing
        // 0xc1 without completing media setup leaves the server waiting and the
        // framebuffer black. Standard uses the ordinary shared-session flag;
        // its pending Match Client request may still use public SetDesktopSize
        // when a regular RFB server advertises ExtendedDesktopSize support.
        let flags: UInt8 = requestAppleMediaStream ? 0xc1 : 0x01
        try await tcp.send(Data([flags]))
        log.debug("Sent ClientInit flags=0x\(String(flags, radix: 16))")
    }

    private func readServerInit() async throws {
        // Read the fixed-size portion: width(2) + height(2) + pixelFormat(16) + nameLength(4) = 24
        log.info("Reading ServerInit (\(ServerInit.minWireSize) bytes)...")
        let headerData = try await tcp.read(exactly: ServerInit.minWireSize)
        log.debug("ServerInit raw header: \(headerData.map { String(format: "%02x", $0) }.joined(separator: " "))")
        var reader = MessageReader(data: headerData)
        let width = try reader.readUInt16()
        let height = try reader.readUInt16()
        let pf = try reader.readPixelFormat()
        let nameLen = try reader.readUInt32()

        let serverInitNameField = try await tcp.read(exactly: Int(nameLen))
        var nameData = serverInitNameField
        if stateMachine.negotiatedVersion?.isApple == true,
           let capabilities = AppleServerCapabilities(
               serverInitNameField: serverInitNameField) {
            appleServerCapabilities = capabilities
            nameData = AppleServerCapabilities.desktopNameData(
                fromServerInitNameField: serverInitNameField)
            let preciseScroll = capabilities.supportsServerCommand(
                AppleServerCapabilities.preciseScrollCommand)
            let dynamicDisplay = capabilities.supportsServerCommand(
                AppleServerCapabilities.displayConfigurationCommand)
            log.info(
                "Apple ServerInit capabilities: flags=0x\(String(capabilities.serverFlags, radix: 16)) "
                    + "preciseScroll=\(preciseScroll) dynamicDisplay=\(dynamicDisplay)")
        } else {
            appleServerCapabilities = nil
        }
        let name = String(data: nameData, encoding: .utf8)
            ?? String(data: nameData, encoding: .isoLatin1)
            ?? ""

        let serverInit = ServerInit(
            framebufferWidth: width,
            framebufferHeight: height,
            pixelFormat: pf,
            name: name
        )

        self.fbWidth = width
        self.fbHeight = height
        activeAppleMediaTilesPerFrame = AppleMediaVideoMode.activeTileCount(
            pixelWidth: Int(width),
            pixelHeight: Int(height))
        self.pixelFormat = pf

        log.info("ServerInit: \(width)x\(height) '\(name)'")

        // A client-sized request may have been staged before connecting. Send
        // Apple's virtual-display description as soon as ServerInit confirms
        // support and, critically, before SetEncodings starts media setup. This
        // prevents a constrained remote viewer from first receiving a physical
        // 5K reference frame and only resizing after the video path is already
        // congested.
        if !requestAppleMediaStream,
           let pendingRemoteDisplaySize,
           appleServerCapabilities?.supportsServerCommand(
               AppleServerCapabilities.displayConfigurationCommand) == true {
            try await sendAppleVirtualDisplaySize(pendingRemoteDisplaySize)
        }

        let actions = stateMachine.handle(event: .receivedServerInit(serverInit))
        emitState()
        if requestAppleMediaStream {
            try await sendAppleMediaStreamSetupIfNeeded()
        } else {
            try await executeActions(actions)
        }

        continuation?.yield(.serverInit(serverInit))
    }

    private func readReasonString() async throws -> String {
        let lenData = try await tcp.read(exactly: 4)
        var reader = MessageReader(data: lenData)
        let len = try reader.readUInt32()
        guard len > 0 else { return "Unknown error" }
        let textData = try await tcp.read(exactly: Int(len))
        return String(data: textData, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: - Message read loop

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                if acceptedAppleMediaStream {
                    try await drainAppleMediaControlRecord()
                    continue
                }

                let typeData = try await tcp.read(exactly: 1)
                let messageType = typeData[typeData.startIndex]

                switch messageType {
                case 0: // FramebufferUpdate
                    try await handleFramebufferUpdate()
                case 1: // SetColorMapEntries
                    try await handleSetColorMapEntries()
                case 2: // Bell
                    await handleBell()
                case 3: // ServerCutText
                    try await handleServerCutText()
                case 0x14:
                    // Apple media short control (8 bytes total). The server can
                    // emit these on the clear channel before the media stream is
                    // accepted; consume the remaining 7 bytes so a race in that
                    // timing doesn't desync the whole stream (which cascades into
                    // garbage framebuffer rects and a dead connection).
                    _ = try await tcp.read(exactly: 7)
                default:
                    log.warning("Unknown server message type: \(messageType)")
                    continuation?.yield(.error(.protocolViolation("Unknown message type: \(messageType)")))
                }
            } catch is CancellationError {
                break
            } catch let error as VNCProtocolError {
                log.error("Read loop error: \(error.localizedDescription)")
                continuation?.yield(.error(error))
                await terminateUnexpectedConnection(error)
                break
            } catch {
                log.error("Read loop error: \(error.localizedDescription)")
                let protocolError = VNCProtocolError.ioError(error.localizedDescription)
                continuation?.yield(.error(protocolError))
                await terminateUnexpectedConnection(protocolError)
                break
            }
        }
    }

    private func handleUnexpectedTCPDisconnect(_ error: VNCProtocolError) async {
        // During the handshake, the awaited read path owns error propagation
        // back to connect(). After ServerInit, this state callback is the
        // authoritative fallback when iOS resumes a suspended failed socket.
        guard handshakeComplete,
              !isDisconnecting,
              !terminalDisconnectHandled else { return }
        log.error("TCP state reported connection loss: \(error.localizedDescription)")
        continuation?.yield(.error(error))
        await terminateUnexpectedConnection(error)
    }

    private func terminateUnexpectedConnection(_ error: VNCProtocolError) async {
        guard !isDisconnecting, !terminalDisconnectHandled else { return }
        terminalDisconnectHandled = true
        readTask?.cancel()
        appleDCTAutoUpdateRefreshTask?.cancel()
        appleDCTAutoUpdateRefreshTask = nil
        framebufferCreditWaiter?.resume()
        framebufferCreditWaiter = nil
        _ = stateMachine.handle(event: .connectionLost(error))
        emitState()
        await stopAppleMediaUDP()
        await tcp.close()
        continuation?.yield(.disconnected)
        continuation?.finish()
    }

    private func handleFramebufferUpdate() async throws {
        // padding(1) + numberOfRectangles(2) = 3 bytes
        let headerData = try await tcp.read(exactly: 3)
        let rectCount = UInt16(headerData[headerData.startIndex + 1]) << 8
                      | UInt16(headerData[headerData.startIndex + 2])

        var rectsWithData: [(FramebufferRect, Data)] = []
        rectsWithData.reserveCapacity(Int(rectCount))
        var pendingResize: FramebufferRect?

        for _ in 0..<rectCount {
            let rectData = try await tcp.read(exactly: FramebufferRect.wireSize)
            var reader = MessageReader(data: rectData)
            let rect = try FramebufferRect(reader: &reader)

            let pixelData: Data

            switch rect.encoding {
            case .raw:
                let byteCount = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
                if byteCount > 0 {
                    pixelData = try await tcp.read(exactly: byteCount)
                } else {
                    pixelData = Data()
                }

            case .zlib, .zrle:
                // Wire format: UInt32 compressedLength, then compressedLength bytes.
                // We read the length prefix + compressed data and forward both to the
                // renderer so it can decompress using its persistent zlib stream.
                let lenData = try await tcp.read(exactly: 4)
                let compressedLen = Int(lenData[lenData.startIndex]) << 24
                    | Int(lenData[lenData.startIndex + 1]) << 16
                    | Int(lenData[lenData.startIndex + 2]) << 8
                    | Int(lenData[lenData.startIndex + 3])
                let compressedData = compressedLen > 0
                    ? try await tcp.read(exactly: compressedLen)
                    : Data()
                // Forward length prefix + compressed bytes so the renderer can parse
                var fullPayload = Data(capacity: 4 + compressedLen)
                fullPayload.append(lenData)
                fullPayload.append(compressedData)
                pixelData = fullPayload

            case .tight:
                pixelData = try await readTightRectanglePayload(rect: rect)

            case .appleMultiVariantScreenshare:
                // Apple Adaptive DCT (1011) is framed as a big-endian UInt32
                // byte count followed by one self-typed codec message.
                let lengthData = try await tcp.read(exactly: 4)
                let length = Int(lengthData[lengthData.startIndex]) << 24
                    | Int(lengthData[lengthData.startIndex + 1]) << 16
                    | Int(lengthData[lengthData.startIndex + 2]) << 8
                    | Int(lengthData[lengthData.startIndex + 3])
                var fullPayload = lengthData
                if length > 0 {
                    fullPayload.append(try await tcp.read(exactly: length))
                }
                pixelData = fullPayload

            case .copyRect:
                // 4 bytes: srcX(2) + srcY(2)
                pixelData = try await tcp.read(exactly: 4)

            case .desktopSize:
                pixelData = Data()

            case .extendedDesktopSize:
                // ExtendedDesktopSize is not payload-free: one count byte and
                // three padding bytes are followed by 16 bytes per screen.
                // Consume it in full or the next RFB message begins mid-layout.
                var payload = try await tcp.read(exactly: ExtendedDesktopSizePayload.headerWireSize)
                let payloadSize = ExtendedDesktopSizePayload.wireSize(screenCount: payload[payload.startIndex])
                let remaining = payloadSize - ExtendedDesktopSizePayload.headerWireSize
                if remaining > 0 {
                    payload.append(try await tcp.read(exactly: remaining))
                }
                let layout = try ExtendedDesktopSizePayload(data: payload)
                try await noteStandardDesktopSizeSupport(layout)
                continuation?.yield(.desktopLayout(layout))
                pixelData = payload

            case .encryptionInfo:
                // Apple encryption pseudo-encoding: read 8 bytes
                let eiData = try await tcp.read(exactly: 8)
                var eiReader = MessageReader(data: eiData)
                let info = try AppleEncryptionInfo(reader: &eiReader)
                continuation?.yield(.encryptionInfo(info))
                // Feed to state machine for response path (Finding 6)
                let eiActions = stateMachine.handle(event: .receivedEncryptionInfo(info))
                try await executeActions(eiActions)
                pixelData = Data()

            case .serverDisplayInfo:
                // Apple display info pseudo-encoding: read 24 bytes
                let diData = try await tcp.read(exactly: 24)
                var diReader = MessageReader(data: diData)
                let info = try AppleDisplayInfo(reader: &diReader)
                continuation?.yield(.displayInfo(info))
                try await sendAppleStandardDisplaySelectionIfNeeded(
                    displayID: info.displayIndex)
                // Feed to state machine (informational, no response)
                let _ = stateMachine.handle(event: .receivedAppleDisplayInfo(info))
                pixelData = Data()

            case .mediaStreamOffer:
                // Apple RFBMediaStreamMessage1: current macOS payload is 36 bytes.
                let offerData = try await tcp.read(exactly: AppleMediaStreamOffer.wirePayloadSize)
                try await handleAppleMediaStreamOfferPayload(offerData)
                pixelData = offerData

            case .cursor:
                // Cursor pseudo-encoding: pixel data + bitmask
                let pixelBytes = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
                let maskBytes = Int((Int(rect.width) + 7) / 8) * Int(rect.height)
                let totalBytes = pixelBytes + maskBytes
                if totalBytes > 0 {
                    pixelData = try await tcp.read(exactly: totalBytes)
                } else {
                    pixelData = Data()
                }

            case .unknown(let value) where value == 1100:
                // Apple cursor-position notification; coordinates are carried
                // by the rectangle header.
                pixelData = Data()

            case .unknown(let value) where value == 1101:
                // Legacy Apple display layout: 10-byte header followed by
                // 28 bytes per display. The count is the final UInt16.
                var payload = try await tcp.read(exactly: 10)
                let count = Int(payload[payload.startIndex + 8]) << 8
                    | Int(payload[payload.startIndex + 9])
                if count > 0 {
                    payload.append(try await tcp.read(exactly: count * 28))
                }
                pixelData = payload

            case .unknown(let value) where value == 1104:
                // Apple cursor cache record: id + payload byte count.
                var payload = try await tcp.read(exactly: 8)
                let length = Int(payload[payload.startIndex + 4]) << 24
                    | Int(payload[payload.startIndex + 5]) << 16
                    | Int(payload[payload.startIndex + 6]) << 8
                    | Int(payload[payload.startIndex + 7])
                if length > 0 {
                    payload.append(try await tcp.read(exactly: length))
                }
                pixelData = payload

            case .unknown(let value) where value == 1105:
                // Apple DisplayInfo2: a UInt16 byte count followed by the
                // complete display-layout structure.
                var payload = try await tcp.read(exactly: 2)
                let length = Int(payload[payload.startIndex]) << 8
                    | Int(payload[payload.startIndex + 1])
                if length > 0 {
                    payload.append(try await tcp.read(exactly: length))
                }
                for info in appleDisplayInfo2Records(payload) {
                    continuation?.yield(.displayInfo(info))
                    try await sendAppleStandardDisplaySelectionIfNeeded(
                        displayID: info.displayIndex)
                }
                pixelData = payload

            default:
                // For encodings we don't specifically handle, log and skip.
                // Since we only advertise encodings we implement, this path
                // should only be hit if the server misbehaves.
                log.warning("Unhandled encoding \(rect.encoding.rawValue) for rect \(rect.width)x\(rect.height)")
                pixelData = Data()
            }

            rectsWithData.append((rect, pixelData))
            if rect.isSuccessfulDesktopResize {
                pendingResize = rect
            }
        }

        if let resize = pendingResize {
            try await acceptFramebufferResize(width: resize.width, height: resize.height)
        }

        let receivedPortableFullFrame = rectsWithData.contains(where: { rect, _ in
               (rect.encoding == .tight || rect.encoding == .zlib
                    || rect.encoding == .zrle || rect.encoding == .raw)
                   && rect.x == 0 && rect.y == 0
                   && rect.width >= fbWidth && rect.height >= fbHeight
           })
        if appleClassicAutoUpdateRequested,
                  !appleDCTRequested,
                  stateMachine.negotiatedVersion?.isApple == true,
                  !appleDCTAutoUpdateActive,
                  receivedPortableFullFrame {
            pendingAppleDCTAutoUpdateActivation = true
            log.debug("Received initial portable framebuffer for adaptive updates")
        }

        if appleDCTRequested,
           stateMachine.negotiatedVersion?.isApple == true,
           !appleDCTAutoUpdateActive,
           rectsWithData.contains(where: { rect, payload in
               rect.encoding == .appleMultiVariantScreenshare
                   && payload.count >= 5
                   && payload[payload.startIndex + 4] == 0
                   && rect.x == 0 && rect.y == 0
                   && rect.width >= fbWidth && rect.height >= fbHeight
           }) {
            awaitingAppleDCTInitialReference = false
            pendingAppleDCTAutoUpdateActivation = true
            log.debug("Received complete initial Apple DCT reference image")
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if framebufferRequestSentNanos != 0 {
            let milliseconds = (now &- framebufferRequestSentNanos) / 1_000_000
            if milliseconds >= 100 {
                let payloadBytes = rectsWithData.reduce(0) { $0 + $1.1.count }
                let encodings = rectsWithData.map { String(describing: $0.0.encoding) }
                    .joined(separator: ",")
                log.info(
                    "Framebuffer server/network wait=\(milliseconds)ms "
                        + "rects=\(rectsWithData.count) payload=\(payloadBytes)B "
                        + "encodings=\(encodings)")
            }
            framebufferRequestSentNanos = 0
        }

        continuation?.yield(.framebufferUpdate(rectsWithData))

        // Pipeline the next incremental request the moment this update is
        // fully off the wire, so the server encodes the next frame while
        // this one crosses the event stream and decodes. Once an Apple
        // media stream offer arrives, stop requesting entirely: media
        // negotiation switches this channel to encrypted control records.
        let rects = rectsWithData.map(\.0)
        if requestAppleMediaStream,
           rects.contains(where: { $0.encoding == .mediaStreamOffer }) {
            framebufferRequestsSuppressed = true
            log.debug("Suppressing framebuffer update request after Apple media stream offer")
            return
        }
        guard !framebufferRequestsSuppressed else { return }

        unacknowledgedUpdates += 1
        let actions = stateMachine.handle(event: .receivedFramebufferUpdate(rects))
        for action in actions {
            if case .sendFramebufferUpdateRequest = action,
               unacknowledgedUpdates >= maxUnacknowledgedUpdates {
                deferredUpdateRequest = true
                continue
            }
            try await executeAction(action)
        }

        if appleDCTAutoUpdateActive || pendingAppleDCTAutoUpdateActivation {
            await waitForFramebufferCreditIfNeeded()
        }
    }

    /// Consume one complete Tight rectangle while retaining its compact wire
    /// framing for the renderer. A wrong byte count here desynchronizes the
    /// entire RFB stream, so derive the basic-filter payload size exactly as
    /// specified instead of scanning for the next message boundary.
    private func readTightRectanglePayload(rect: FramebufferRect) async throws -> Data {
        let controlData = try await tcp.read(exactly: 1)
        let control = controlData[controlData.startIndex]
        let compression = control >> 4
        var payload = controlData
        let tightPixelSize = pixelFormat.bitsPerPixel == 32
            && pixelFormat.depth == 24
            && pixelFormat.trueColor
            && pixelFormat.redMax == 255
            && pixelFormat.greenMax == 255
            && pixelFormat.blueMax == 255
            ? 3 : pixelFormat.bytesPerPixel

        switch compression {
        case 8: // Fill
            payload.append(try await tcp.read(exactly: tightPixelSize))

        case 9: // JPEG
            let (lengthBytes, length) = try await readTightCompactLength()
            payload.append(lengthBytes)
            if length > 0 { payload.append(try await tcp.read(exactly: length)) }

        case 0...7: // Basic compression, optionally with an explicit filter.
            var filter: UInt8 = 0
            if compression & 0x04 != 0 {
                let filterData = try await tcp.read(exactly: 1)
                filter = filterData[filterData.startIndex]
                payload.append(filterData)
            }

            let width = Int(rect.width)
            let height = Int(rect.height)
            let uncompressedSize: Int
            if filter == 1 {
                let paletteSizeData = try await tcp.read(exactly: 1)
                payload.append(paletteSizeData)
                let paletteSize = Int(paletteSizeData[paletteSizeData.startIndex]) + 1
                payload.append(try await tcp.read(exactly: paletteSize * tightPixelSize))
                uncompressedSize = paletteSize == 2
                    ? ((width + 7) / 8) * height
                    : width * height
            } else {
                uncompressedSize = width * height * tightPixelSize
            }

            if uncompressedSize < 12 {
                if uncompressedSize > 0 {
                    payload.append(try await tcp.read(exactly: uncompressedSize))
                }
            } else {
                let (lengthBytes, length) = try await readTightCompactLength()
                payload.append(lengthBytes)
                if length > 0 { payload.append(try await tcp.read(exactly: length)) }
            }

        default:
            throw VNCProtocolError.protocolViolation(
                "Unsupported Tight compression control \(compression)")
        }
        return payload
    }

    private func readTightCompactLength() async throws -> (Data, Int) {
        var bytes = Data()
        var value = 0
        for index in 0..<3 {
            let byteData = try await tcp.read(exactly: 1)
            let byte = byteData[byteData.startIndex]
            bytes.append(byte)
            value |= Int(byte & 0x7F) << (7 * index)
            if byte & 0x80 == 0 { return (bytes, value) }
        }
        return (bytes, value)
    }

    private func handleSetColorMapEntries() async throws {
        // padding(1) + firstColor(2) + numberOfColors(2) = 5 bytes
        let headerData = try await tcp.read(exactly: 5)
        let numColors = UInt16(headerData[headerData.startIndex + 3]) << 8
                      | UInt16(headerData[headerData.startIndex + 4])
        // Each color is 6 bytes (r,g,b as UInt16)
        let _ = try await tcp.read(exactly: Int(numColors) * 6)
        // Color map entries are passed through but not currently surfaced as session events
    }

    private func handleBell() async {
        let actions = stateMachine.handle(event: .receivedBell)
        for action in actions { await executeActionNoThrow(action) }
        continuation?.yield(.bell)
    }

    private func handleServerCutText() async throws {
        // padding(3) + length(4) = 7 bytes
        let headerData = try await tcp.read(exactly: 7)
        let length = UInt32(headerData[headerData.startIndex + 3]) << 24
                   | UInt32(headerData[headerData.startIndex + 4]) << 16
                   | UInt32(headerData[headerData.startIndex + 5]) << 8
                   | UInt32(headerData[headerData.startIndex + 6])

        let textData = try await tcp.read(exactly: Int(length))
        let text = String(data: textData, encoding: .utf8)
            ?? String(data: textData, encoding: .isoLatin1)
            ?? ""

        let actions = stateMachine.handle(event: .receivedServerCutText(text))
        for action in actions { await executeActionNoThrow(action) }
        continuation?.yield(.clipboardText(text))
    }

    // MARK: - Action execution

    /// Execute a list of ConnectionActions. Some are async (sending data), some are sync.
    ///
    /// Consecutive plain client messages (the post-ServerInit burst of
    /// SetPixelFormat + SetEncodings + first update request) are coalesced
    /// into one socket write so the server receives them in a single
    /// segment — the first framebuffer arrives one RTT sooner.
    private func executeActions(_ actions: [ConnectionAction]) async throws {
        var pending = Data()

        for action in actions {
            switch action {
            case .sendSetPixelFormat(let pf):
                pending.append(ClientMessage.setPixelFormat(pf).serialize())
                self.pixelFormat = pf
                log.debug("Queued SetPixelFormat")

            case .sendSetEncodings(let encodings):
                if requestAppleMediaStream && !sentAppleMediaStreamConfiguration {
                    if requestedDisplayCount > 1,
                       !sentAppleMediaInitialSetDisplay {
                        // Display selection must precede media message one.
                        // Otherwise only the first video receiver is created,
                        // and the desktops are combined into that receiver
                        // when the late SetDisplay arrives.
                        pending.append(appleSetDisplayMessage(
                            isGlobal: true,
                            displayID: 0))
                        sentAppleMediaInitialSetDisplay = true
                    }
                    pending.append(ClientMessage.setEncodings(encodings).serialize())
                    log.debug("Queued SetEncodings (\(encodings.count) encodings)")
                    if !pending.isEmpty {
                        try await sendClientPayload(pending)
                        pending = Data()
                    }
                    try await sendAppleMediaStreamSetupIfNeeded()
                } else {
                    pending.append(ClientMessage.setEncodings(encodings).serialize())
                    log.debug("Queued SetEncodings (\(encodings.count) encodings)")
                    if requestedDisplayCount > 1,
                       (appleServerCapabilities != nil
                           || stateMachine.negotiatedVersion?.isApple == true),
                       !sentAppleMediaInitialSetDisplay {
                    // Apple's Standard viewer sends SetDisplay in the initial
                    // client burst. SetDesktopSize changes monitor topology;
                    // it does not select which existing monitor(s) the server
                    // should encode. Byte 1 is the server's
                    // combineAllDisplaysFlag, so one display must explicitly
                    // clear it or the server keeps returning the composite.
                    pending.append(appleSetDisplayMessage(
                        isGlobal: requestedDisplayCount > 1,
                        displayID: 0))
                    sentAppleMediaInitialSetDisplay = true
                    }
                }

            case .sendFramebufferUpdateRequest(let incremental, let width, let height):
                pending.append(ClientMessage.framebufferUpdateRequest(
                    incremental: incremental,
                    x: 0, y: 0,
                    width: width,
                    height: height
                ).serialize())
                framebufferRequestSentNanos = DispatchTime.now().uptimeNanoseconds

            default:
                if !pending.isEmpty {
                    try await sendClientPayload(pending)
                    pending = Data()
                }
                try await executeAction(action)
            }
        }
        if !pending.isEmpty {
            try await sendClientPayload(pending)
        }
    }

    private func executeAction(_ action: ConnectionAction) async throws {
        switch action {
        case .sendProtocolVersion(let version):
            try await tcp.send(version.wireBytes())
            log.debug("Sent protocol version: \(version)")

        case .sendSecurityType(let type):
            if type == .macAuthentication {
                // Type 33: Don't send the type byte separately.
                // MacAuthenticator will combine it with the RSA1 request
                // in a single TCP write (macOS server requires this).
                securityTypeSentSeparately = false
                log.debug("Security type \(type) will be sent with first auth message")
            } else {
                try await tcp.send(Data([type.rawValue]))
                securityTypeSentSeparately = true
                log.debug("Sent security type: \(type)")
            }

        case .performAuthentication(let secType, _):
            try await performAuthentication(secType)

        case .sendAuthResponse(let data):
            try await tcp.send(data)

        case .requestServerInit:
            try await sendClientInit()

        case .sendSetPixelFormat(let pf):
            let msg = ClientMessage.setPixelFormat(pf)
            try await tcp.send(msg.serialize())
            self.pixelFormat = pf
            log.debug("Sent SetPixelFormat")

        case .sendSetEncodings(let encodings):
            let msg = ClientMessage.setEncodings(encodings)
            try await tcp.send(msg.serialize())
            log.debug("Sent SetEncodings (\(encodings.count) encodings)")
            if requestAppleMediaStream && !sentAppleMediaStreamConfiguration {
                try await sendAppleMediaStreamSetupIfNeeded()
            }

        case .sendFramebufferUpdateRequest(let incremental, let width, let height):
            let msg = ClientMessage.framebufferUpdateRequest(
                incremental: incremental,
                x: 0, y: 0,
                width: width,
                height: height
            )
            try await sendClientPayload(msg.serialize())
            framebufferRequestSentNanos = DispatchTime.now().uptimeNanoseconds

        case .updateFramebuffer:
            // Handled via the event stream, no additional action needed
            break

        case .notifyBell:
            continuation?.yield(.bell)

        case .notifyClipboard(let text):
            continuation?.yield(.clipboardText(text))

        case .reportError(let error):
            continuation?.yield(.error(error))

        case .disconnect:
            await stopAppleMediaUDP()
            await tcp.close()
            continuation?.yield(.disconnected)

        case .sendEncryptionResponse:
            // Encryption setup is handled separately when the pseudo-encoding is processed
            break

        case .sendMediaStreamAnswer(let answer):
            // Send the media stream answer as a pseudo-encoding response
            dumpAppleMediaClientRecordIfRequested(answer.wireBytes())
            try await tcp.send(answer.wireBytes())
            if answer.accepted {
                let isInitialAcceptance = !acceptedAppleMediaStream
                acceptedAppleMediaStream = true
                if isInitialAcceptance {
                    drainedAppleMediaControlBytes = 0
                    appleMediaControlBuffer.removeAll(keepingCapacity: true)
                    appleDecryptedRFBBuffer.removeAll(keepingCapacity: true)
                }
                emittedAppleMediaControlDiagnostics = 0
                appleMediaServerPacketID = 0
                appleMediaClientPacketID = 0
                sentAppleMediaPostAcceptViewerInfo = false
                sentAppleMediaPostAnswerViewerInfo = false
                sentAppleMediaAutoFrameUpdate = false
                rebuildAppleMediaSRTPContexts()
                if let key = appleSessionKey, appleEncryptedControlChannel == nil {
                    appleEncryptedControlChannel = try? AESCBCChannel(sendKey: key, recvKey: key)
                }
                try await sendAppleMediaPostAcceptEncodingsIfNeeded()
            }
            log.debug("Sent media stream answer for stream \(answer.streamID)")
        }
    }

    private func sendAppleMediaPostAcceptEncodingsIfNeeded() async throws {
        guard requestAppleMediaStream, !sentAppleMediaPostAcceptEncodings else { return }
        let payload = ClientMessage.setEncodings(appleMediaPostAcceptEncodings()).serialize()
        try await sendAppleEncryptedClientPayload(payload)
        sentAppleMediaPostAcceptEncodings = true
        log.debug("Sent Apple media post-accept SetEncodings length=\(payload.count)")
        try await sendAppleMediaPostAcceptViewerInfoIfNeeded()
    }

    private func sendAppleMediaPostAcceptViewerInfoIfNeeded() async throws {
        guard requestAppleMediaStream, !sentAppleMediaPostAcceptViewerInfo else { return }
        let payload = appleMediaStreamConfiguration(localPort: appleMediaConfigurationUDPPort())
        try await sendAppleEncryptedClientPayload(payload)
        sentAppleMediaPostAcceptViewerInfo = true
        log.debug("Sent Apple media post-accept viewer info length=\(payload.count)")
    }

    private func sendAppleMediaPostAnswerViewerInfoIfNeeded(for payload: Data) async throws {
        guard requestAppleMediaStream,
              isAppleAVCMediaAnswerPayload(payload) else { return }
        if let lengths = appleAVCMediaAnswerStreamLengths(payload) {
            appleMediaAnswerStreamLengths = lengths
            log.info(
                "Apple AVC message 2 accepted offer lengths "
                    + "audio=\(lengths[0]) video=\(lengths[1]) video2=\(lengths[2])")
        }
        _ = appleMediaGenerationTracker.finishMessageTwo()
        guard !sentAppleMediaPostAnswerViewerInfo else { return }
        let viewerInfo = appleMediaStreamConfiguration(localPort: appleMediaConfigurationUDPPort())
        try await sendAppleEncryptedClientPayload(viewerInfo)
        sentAppleMediaPostAnswerViewerInfo = true
        log.debug("Sent Apple media post-answer viewer info length=\(viewerInfo.count)")

    }

    private func applyStagedVirtualDisplayAfterInitialVideo() async {
        guard let pendingRemoteDisplaySize,
              appleServerCapabilities?.supportsServerCommand(
                AppleServerCapabilities.displayConfigurationCommand) == true else { return }
        do {
            log.info(
                "Initial Apple video source live; applying staged virtual display "
                    + "\(pendingRemoteDisplaySize.pixelWidth)x"
                    + "\(pendingRemoteDisplaySize.pixelHeight)")
            try await sendAppleVirtualDisplaySize(pendingRemoteDisplaySize)
        } catch {
            log.error(
                "Could not apply staged virtual display after initial video: "
                    + error.localizedDescription)
        }
    }

    private func applyQueuedVirtualDisplayAfterMediaReady() async {
        guard appleDisplayReconfigurationGeneration == nil,
              let pendingRemoteDisplaySize,
              pendingRemoteDisplaySize != lastSentRemoteDisplaySize else { return }
        do {
            log.info(
                "Media reconfiguration live; applying coalesced virtual display "
                    + "\(pendingRemoteDisplaySize.pixelWidth)x"
                    + "\(pendingRemoteDisplaySize.pixelHeight)")
            try await sendAppleVirtualDisplaySize(pendingRemoteDisplaySize)
        } catch {
            log.error(
                "Could not apply coalesced virtual display: "
                    + error.localizedDescription)
        }
    }

    private func appleMediaPostAcceptEncodings() -> [Encoding] {
        let nativeViewerEncodingRawValues: Set<Int32> = [
            0, 1, 6, 16,
            1000, 1001, 1002, 1010, 1011,
        ]
        // appleH264 (1010) selects the HEVC-over-UDP high-performance path.
        // This method is only reached for the native adaptive profile; public
        // Full Quality mode omits the media offer before a session is created.
        let baseEncodings = stateMachine.preferredEncodings.filter {
            nativeViewerEncodingRawValues.contains($0.rawValue)
        }

        return baseEncodings + [
            .cursor,
            .unknown(0x450),
            .unknown(0x44c),
            .desktopSize,
            .unknown(0x44d),
            .unknown(0x451),
            .unknown(0x453),
            .unknown(0x455),
            .unknown(0x456),
        ]
    }

    private func handleAppleMediaServerControlIfPresent(_ payload: Data) async throws -> Bool {
        guard let control = appleMediaServerControl(payload) else { return false }
        log.debug("Received Apple media server control encoding=0x\(String(control.encoding, radix: 16)) length=\(control.body.count)")
        if control.encoding == 0x450 {
            try await requestAppleMediaReconfigurationIfNeeded()
        } else if control.encoding == 0x451 {
            let displays = appleDisplayInfo2Records(control.body)
            if !displays.isEmpty {
                appleMediaDisplayInfos = displays
                appleMediaDisplayCount = requestsVirtualDisplays
                        && lastSentRemoteDisplaySize != nil
                    ? min(requestedDisplayCount, displays.count)
                    : 1
                for display in displays {
                    continuation?.yield(.displayInfo(display))
                }
                log.info(
                    "Apple media DisplayInfo2 announced \(displays.count) screens: "
                        + displays.map { "\($0.width)x\($0.height)" }
                            .joined(separator: ", "))
            }
        } else if control.encoding == 0x455 {
            try await sendAppleMediaInitialSetDisplayIfNeeded()
            try await sendAppleMediaAutoFrameUpdateIfNeeded()
        } else if control.encoding == 0x456 {
            try await sendAppleMediaInitialSetDisplayIfNeeded()
            try await sendAppleMediaAutoFrameUpdateIfNeeded()
            try await sendAppleMediaServerConfigurationIfNeeded()
        }
        return true
    }

    private func requestAppleMediaReconfigurationIfNeeded() async throws {
        guard requestAppleMediaStream,
              requestedDisplayCount > 1,
              appleDisplayReconfigurationGeneration != nil,
              !sentAppleMediaReconfigurationRequest else { return }
        sentAppleMediaReconfigurationRequest = true
        try await sendAppleEncryptedClientPayload(
            ClientMessage.appleMediaStreamRequest.serialize())
        log.info("Requested Apple media renegotiation for virtual displays")
    }

    private func sendAppleMediaInitialSetDisplayIfNeeded() async throws {
        guard !sentAppleMediaInitialSetDisplay else { return }
        if requestsVirtualDisplays {
            sentAppleMediaInitialSetDisplay = true
            return
        }
        let combinesAllDisplays: Bool
        switch runtimeEnvironment["ROOTSHELL_VNC_SET_DISPLAY_MODE"] {
        case "single": combinesAllDisplays = false
        case "global": combinesAllDisplays = true
        case "skip": return
        default: combinesAllDisplays = requestedDisplayCount > 1
        }
        let displayID: UInt32
        if combinesAllDisplays {
            displayID = 0
        } else {
            guard let firstDisplay = appleMediaDisplayInfos.first else {
                // DisplayInfo2 normally precedes 0x455/0x456. If it does not,
                // wait for a later control record rather than sending display
                // ID zero, which is not a portable alias for the main screen.
                return
            }
            displayID = firstDisplay.displayIndex
        }
        sentAppleMediaInitialSetDisplay = true
        try await sendAppleEncryptedClientPayload(appleSetDisplayMessage(
            isGlobal: combinesAllDisplays,
            displayID: displayID))
    }

    private func sendAppleStandardDisplaySelectionIfNeeded(
        displayID: UInt32
    ) async throws {
        guard !requestAppleMediaStream,
              requestedDisplayCount == 1,
              !sentAppleMediaInitialSetDisplay else { return }
        sentAppleMediaInitialSetDisplay = true
        // A non-global SetDisplay requires the server's real display ID. Zero
        // is not a portable synonym for the main monitor; the server validates
        // this UInt32 against its active display list.
        try await sendClientPayload(appleSetDisplayMessage(
            isGlobal: false,
            displayID: displayID))
    }

    private func appleSetDisplayMessage(isGlobal: Bool, displayID: UInt32) -> Data {
        var data = Data(count: 8)
        data[0] = 0x0d
        data[1] = isGlobal ? 1 : 0
        writeUInt32BE(displayID, into: &data, at: 4)
        return data
    }

    private func sendAppleMediaAutoFrameUpdateIfNeeded() async throws {
        guard !sentAppleMediaAutoFrameUpdate else { return }
        sentAppleMediaAutoFrameUpdate = true
        // The interval is a max-fps cap (0 = uncapped, 16 ≈ 62 fps); frame
        // delivery is change-gated regardless, so it does not affect idle bitrate.
        let interval = runtimeEnvironment["ROOTSHELL_VNC_AUTOFRAME_INTERVAL_MS"]
            .flatMap { Int32($0) } ?? 16
        try await sendAppleEncryptedClientPayload(appleAutoFrameUpdateMessage(intervalMilliseconds: interval))
    }

    private func sendAppleDCTAutoFrameUpdate() async throws {
        guard appleClassicAutoUpdateRequested,
              stateMachine.negotiatedVersion?.isApple == true else { return }
        try await sendClientPayload(
            appleAutoFrameUpdateMessage(
                intervalMilliseconds: 0))
        framebufferRequestSentNanos = DispatchTime.now().uptimeNanoseconds
    }

    private func startAppleDCTAutoUpdateRefreshTask() {
        guard appleDCTAutoUpdateRefreshTask == nil else { return }
        appleDCTAutoUpdateRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, let self else { return }
                    try await self.refreshAppleDCTAutoUpdate()
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    await self.logAppleDCTAutoUpdateRefreshFailure(error)
                }
            }
        }
    }

    private func refreshAppleDCTAutoUpdate() async throws {
        guard appleDCTAutoUpdateActive, !isDisconnecting else { return }
        try await sendAppleDCTAutoFrameUpdate()
    }

    private func logAppleDCTAutoUpdateRefreshFailure(_ error: Error) {
        log.warning(
            "Failed to renew Apple DCT auto updates: "
                + error.localizedDescription)
    }

    private func waitForFramebufferCreditIfNeeded() async {
        guard unacknowledgedUpdates >= maxUnacknowledgedUpdates else { return }
        await withCheckedContinuation { continuation in
            if unacknowledgedUpdates < maxUnacknowledgedUpdates {
                continuation.resume()
            } else {
                precondition(framebufferCreditWaiter == nil)
                framebufferCreditWaiter = continuation
            }
        }
    }

    private func resumeFramebufferCreditWaiterIfPossible() {
        guard unacknowledgedUpdates < maxUnacknowledgedUpdates,
              let waiter = framebufferCreditWaiter else { return }
        framebufferCreditWaiter = nil
        waiter.resume()
    }

    /// Commit server-announced geometry before any subsequent update request.
    /// An active Apple media subscription carries explicit capture bounds, so
    /// resend that same understood control message with the new dimensions;
    /// this keeps the existing media session and decoder timeline intact.
    private func acceptFramebufferResize(width: UInt16, height: UInt16) async throws {
        guard width > 0, height > 0 else { return }
        guard width != fbWidth || height != fbHeight else { return }

        let oldWidth = fbWidth
        let oldHeight = fbHeight
        fbWidth = width
        fbHeight = height
        log.info("Framebuffer resized \(oldWidth)x\(oldHeight) -> \(width)x\(height)")

        if appleDCTAutoUpdateActive {
            try await sendAppleDCTAutoFrameUpdate()
            log.debug("Updated Apple DCT frame subscription to \(width)x\(height)")
        }

        guard acceptedAppleMediaStream, sentAppleMediaAutoFrameUpdate else { return }
        let interval = runtimeEnvironment["ROOTSHELL_VNC_AUTOFRAME_INTERVAL_MS"]
            .flatMap { Int32($0) } ?? 16
        try await sendAppleEncryptedClientPayload(
            appleAutoFrameUpdateMessage(intervalMilliseconds: interval))
        log.debug("Updated Apple media frame subscription to \(width)x\(height)")
    }

    private func appleAutoFrameUpdateMessage(intervalMilliseconds: Int32) -> Data {
        ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: intervalMilliseconds,
            x: 0, y: 0,
            width: fbWidth, height: fbHeight).serialize()
    }

    private func noteStandardDesktopSizeSupport(
        _ layout: ExtendedDesktopSizePayload
    ) async throws {
        standardDesktopLayout = layout
        guard let pendingRemoteDisplaySize,
              appleServerCapabilities?.supportsServerCommand(
                AppleServerCapabilities.displayConfigurationCommand) != true else { return }
        try await sendStandardDesktopSize(pendingRemoteDisplaySize)
    }

    private func sendStandardDesktopSize(
        _ requested: PendingRemoteDisplaySize
    ) async throws {
        // SetDesktopSize changes the server's monitor topology; it is not a
        // display-selection mechanism. Keep Match Client to one screen and
        // select existing standard-mode displays in the presentation layer.
        let existing = standardDesktopLayout?.screens.first
        let screen = SetDesktopSizeScreen(
            id: existing?.id ?? 0,
            width: requested.pixelWidth,
            height: requested.pixelHeight,
            flags: existing?.flags ?? 0)
        let request = SetDesktopSizeRequest(
            width: requested.pixelWidth,
            height: requested.pixelHeight,
            screens: [screen])
        let message = ClientMessage.setDesktopSize(request)
        try await sendClientPayload(message.serialize())
        lastSentRemoteDisplaySize = requested
        pendingRemoteDisplaySize = nil
        appleRemoteDisplaySizeSink?(
            request.width,
            request.height)
        log.info(
            "Requested standard remote desktop \(request.width)x\(request.height)")
    }

    private func sendAppleVirtualDisplaySize(
        _ requested: PendingRemoteDisplaySize
    ) async throws {
        // The display command describes a 2× virtual display with both pixel
        // and point dimensions. A nominal 110 points/inch gives the virtual display
        // a stable physical size without affecting its explicit HiDPI mode.
        let millimetersPerPoint = Float(25.4 / 110.0)
        let mode = AppleVirtualDisplayMode(
            pixelWidth: UInt32(requested.pixelWidth),
            pixelHeight: UInt32(requested.pixelHeight),
            pointWidth: UInt32(requested.pointWidth),
            pointHeight: UInt32(requested.pointHeight))
        // These are fixed capability maxima, not the active mode or an active
        // resolution cap. The requested pixel/point pair below selects 2×.
        // The virtual encoder emits multiple tiles only above its capture
        // size threshold. Demanding them for a smaller Match Client window
        // completes control negotiation but creates no RTP source at all.
        activeAppleMediaTilesPerFrame = AppleMediaVideoMode.activeTileCount(
            pixelWidth: Int(requested.pixelWidth),
            pixelHeight: Int(requested.pixelHeight))
        let displays = (0..<requestedDisplayCount).map { index in
            AppleVirtualDisplay(
                name: requestedDisplayCount == 1
                    ? "rootshell Virtual Display"
                    : "rootshell Virtual Display \(index + 1)",
                widthInMillimeters: Float(requested.pointWidth) * millimetersPerPoint,
                heightInMillimeters: Float(requested.pointHeight) * millimetersPerPoint,
                maximumPixelWidth: appleVirtualDisplayMaximumPixelWidth,
                maximumPixelHeight: appleVirtualDisplayMaximumPixelHeight,
                originX: UInt16(Int(requested.pixelWidth) * index),
                identifier: UInt32(7 + index),
                modes: [mode])
        }
        let message = ClientMessage.appleDisplayConfiguration(
            AppleDisplayConfiguration(displays: displays))
        // The Apple media re-offer that follows command 29 is generated from
        // these session dimensions. ServerInit is not repeated for a virtual
        // display change, so retaining the physical framebuffer here would
        // advertise decoder geometry for the retired capture source.
        let previousWidth = fbWidth
        let previousHeight = fbHeight
        let previousDisplayCount = appleMediaDisplayCount
        fbWidth = requested.pixelWidth
        fbHeight = requested.pixelHeight
        appleMediaDisplayCount = displays.count
        if requestAppleMediaStream {
            appleDisplayReconfigurationGeneration =
                appleMediaGenerationTracker.generation &+ 1
            sentAppleMediaReconfigurationRequest = false
        }
        do {
            try await sendClientPayload(message.serialize())
        } catch {
            fbWidth = previousWidth
            fbHeight = previousHeight
            appleMediaDisplayCount = previousDisplayCount
            appleDisplayReconfigurationGeneration = nil
            throw error
        }
        lastSentRemoteDisplaySize = requested
        pendingRemoteDisplaySize = nil
        let aggregateWidth = UInt16(min(
            Int(UInt16.max),
            Int(requested.pixelWidth) * displays.count))
        appleRemoteDisplaySizeSink?(
            aggregateWidth,
            requested.pixelHeight)
        log.info(
            "Requested Apple dynamic virtual display \(requested.pixelWidth)x"
                + "\(requested.pixelHeight) pixels (\(requested.pointWidth)x"
                + "\(requested.pointHeight) points), count=\(displays.count)")
    }

    private nonisolated func appleMediaServerControl(_ payload: Data) -> (encoding: UInt16, body: Data)? {
        parseAppleMediaServerControl(payload, encodingOffset: 14)
            ?? parseAppleMediaServerControl(payload, encodingOffset: 16)
    }

    private nonisolated func parseAppleMediaServerControl(
        _ payload: Data,
        encodingOffset: Int
    ) -> (encoding: UInt16, body: Data)? {
        guard payload.count >= encodingOffset + 4 else { return nil }
        guard let encoding = readUInt16BE(payload, at: encodingOffset),
              let bodyLength = readUInt16BE(payload, at: encodingOffset + 2) else { return nil }

        let bodyStart = payload.startIndex + encodingOffset + 2
        let bodyEnd = bodyStart + Int(bodyLength)
        guard bodyEnd <= payload.endIndex else { return nil }

        switch encoding {
        case 0x450, 0x451, 0x453, 0x455, 0x456:
            return (encoding, Data(payload[bodyStart..<bodyEnd]))
        default:
            return nil
        }
    }

    private func sendClientPayload(_ payload: Data) async throws {
        if acceptedAppleMediaStream {
            traceAppleMediaClientPayload(label: "client encrypted payload", payload: payload)
            try await sendAppleEncryptedClientPayload(payload)
        } else {
            if requestAppleMediaStream {
                traceAppleMediaClientPayload(label: "client plaintext payload", payload: payload)
            }
            try await tcp.send(payload)
        }
    }

    private func sendAppleEncryptedClientPayload(_ payload: Data) async throws {
        dumpAppleMediaClientRecordIfRequested(payload)
        if let channel = appleMediaComCryptionChannel {
            let encrypted = try channel.encryptPayload(payload, packetID: appleMediaClientPacketID)
            appleMediaClientPacketID &+= 1
            guard encrypted.count <= Int(UInt16.max) else {
                throw VNCProtocolError.protocolViolation(
                    "Apple ComCryption client payload too large: \(encrypted.count) bytes")
            }

            var framed = Data(capacity: 2 + encrypted.count)
            framed.append(UInt8((encrypted.count >> 8) & 0xFF))
            framed.append(UInt8(encrypted.count & 0xFF))
            framed.append(encrypted)
            traceAppleMediaClientFrame(label: "client ComCryption frame", payload: payload, framed: framed)
            try await tcp.send(framed)
            return
        }

        try ensureAppleEncryptedControlChannel()
        guard let channel = appleEncryptedControlChannel else {
            throw VNCProtocolError.protocolViolation("Apple encrypted channel is unavailable")
        }

        let encrypted = try channel.encrypt(payload)
        guard encrypted.count <= Int(UInt16.max) else {
            throw VNCProtocolError.protocolViolation(
                "Apple encrypted client payload too large: \(encrypted.count) bytes")
        }

        var framed = Data(capacity: 2 + encrypted.count)
        framed.append(UInt8((encrypted.count >> 8) & 0xFF))
        framed.append(UInt8(encrypted.count & 0xFF))
        framed.append(encrypted)
        traceAppleMediaClientFrame(label: "client AES frame", payload: payload, framed: framed)
        try await tcp.send(framed)
    }

    private nonisolated func traceAppleMediaClientPayload(label: String, payload: Data) {
        guard runtimeEnvironment["ROOTSHELL_VNC_TRACE_APPLE_MEDIA_SEND"] == "1" else { return }
        print("Apple media send: \(label) payloadLength=\(payload.count) prefix=\(hexDump(payload.prefix(96)))")
    }

    private nonisolated func traceAppleMediaClientFrame(label: String, payload: Data, framed: Data) {
        guard runtimeEnvironment["ROOTSHELL_VNC_TRACE_APPLE_MEDIA_SEND"] == "1" else { return }
        print("Apple media send: \(label) payloadLength=\(payload.count) frameLength=\(framed.count) payloadPrefix=\(hexDump(payload.prefix(96))) framePrefix=\(hexDump(framed.prefix(96)))")
    }

    private nonisolated func hexDump(_ data: some Collection<UInt8>) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func ensureAppleEncryptedControlChannel() throws {
        guard appleEncryptedControlChannel == nil else { return }
        guard let key = appleSessionKey else {
            throw VNCProtocolError.protocolViolation("Apple session key is unavailable")
        }
        appleEncryptedControlChannel = try AESCBCChannel(sendKey: key, recvKey: key)
    }

    private func drainAppleMediaControlRecord() async throws {
        let chunk = try await tcp.read(upTo: 4096)
        dumpAppleMediaTCPChunkIfRequested(chunk)
        drainedAppleMediaControlBytes += chunk.count
        appleMediaControlBuffer.append(chunk)

        var plaintextPrefix: Data?
        var decryptError: String?

        if appleMediaComCryptionChannel != nil || appleEncryptedControlChannel != nil {
            while let encryptedRecord = nextAppleEncryptedControlRecord() {
                if appleMediaComCryptionChannel != nil {
                    do {
                        let record = try decryptAppleMediaComCryptionRecord(encryptedRecord)
                        dumpAppleMediaPlaintextIfRequested(record.payload)
                        dumpAppleMediaServerRecordIfRequested(record.payload)
                        plaintextPrefix = record.plaintextPrefix
                        decryptError = describeAppleMediaPlaintext(record.payload)
                        if try await handleAppleMediaServerControlIfPresent(record.payload) {
                            continue
                        }
                        let isAVCMediaRecord = findAppleAVCMediaMessage(
                            in: record.payload) != nil
                        _ = try await handleAppleAVCServerMediaMessageIfPresent(record.payload)
                        try await sendAppleMediaPostAnswerViewerInfoIfNeeded(for: record.payload)
                        let isRFBRecord = record.payload.first.map { first in
                            first == 0 || first == 2 || first == 3
                        } ?? false
                        if !isAVCMediaRecord, isRFBRecord {
                            appleDecryptedRFBBuffer.append(record.payload)
                            try await drainAppleDecryptedRFBBuffer()
                        }

                        let candidatePackets = extractAppleMediaRTPPackets(from: record.payload)
                        for packet in confirmedAppleMediaRTPPackets(from: candidatePackets) {
                            emitAppleMediaRTPPacket(packet)
                        }
                        continue
                    } catch {
                        if encryptedRecord.count >= 1024 {
                            decryptError = "Apple ComCryption: \(error.localizedDescription)"
                            continue
                        }
                    }
                }

                if let channel = appleEncryptedControlChannel {
                    do {
                        let plaintext = try channel.decrypt(encryptedRecord)
                        dumpAppleMediaServerRecordIfRequested(plaintext)
                        plaintextPrefix = Data(plaintext.prefix(64))
                        decryptError = describeAppleMediaPlaintext(plaintext)
                        if try await handleAppleMediaServerControlIfPresent(plaintext) {
                            continue
                        }
                        _ = try await handleAppleAVCServerMediaMessageIfPresent(plaintext)
                        try await sendAppleMediaPostAnswerViewerInfoIfNeeded(for: plaintext)
                        let candidatePackets = extractAppleMediaRTPPackets(from: plaintext)
                        for packet in confirmedAppleMediaRTPPackets(from: candidatePackets) {
                            emitAppleMediaRTPPacket(packet)
                        }
                    } catch {
                        decryptError = error.localizedDescription
                    }
                } else {
                    decryptError = "Apple encrypted channel is unavailable"
                }
            }

            if plaintextPrefix == nil, decryptError == nil {
                if let pendingLength = pendingAppleEncryptedRecordLength() {
                    decryptError = "waiting for encrypted record: buffered=\(appleMediaControlBuffer.count) expected=\(pendingLength)"
                } else if let channel = appleEncryptedControlChannel,
                          let candidate = tryAppleMediaBlockStreamDecrypt(channel: channel) {
                    plaintextPrefix = candidate.plaintextPrefix
                    decryptError = candidate.diagnostic
                } else {
                    decryptError = describeAppleMediaEncryptedBuffer()
                }
            }

            if appleMediaControlBuffer.count > appleMediaControlBufferLimit {
                let retained = Data(appleMediaControlBuffer.suffix(4096))
                appleMediaControlBuffer = retained
                if decryptError == nil {
                    decryptError = "buffer exceeded \(appleMediaControlBufferLimit) bytes without a complete encrypted record"
                }
            }
        }

        emitAppleMediaControlDiagnostic(
            encryptedLength: chunk.count,
            encryptedPrefix: Data(chunk.prefix(64)),
            plaintextPrefix: plaintextPrefix,
            decryptError: decryptError
        )
        latestAppleMediaControlDiagnostic = decryptError

        if drainedAppleMediaControlBytes <= 4096 {
            log.debug("Drained Apple media TCP control stream chunk \(chunk.count) bytes")
        }
    }

    private func drainAppleDecryptedRFBBuffer() async throws {
        while true {
            guard appleDecryptedRFBBuffer.count >= 1 else { return }
            let base = appleDecryptedRFBBuffer.startIndex
            let messageType = appleDecryptedRFBBuffer[base]

            switch messageType {
            case 0:
                guard try await drainAppleDecryptedFramebufferUpdate() else { return }
            case 2:
                appleDecryptedRFBBuffer.removeSubrange(base..<base + 1)
                continuation?.yield(.bell)
            case 3:
                guard try drainAppleDecryptedServerCutText() else { return }
            default:
                return
            }
        }
    }

    private func drainAppleDecryptedFramebufferUpdate() async throws -> Bool {
        let base = appleDecryptedRFBBuffer.startIndex
        guard base + 4 <= appleDecryptedRFBBuffer.endIndex else { return false }

        let rectCount = Int(UInt16(appleDecryptedRFBBuffer[base + 2]) << 8
            | UInt16(appleDecryptedRFBBuffer[base + 3]))
        var offset = base + 4
        var rectsWithData: [(FramebufferRect, Data)] = []
        rectsWithData.reserveCapacity(rectCount)
        var pendingResize: FramebufferRect?

        for _ in 0..<rectCount {
            guard offset + FramebufferRect.wireSize <= appleDecryptedRFBBuffer.endIndex else { return false }
            var reader = MessageReader(data: Data(appleDecryptedRFBBuffer[offset..<offset + FramebufferRect.wireSize]))
            let rect = try FramebufferRect(reader: &reader)
            offset += FramebufferRect.wireSize

            let pixelDataLength: Int
            switch rect.encoding {
            case .raw:
                pixelDataLength = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
            case .zlib, .zrle:
                guard offset + 4 <= appleDecryptedRFBBuffer.endIndex else { return false }
                let b0 = UInt32(appleDecryptedRFBBuffer[offset]) << 24
                let b1 = UInt32(appleDecryptedRFBBuffer[offset + 1]) << 16
                let b2 = UInt32(appleDecryptedRFBBuffer[offset + 2]) << 8
                let b3 = UInt32(appleDecryptedRFBBuffer[offset + 3])
                let compressedLength = Int(b0 | b1 | b2 | b3)
                pixelDataLength = 4 + compressedLength
            case .copyRect:
                pixelDataLength = 4
            case .desktopSize:
                pixelDataLength = 0
            case .extendedDesktopSize:
                guard offset + ExtendedDesktopSizePayload.headerWireSize
                        <= appleDecryptedRFBBuffer.endIndex else { return false }
                pixelDataLength = ExtendedDesktopSizePayload.wireSize(
                    screenCount: appleDecryptedRFBBuffer[offset])
            case .mediaStreamOffer:
                pixelDataLength = AppleMediaStreamOffer.wirePayloadSize
            case .encryptionInfo, .serverDisplayInfo, .mediaStreamAnswer:
                pixelDataLength = 0
            case .cursor:
                let pixelBytes = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
                let maskBytes = Int((Int(rect.width) + 7) / 8) * Int(rect.height)
                pixelDataLength = pixelBytes + maskBytes
            default:
                return false
            }

            guard offset + pixelDataLength <= appleDecryptedRFBBuffer.endIndex else { return false }
            let pixelData = Data(appleDecryptedRFBBuffer[offset..<offset + pixelDataLength])
            offset += pixelDataLength
            if rect.encoding == .extendedDesktopSize {
                let layout = try ExtendedDesktopSizePayload(data: pixelData)
                try await noteStandardDesktopSizeSupport(layout)
            } else if rect.encoding == .mediaStreamOffer {
                try await handleAppleMediaStreamOfferPayload(pixelData)
            }
            rectsWithData.append((rect, pixelData))
            if rect.isSuccessfulDesktopResize {
                pendingResize = rect
            }
        }

        appleDecryptedRFBBuffer.removeSubrange(base..<offset)
        if let resize = pendingResize {
            try await acceptFramebufferResize(width: resize.width, height: resize.height)
        }
        continuation?.yield(.framebufferUpdate(rectsWithData))
        return true
    }

    private func handleAppleMediaStreamOfferPayload(_ offerData: Data) async throws {
        var offerReader = MessageReader(data: offerData)
        let offer = try AppleMediaStreamOffer(reader: &offerReader)
        if !isAppleMediaComCryptionTransition(offer.rawPayload) {
            // DisplayInfo2 is authoritative for the stream display count; keep
            // the offer-field interpretation only for old virtual-display servers.
            if appleMediaDisplayInfos.isEmpty,
               requestsVirtualDisplays {
                appleMediaDisplayCount = selectedAppleMediaDisplayCount(
                    offered: offer.videoStreamDisplayCount,
                    requested: requestedDisplayCount)
            }
            appleMediaSupportsHDR = offer.videoStream1Flags.map { flags in
                flags & 0x02 != 0
            } ?? false
        }
        try configureAppleMediaComCryptionIfPresent(offer.rawPayload)
        try await configureAppleMediaUDP(for: offer)
        continuation?.yield(.mediaStreamOffer(offer))
        let actions = stateMachine.handle(event: .receivedMediaStreamOffer(offer))
        try await executeActions(actions)
    }

    private func drainAppleDecryptedServerCutText() throws -> Bool {
        let base = appleDecryptedRFBBuffer.startIndex
        guard base + 8 <= appleDecryptedRFBBuffer.endIndex else { return false }
        let length = Int(UInt32(appleDecryptedRFBBuffer[base + 4]) << 24
            | UInt32(appleDecryptedRFBBuffer[base + 5]) << 16
            | UInt32(appleDecryptedRFBBuffer[base + 6]) << 8
            | UInt32(appleDecryptedRFBBuffer[base + 7]))
        guard base + 8 + length <= appleDecryptedRFBBuffer.endIndex else { return false }

        let textData = Data(appleDecryptedRFBBuffer[base + 8..<base + 8 + length])
        let text = String(data: textData, encoding: .utf8)
            ?? String(data: textData, encoding: .isoLatin1)
            ?? ""
        appleDecryptedRFBBuffer.removeSubrange(base..<base + 8 + length)
        continuation?.yield(.clipboardText(text))
        return true
    }

    private func configureAppleMediaComCryptionIfPresent(_ payload: Data) throws {
        guard isAppleMediaComCryptionTransition(payload) else { return }

        let base = payload.startIndex
        let encryptedKey = Data(payload[base + 4..<base + 20])
        let encryptedIV = Data(payload[base + 20..<base + 36])
        guard !encryptedKey.allSatisfy({ $0 == 0 }),
              !encryptedIV.allSatisfy({ $0 == 0 }) else {
            return
        }

        try ensureAppleEncryptedControlChannel()
        guard let channel = appleEncryptedControlChannel else {
            throw VNCProtocolError.protocolViolation(
                "Apple encrypted channel is unavailable")
        }
        let key = try channel.decryptECBBlock(encryptedKey)
        let iv = try channel.decryptECBBlock(encryptedIV)
        applePreviousMediaComCryptionChannel = appleMediaComCryptionChannel
        applePreviousMediaServerPacketID = appleMediaServerPacketID
        appleMediaComCryptionChannel = try AppleComCryptionChannel(key: key, iv: iv)
        appleMediaServerPacketID = 0
        appleMediaClientPacketID = 0
        // Encrypted session: SRTP keys will follow on the control channel, so
        // early media datagrams must be buffered, not dropped as undecryptable.
        appleMediaExpectsSRTP = true
        log.debug("Configured Apple media ComCryption from 0x44f encryption info")
    }

    private nonisolated func isAppleMediaComCryptionTransition(_ payload: Data) -> Bool {
        guard payload.count >= 36 else { return false }
        let base = payload.startIndex
        let mode = UInt32(payload[base]) << 24
            | UInt32(payload[base + 1]) << 16
            | UInt32(payload[base + 2]) << 8
            | UInt32(payload[base + 3])
        return mode == 1
    }

    private func decryptAppleMediaComCryptionRecord(
        _ encryptedRecord: Data
    ) throws -> AppleComCryptionChannel.Record {
        if let previous = applePreviousMediaComCryptionChannel {
            do {
                let record = try previous.decryptRecord(
                    encryptedRecord,
                    expectedPacketID: applePreviousMediaServerPacketID)
                applePreviousMediaServerPacketID = record.packetID &+ 1
                return record
            } catch {
                // Old-channel records are contiguous. Its first authentication
                // failure is the generation boundary; discard the now-advanced
                // CBC state and try the untouched replacement channel.
                applePreviousMediaComCryptionChannel = nil
            }
        }
        guard let channel = appleMediaComCryptionChannel else {
            throw VNCProtocolError.protocolViolation("Apple media ComCryption channel is unavailable")
        }

        let record = try channel.decryptRecord(encryptedRecord, expectedPacketID: appleMediaServerPacketID)
        appleMediaServerPacketID = record.packetID &+ 1
        return record
    }

    private nonisolated func dumpAppleMediaTCPChunkIfRequested(_ chunk: Data) {
        guard let path = runtimeEnvironment["ROOTSHELL_VNC_DUMP_MEDIA_TCP"] else {
            return
        }
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: chunk)
            try? handle.close()
        } else {
            try? chunk.write(to: URL(fileURLWithPath: path))
        }
    }

    private nonisolated func dumpAppleMediaPlaintextIfRequested(_ payload: Data) {
        guard let path = runtimeEnvironment["ROOTSHELL_VNC_DUMP_MEDIA_PLAINTEXT"] else {
            return
        }
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
            try? handle.close()
        } else {
            try? payload.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Append each decrypted server control record to a file, length-framed
    /// (4-byte big-endian length prefix + payload) so individual records can be
    /// split back out. Use to capture the exact server->client media-config
    /// records (0x451/0x455/0x456 and the AVC media message) from a real server.
    private nonisolated func dumpAppleMediaServerRecordIfRequested(_ payload: Data) {
        guard let path = runtimeEnvironment["ROOTSHELL_VNC_DUMP_SERVER_RECORDS"] else {
            return
        }
        let framed = appleMediaDumpFrame(direction: 0x53 /* 'S' */, payload: payload)
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: framed)
            try? handle.close()
        } else {
            try? framed.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Frame a dumped media record: [dir:1][monotonic ns:8 BE][len:4 BE][payload].
    /// The timestamp lets the client- and server-record dumps be merge-sorted
    /// into the exact bidirectional wire order.
    private nonisolated func appleMediaDumpFrame(direction: UInt8, payload: Data) -> Data {
        let ts = DispatchTime.now().uptimeNanoseconds
        let count = UInt32(payload.count)
        var framed = Data([direction])
        for shift in stride(from: 56, through: 0, by: -8) {
            framed.append(UInt8((ts >> UInt64(shift)) & 0xff))
        }
        for shift in [24, 16, 8, 0] {
            framed.append(UInt8((count >> UInt32(shift)) & 0xff))
        }
        framed.append(payload)
        return framed
    }

    /// Append each outgoing client media record (plaintext, before encryption)
    /// to a file, length-framed, so the full bidirectional media negotiation
    /// order can be reconstructed alongside the server-record dump.
    private nonisolated func dumpAppleMediaClientRecordIfRequested(_ payload: Data) {
        guard let path = runtimeEnvironment["ROOTSHELL_VNC_DUMP_CLIENT_RECORDS"] else {
            return
        }
        let framed = appleMediaDumpFrame(direction: 0x43 /* 'C' */, payload: payload)
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: framed)
            try? handle.close()
        } else {
            try? framed.write(to: URL(fileURLWithPath: path))
        }
    }

    private func tryAppleMediaBlockStreamDecrypt(
        channel: AESCBCChannel
    ) -> (plaintextPrefix: Data, diagnostic: String)? {
        guard appleMediaControlBuffer.count >= 32 else { return nil }

        for offset in 0..<min(16, appleMediaControlBuffer.count) {
            let start = appleMediaControlBuffer.startIndex + offset
            let candidateLength = appleMediaControlBuffer.endIndex - start
            guard candidateLength >= 32, candidateLength % 16 == 0 else { continue }

            let encrypted = Data(appleMediaControlBuffer[start..<appleMediaControlBuffer.endIndex])
            guard let plaintext = try? channel.decryptNoPadding(encrypted) else { continue }

            let candidatePackets = extractAppleMediaRTPPackets(from: plaintext)
            let packets = confirmedAppleMediaRTPPackets(from: candidatePackets)
            for packet in packets {
                emitAppleMediaRTPPacket(packet)
            }

            let diagnostic = describeAppleMediaPlaintext(plaintext)
                ?? "plaintext scan: \(plaintext.count) bytes"
            if !packets.isEmpty {
                appleMediaControlBuffer.removeSubrange(
                    appleMediaControlBuffer.startIndex..<appleMediaControlBuffer.endIndex)
                return (Data(plaintext.prefix(64)), "block stream offset=\(offset) \(diagnostic)")
            }

            if looksLikeAppleMediaPlaintext(plaintext) {
                return (Data(plaintext.prefix(64)), "block stream offset=\(offset) \(diagnostic)")
            }
        }

        return nil
    }

    private func pendingAppleEncryptedRecordLength() -> Int? {
        guard appleMediaControlBuffer.count >= 2 else { return nil }
        let base = appleMediaControlBuffer.startIndex
        let length = Int(UInt16(appleMediaControlBuffer[base]) << 8
            | UInt16(appleMediaControlBuffer[base + 1]))
        guard length >= 32, length % 16 == 0 else { return nil }
        let totalLength = 2 + length
        return appleMediaControlBuffer.count < totalLength ? totalLength : nil
    }

    private func looksLikeAppleMediaPlaintext(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(min(data.count, 512)))
        for offset in bytes.indices where offset + 12 <= bytes.count {
            if bytes[offset] == 0x80 || bytes[offset] == 0x90 {
                let payloadType = bytes[offset + 1] & 0x7F
                if payloadType >= 96 {
                    return true
                }
            }
        }
        return false
    }

    private func nextAppleEncryptedControlRecord() -> Data? {
        while appleMediaControlBuffer.count >= 2 {
            let base = appleMediaControlBuffer.startIndex
            let length = Int(UInt16(appleMediaControlBuffer[base]) << 8
                | UInt16(appleMediaControlBuffer[base + 1]))

            guard length >= 32,
                  length <= UInt16.max,
                  length % 16 == 0 else {
                return nil
            }

            let recordEnd = base + 2 + length
            guard recordEnd <= appleMediaControlBuffer.endIndex else {
                return nil
            }

            let encrypted = Data(appleMediaControlBuffer[base + 2..<recordEnd])
            appleMediaControlBuffer.removeSubrange(base..<recordEnd)
            return encrypted
        }

        return nil
    }

    private func describeAppleMediaEncryptedBuffer() -> String {
        guard !appleMediaControlBuffer.isEmpty else {
            return "encrypted stream scan: empty buffer"
        }

        let bytes = [UInt8](appleMediaControlBuffer.prefix(min(appleMediaControlBuffer.count, 2048)))
        let firstU16: String
        if bytes.count >= 2 {
            let value = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            firstU16 = "\(value)"
        } else {
            firstU16 = "n/a"
        }

        let firstU32: String
        if bytes.count >= 4 {
            let value = UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
            firstU32 = "\(value)"
        } else {
            firstU32 = "n/a"
        }

        var rawRTPOffsets: [String] = []
        for offset in bytes.indices where offset + 12 <= bytes.count && (bytes[offset] == 0x80 || bytes[offset] == 0x90) {
            let payloadType = bytes[offset + 1] & 0x7F
            if payloadType >= 96 {
                let sequence = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
                rawRTPOffsets.append("@\(offset):pt=\(payloadType),seq=\(sequence)")
                if rawRTPOffsets.count == 4 { break }
            }
        }

        return "encrypted stream scan: buffered=\(appleMediaControlBuffer.count) "
            + "firstU16=\(firstU16) firstU32=\(firstU32) "
            + "blockAligned=\(appleMediaControlBuffer.count % 16 == 0) "
            + "rawRTP=\(rawRTPOffsets.isEmpty ? "none" : rawRTPOffsets.joined(separator: ";"))"
    }

    private func describeAppleMediaPlaintext(_ data: Data) -> String? {
        if let mediaControlDescription = describeAppleAVCMediaControlPlaintext(data) {
            return mediaControlDescription
        }
        if let control = appleMediaServerControl(data) {
            return "Apple media server control: encoding=0x\(String(control.encoding, radix: 16)) bodyLength=\(control.body.count)"
        }
        if let shortControlDescription = describeAppleMediaShortControlPayload(data) {
            return shortControlDescription
        }

        guard data.count >= 12 else {
            return "plaintext scan: too short for RTP"
        }

        let bytes = [UInt8](data.prefix(min(data.count, 2048)))
        var rtpOffsets: [String] = []
        for offset in bytes.indices where offset + 12 <= bytes.count && (bytes[offset] & 0xC0) == 0x80 {
            let payloadType = bytes[offset + 1] & 0x7F
            let sequence = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
            let timestamp = UInt32(bytes[offset + 4]) << 24
                | UInt32(bytes[offset + 5]) << 16
                | UInt32(bytes[offset + 6]) << 8
                | UInt32(bytes[offset + 7])
            rtpOffsets.append("@\(offset):pt=\(payloadType),seq=\(sequence),ts=\(timestamp)")
            if rtpOffsets.count == 4 { break }
        }

        var framedOffsets: [String] = []
        for offset in bytes.indices {
            if offset + 2 + 12 <= bytes.count {
                let length = Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
                let start = offset + 2
                if length >= 12,
                   start + length <= bytes.count,
                   (bytes[start] & 0xC0) == 0x80 {
                    framedOffsets.append("u16@\(offset):len=\(length)")
                }
            }
            if offset + 4 + 12 <= bytes.count {
                let length = Int(UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3]))
                let start = offset + 4
                if length >= 12,
                   length <= 4096,
                   start + length <= bytes.count,
                   (bytes[start] & 0xC0) == 0x80 {
                    framedOffsets.append("u32@\(offset):len=\(length)")
                }
            }
            if framedOffsets.count == 4 { break }
        }

        var parts = ["plaintext scan: \(data.count) bytes"]
        parts.append("rtpOffsets=\(rtpOffsets.isEmpty ? "none" : rtpOffsets.joined(separator: ";"))")
        parts.append("framed=\(framedOffsets.isEmpty ? "none" : framedOffsets.joined(separator: ";"))")
        return parts.joined(separator: " ")
    }

    private nonisolated func describeAppleMediaShortControlPayload(_ data: Data) -> String? {
        guard data.count == 8 else { return nil }
        let bytes = [UInt8](data)
        let messageType = bytes[0]
        guard messageType == 0x14 else { return nil }

        let field1 = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let field2 = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        let field3 = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        return "Apple media short control: type=0x14 field1=\(field1) field2=\(field2) field3=\(field3)"
    }

    private func describeAppleAVCMediaControlPlaintext(_ data: Data) -> String? {
        guard data.count >= 36 else { return nil }

        let plistMagic = Data("bplist00".utf8)
        let plistOffsets = ranges(of: plistMagic, in: data).map(\.lowerBound)
        guard !plistOffsets.isEmpty else { return nil }

        let firstPlistOffset = plistOffsets[0]
        let messageType = readUInt16BE(data, at: firstPlistOffset - 18)
        let streamCount = readUInt16BE(data, at: firstPlistOffset - 16)
        let prefixLength = readUInt16BE(data, at: 0)

        var parts = [
            "AVC media control: \(data.count) bytes",
            "prefixLength=\(prefixLength.map(String.init) ?? "n/a")",
            "messageType=\(messageType.map(String.init) ?? "n/a")",
            "streams=\(streamCount.map(String.init) ?? "n/a")",
            "plistOffsets=\(plistOffsets.map(String.init).joined(separator: ","))",
        ]

        var parsedEnd = data.startIndex
        for (index, offset) in plistOffsets.enumerated() {
            let upperBound = index + 1 < plistOffsets.count ? plistOffsets[index + 1] : data.endIndex
            guard let range = validPropertyListRange(in: data, from: offset, upperBound: upperBound) else {
                parts.append("plist\(index)=invalid")
                continue
            }
            parsedEnd = max(parsedEnd, range.upperBound)
            parts.append("plist\(index)=\(describeAVCAnswerPlist(Data(data[range])))")
        }

        if parsedEnd < data.endIndex {
            parts.append("trailerBytes=\(data.distance(from: parsedEnd, to: data.endIndex))")
        }

        return parts.joined(separator: " ")
    }

    private func isAppleAVCMediaAnswerPayload(_ data: Data) -> Bool {
        guard data.count >= 36 else { return false }
        let plistMagic = Data("bplist00".utf8)
        guard let firstPlistOffset = ranges(of: plistMagic, in: data).first?.lowerBound,
              let messageType = readUInt16BE(data, at: firstPlistOffset - 18) else {
            return false
        }
        return messageType == 2
    }

    private nonisolated func appleAVCMediaAnswerStreamLengths(_ payload: Data) -> [Int]? {
        guard let message = findAppleAVCMediaMessage(in: payload),
              message.messageType == 2,
              let audio = readUInt16BE(message.body, at: 8),
              let video = readUInt16BE(message.body, at: 10),
              let video2 = readUInt16BE(message.body, at: 12) else {
            return nil
        }
        return [Int(audio), Int(video), Int(video2)]
    }

    private nonisolated func validPropertyListRange(
        in data: Data,
        from offset: Data.Index,
        upperBound: Data.Index
    ) -> Range<Data.Index>? {
        guard offset < upperBound else { return nil }
        if (try? PropertyListSerialization.propertyList(
            from: Data(data[offset..<upperBound]),
            options: [],
            format: nil
        )) != nil {
            return offset..<upperBound
        }

        var end = upperBound
        while data.distance(from: offset, to: end) >= 8 {
            if (try? PropertyListSerialization.propertyList(
                from: Data(data[offset..<end]),
                options: [],
                format: nil
            )) != nil {
                return offset..<end
            }
            end = data.index(before: end)
        }
        return nil
    }

    private nonisolated func describeAVCAnswerPlist(_ data: Data) -> String {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return "invalidPlist(\(data.count) bytes)"
        }

        let mediaBlobLength = (plist["avcMediaStreamNegotiatorMediaBlob"] as? Data)?.count
        let endpointLength = (plist["avcMediaStreamOptionRemoteEndpointInfo"] as? Data)?.count
        let mode = plist["avcMediaStreamNegotiatorMode"] as? Int
        var fields: [String] = ["plistBytes=\(data.count)"]
        if let mediaBlobLength { fields.append("mediaBlob=\(mediaBlobLength)") }
        if let endpointLength { fields.append("endpoint=\(endpointLength)") }
        if let mode { fields.append("mode=\(mode)") }
        return fields.joined(separator: ",")
    }

    private nonisolated func ranges(of needle: Data, in haystack: Data) -> [Range<Data.Index>] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var ranges: [Range<Data.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack[searchStart..<haystack.endIndex].range(of: needle) {
            ranges.append(range)
            searchStart = range.lowerBound + 1
        }
        return ranges
    }

    private nonisolated func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }
        let index = data.startIndex + offset
        return UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }

    private func confirmedAppleMediaRTPPackets(from packets: [Data]) -> [Data] {
        var confirmedPackets: [Data] = []

        for packet in packets {
            guard let header = parseAppleMediaRTPHeader(packet) else { continue }

            if var stream = confirmedAppleMediaRTPStream {
                guard header.ssrc == stream.ssrc,
                      header.payloadType == stream.payloadType,
                      isPlausibleNextRTPSequence(header.sequenceNumber, after: stream.lastSequenceNumber) else {
                    continue
                }

                stream.lastSequenceNumber = header.sequenceNumber
                confirmedAppleMediaRTPStream = stream
                confirmedPackets.append(packet)
                continue
            }

            if var pending = pendingAppleMediaRTPStream,
               header.ssrc == pending.ssrc,
               header.payloadType == pending.payloadType,
               isPlausibleNextRTPSequence(header.sequenceNumber, after: pending.lastSequenceNumber) {
                pending.lastSequenceNumber = header.sequenceNumber
                pending.packets.append(packet)

                if pending.packets.count >= 2 {
                    confirmedAppleMediaRTPStream = ConfirmedAppleMediaRTPStream(
                        payloadType: pending.payloadType,
                        ssrc: pending.ssrc,
                        lastSequenceNumber: pending.lastSequenceNumber
                    )
                    confirmedPackets.append(contentsOf: pending.packets)
                    pendingAppleMediaRTPStream = nil
                } else {
                    pendingAppleMediaRTPStream = pending
                }
            } else {
                pendingAppleMediaRTPStream = PendingAppleMediaRTPStream(
                    payloadType: header.payloadType,
                    ssrc: header.ssrc,
                    lastSequenceNumber: header.sequenceNumber,
                    packets: [packet]
                )
            }
        }

        return confirmedPackets
    }

    private func isPlausibleNextRTPSequence(_ sequence: UInt16, after previous: UInt16) -> Bool {
        let distance = sequence &- previous
        return distance > 0 && distance < 256
    }

    private func extractAppleMediaRTPPackets(from data: Data) -> [Data] {
        if looksLikeRTPPacket(data) {
            return [data]
        }

        for offset in 0...min(16, data.count) {
            let start = data.startIndex + offset
            if let packets = parseLengthPrefixedAppleMediaPackets(data[start..<data.endIndex], lengthByteCount: 2),
               !packets.isEmpty {
                return packets
            }
            if let packets = parseLengthPrefixedAppleMediaPackets(data[start..<data.endIndex], lengthByteCount: 4),
               !packets.isEmpty {
                return packets
            }
        }

        return []
    }

    private func parseLengthPrefixedAppleMediaPackets(
        _ slice: Data.SubSequence,
        lengthByteCount: Int
    ) -> [Data]? {
        guard lengthByteCount == 2 || lengthByteCount == 4 else { return nil }

        var packets: [Data] = []
        var offset = slice.startIndex

        while offset < slice.endIndex {
            guard offset + lengthByteCount <= slice.endIndex else { return nil }

            let length: Int
            if lengthByteCount == 2 {
                length = Int(UInt16(slice[offset]) << 8 | UInt16(slice[offset + 1]))
            } else {
                length = Int(UInt32(slice[offset]) << 24
                    | UInt32(slice[offset + 1]) << 16
                    | UInt32(slice[offset + 2]) << 8
                    | UInt32(slice[offset + 3]))
            }

            guard length >= 12, length <= 16_384 else { return nil }
            let packetStart = offset + lengthByteCount
            let packetEnd = packetStart + length
            guard packetEnd <= slice.endIndex else { return nil }

            let packet = Data(slice[packetStart..<packetEnd])
            guard looksLikeRTPPacket(packet) else { return nil }
            packets.append(packet)
            offset = packetEnd
        }

        return offset == slice.endIndex ? packets : nil
    }

    private func looksLikeRTPPacket(_ data: Data) -> Bool {
        parseAppleMediaRTPHeader(data) != nil
    }

    private func parseAppleMediaRTPHeader(_ data: Data) -> AppleMediaRTPHeader? {
        guard data.count >= 12 else { return nil }
        let base = data.startIndex
        // This RTP/SRTP profile uses the minimal RTP header
        // (`0x80`) and payload type in the dynamic/video range. A loose
        // version-bit check has too many false positives in encrypted media.
        guard data[base] == 0x80 || data[base] == 0x90 else { return nil }

        let csrcCount = Int(data[base] & 0x0F)
        let hasExtension = (data[base] >> 4) & 0x01 == 1
        let payloadType = data[base + 1] & 0x7F
        guard payloadType >= 96 else { return nil }

        var payloadOffset = 12 + csrcCount * 4
        guard data.count >= payloadOffset else { return nil }

        if hasExtension {
            guard data.count >= payloadOffset + 4 else { return nil }
            let extensionLength = Int(UInt16(data[base + payloadOffset + 2]) << 8
                | UInt16(data[base + payloadOffset + 3]))
            payloadOffset += 4 + extensionLength * 4
            guard data.count >= payloadOffset else { return nil }
        }

        guard data.count > payloadOffset else { return nil }

        let sequenceNumber = UInt16(data[base + 2]) << 8
            | UInt16(data[base + 3])
        let timestamp = UInt32(data[base + 4]) << 24
            | UInt32(data[base + 5]) << 16
            | UInt32(data[base + 6]) << 8
            | UInt32(data[base + 7])
        let ssrc = UInt32(data[base + 8]) << 24
            | UInt32(data[base + 9]) << 16
            | UInt32(data[base + 10]) << 8
            | UInt32(data[base + 11])

        return AppleMediaRTPHeader(
            payloadType: payloadType,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            ssrc: ssrc,
            marker: (data[base + 1] & 0x80) != 0
        )
    }

    private func emitAppleMediaControlDiagnostic(
        encryptedLength: Int,
        encryptedPrefix: Data,
        plaintextPrefix: Data?,
        decryptError: String?
    ) {
        guard emittedAppleMediaControlDiagnostics < 8 else { return }
        emittedAppleMediaControlDiagnostics += 1
        continuation?.yield(.appleMediaControlRecord(
            encryptedLength: encryptedLength,
            encryptedPrefix: encryptedPrefix,
            plaintextPrefix: plaintextPrefix,
            decryptError: decryptError
        ))
    }

    /// Execute an action without throwing, swallowing any errors.
    /// Used in contexts where we cannot propagate errors (e.g., disconnect, bell).
    private func executeActionNoThrow(_ action: ConnectionAction) async {
        do {
            try await executeAction(action)
        } catch {
            log.error("Action execution failed (non-throwing context): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func emitState() {
        continuation?.yield(.stateChanged(stateMachine.state))
    }

    private func configuredAppleMediaUDPPort() -> UInt16? {
        guard let value = runtimeEnvironment["ROOTSHELL_VNC_MEDIA_LOCAL_UDP_PORT"],
               let port = UInt16(value) else {
            return nil
        }
        return port
    }

    private func appleMediaConfigurationUDPPort() -> UInt16 {
        configuredAppleMediaUDPPort() ?? 5900
    }

    private func configureAppleMediaUDP(for offer: AppleMediaStreamOffer) async throws {
        if let overridePort = configuredAppleMediaUDPPort() {
            try await startAppleMediaStreamUDPIfNeeded(bindings: [
                AppleMediaUDPBinding(localPort: overridePort, remotePort: overridePort)
            ])
            return
        }

        let remotePorts = isAppleMediaComCryptionTransition(offer.rawPayload)
            ? []
            : uniqueNonZeroPorts(
                offer.videoStream1UDPPort,
                offer.audioStreamUDPPort,
                offer.videoStream2UDPPort
            )
        let bindings = (remotePorts.isEmpty ? [5900] : remotePorts).map { remotePort in
            AppleMediaUDPBinding(
                localPort: remotePort,
                remotePort: remotePort
            )
        }
        if remotePorts.isEmpty {
            log.debug("Binding Apple media UDP on default port 5900")
        } else {
            log.debug("Binding Apple media UDP on offered ports \(remotePorts)")
        }
        try await startAppleMediaStreamUDPIfNeeded(bindings: bindings)
    }

    private nonisolated func uniqueNonZeroPorts(_ values: UInt16?...) -> [UInt16] {
        var ports: [UInt16] = []
        for value in values {
            guard let port = value, port != 0, !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    private func appleMediaStreamConfiguration(localPort: UInt16) -> Data {
        var data = ClientMessage.appleMediaStreamConfiguration.serialize()
        guard let offsetValue = runtimeEnvironment["ROOTSHELL_VNC_MEDIA_CONFIG_PORT_OFFSET"],
              let offset = Int(offsetValue),
              offset >= 0,
              offset + 1 < data.count else {
            return data
        }

        data[offset] = UInt8((localPort >> 8) & 0xFF)
        data[offset + 1] = UInt8(localPort & 0xFF)
        log.debug("Patched Apple media configuration UDP port \(localPort) at byte offset \(offset)")
        return data
    }

    private func sendAppleMediaStreamSetupIfNeeded() async throws {
        guard !sentAppleMediaStreamConfiguration else { return }

        let mediaUDPPort = appleMediaConfigurationUDPPort()
        try await tcp.send(appleMediaStreamConfiguration(localPort: mediaUDPPort))
        try await tcp.send(ClientMessage.appleMediaStreamRequest.serialize())
        sentAppleMediaStreamConfiguration = true
        log.debug("Sent Apple media stream configuration and request udpPort=\(mediaUDPPort)")
    }

    /// Ask the server to restart the Apple media stream. Every stream offer
    /// bootstraps a fresh generation with parameter sets and an IRAP, so this
    /// is the recovery of last resort when the initial bootstrap was damaged
    /// on a server that never re-sends an IDR for FIR.
    public func restartAppleMediaStream() async {
        guard sentAppleMediaStreamConfiguration else { return }
        do {
            try await tcp.send(ClientMessage.appleMediaStreamRequest.serialize())
            log.warning("Re-requested Apple media stream (bootstrap recovery)")
        } catch {
            log.error("Could not re-request Apple media stream: \(error.localizedDescription)")
        }
    }

    private func sendAppleMediaServerConfigurationIfNeeded() async throws {
        guard !sentAppleMediaServerConfiguration else { return }

        let configuration = try appleMediaServerConfigurationMessage()
        if rateControlEnabled, appleMediaRateController == nil {
            appleMediaRateController = AppleMediaRateController(
                maxTargetBps: appleMediaRateControllerMaxBps,
                initialTargetBps: appleMediaNetworkProfile.initialCapacityBps)
        }
        rebuildAppleMediaSRTPContexts()
        try await sendAppleEncryptedClientPayload(configuration)
        sentAppleMediaServerConfiguration = true
        log.debug("Sent Apple media server configuration message length=\(configuration.count)")

        // Start the 50 ms feedback-only RCTL source as soon as the receiver is
        // configured, before the first inbound RTP.
        // That outgoing authenticated packet also establishes cellular/VPN
        // NAT mappings. Waiting for video first deadlocks: the server cannot
        // reach our UDP socket until we send, and we previously did not send
        // until the server reached it.
        startAppleRCTLFeedbackLoop()
        await sendAppleMediaRCTLFeedback()
    }

    private func appleMediaServerConfigurationMessage() throws -> Data {
        let generatedAudioOffer = try appleAVCMediaStreamOffer(mode: 8)
        let generatedVideoOffer = try appleAVCMediaStreamOffer(
            mode: 7,
            displayIndex: 0)
        let generatedVideo2Offer = appleMediaDisplayCount > 1
            ? try appleAVCMediaStreamOffer(mode: 7, displayIndex: 1)
            : nil
        let audioOffer = generatedAudioOffer.data
        let videoOffer = generatedVideoOffer.data
        let video2Offer = generatedVideo2Offer?.data

        // The FIR sender field uses the receiver's negotiated local RTP SSRC.
        // Using an unrelated random SSRC produces a valid
        // SRTCP packet that the server does not associate with this receiver.
        appleMediaVideoLocalSSRCs = [generatedVideoOffer.ssrc]
        if let generatedVideo2Offer {
            appleMediaVideoLocalSSRCs.append(generatedVideo2Offer.ssrc)
        }
        appleMediaLocalSSRC = generatedVideoOffer.ssrc
        log.debug(
            "Using negotiated screen receiver SSRCs "
                + appleMediaVideoLocalSSRCs.map { "0x\(String($0, radix: 16))" }
                    .joined(separator: ", ")
                + " for RTCP")
        let audioSendKey = try randomBytes(count: 46)
        let audioReceiveKey = try randomBytes(count: 46)
        let videoSendKey = try randomBytes(count: 46)
        let videoReceiveKey = try randomBytes(count: 46)
        let video2SendKey: Data? = video2Offer == nil ? nil : try randomBytes(count: 46)
        let video2ReceiveKey: Data? = video2Offer == nil ? nil : try randomBytes(count: 46)
        appleMediaSRTPKeys = AppleMediaSRTPKeys(
            audioViewerToServer: audioSendKey,
            audioServerToViewer: audioReceiveKey,
            videoViewerToServer: videoSendKey,
            videoServerToViewer: videoReceiveKey,
            video2ViewerToServer: video2SendKey,
            video2ServerToViewer: video2ReceiveKey
        )
        dumpAppleMediaSRTPKeysIfRequested(
            [audioSendKey, audioReceiveKey, videoSendKey, videoReceiveKey,
             video2SendKey ?? Data(), video2ReceiveKey ?? Data()])

        let fixedHeaderLength = 0xdc
        let video2Length = (video2Offer?.count ?? 0)
        let video2KeyLength = video2Offer == nil ? 0 : 92
        let totalLength = fixedHeaderLength + audioOffer.count + videoOffer.count + video2KeyLength + video2Length
        guard totalLength <= Int(UInt16.max) else {
            throw VNCProtocolError.protocolViolation("Apple media server configuration too large: \(totalLength)")
        }
        guard audioOffer.count <= Int(UInt16.max),
              videoOffer.count <= Int(UInt16.max),
              video2Length <= Int(UInt16.max) else {
            throw VNCProtocolError.protocolViolation("Apple media offer too large")
        }

        var message = Data(count: totalLength)
        message[0] = 0x1c
        writeUInt16BE(UInt16(totalLength - 4), into: &message, at: 2)
        writeUInt16BE(3, into: &message, at: 4)
        // Native receiver flags: bit 0/1 advertise 60 fps for screen one/two;
        // bit 2 means the viewer does not require the cursor to remain visible;
        // bit 3 identifies the native viewer app. Match the native non-viewer,
        // independently rendered-cursor configuration.
        writeUInt32BE(4, into: &message, at: 6)
        writeUInt16BE(UInt16(audioOffer.count), into: &message, at: 10)
        writeUInt16BE(UInt16(videoOffer.count), into: &message, at: 12)
        writeUInt16BE(UInt16(video2Length), into: &message, at: 14)

        let uuidBytes = UUID().bytes
        message.replaceSubrange(0x14..<0x24, with: uuidBytes)
        message.replaceSubrange(0x24..<0x52, with: audioSendKey)
        message.replaceSubrange(0x52..<0x80, with: audioReceiveKey)

        var offset = 0x80
        message.replaceSubrange(offset..<offset + audioOffer.count, with: audioOffer)
        offset += audioOffer.count
        message.replaceSubrange(offset..<offset + 46, with: videoSendKey)
        offset += 46
        message.replaceSubrange(offset..<offset + 46, with: videoReceiveKey)
        offset += 46
        message.replaceSubrange(offset..<offset + videoOffer.count, with: videoOffer)
        offset += videoOffer.count
        if let video2Offer, let video2SendKey, let video2ReceiveKey {
            message.replaceSubrange(offset..<offset + 46, with: video2SendKey)
            offset += 46
            message.replaceSubrange(offset..<offset + 46, with: video2ReceiveKey)
            offset += 46
            message.replaceSubrange(offset..<offset + video2Offer.count, with: video2Offer)
        }
        return message
    }

    private struct GeneratedAppleMediaOffer {
        let data: Data
        let ssrc: UInt32
    }

    private func appleAVCMediaStreamOffer(
        mode: Int,
        displayIndex: Int? = nil
    ) throws -> GeneratedAppleMediaOffer {
        // Mode 8 is Apple's system-audio profile and mode 7 is its screen-video
        // profile. Full Quality is not another media mode; it leaves AVC and
        // requests lossless RFB encodings.
        var negotiatorMode = mode
        if mode != 8, let override = runtimeEnvironment["ROOTSHELL_VNC_AVC_MODE"]
            .flatMap(Int.init) {
            negotiatorMode = override
        }

        let random = try randomBytes(count: 4)
        var ssrc = random.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if ssrc == 0 { ssrc = 1 }
        let displayInfo = displayIndex.flatMap { index in
            appleMediaDisplayInfos.indices.contains(index)
                ? appleMediaDisplayInfos[index]
                : nil
        }
        let profileWidth = displayInfo.map { UInt16(clamping: $0.width) }
            ?? fbWidth
        let profileHeight = displayInfo.map { UInt16(clamping: $0.height) }
            ?? fbHeight
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: profileWidth,
            framebufferHeight: profileHeight,
            supportsHDR: appleMediaSupportsHDR,
            tilesPerFrame: UInt64(activeAppleMediaTilesPerFrame)
        )
        log.debug(
            "Generated Apple media \(mode == 8 ? "audio" : "screen") offer "
                + "ssrc=\(ssrc) aspect=\(profile.aspectRatio.landscapeWidth)/"
                + "\(profile.aspectRatio.landscapeHeight) "
                + "display=\(displayIndex.map { String($0 + 1) } ?? "audio") "
                + "hdr=\(appleMediaSupportsHDR)"
        )
        let data = try profile.makeOffer(
            kind: mode == 8 ? .audio : .screen,
            mode: negotiatorMode,
            ssrc: ssrc,
            ntpTimestamp: AppleMediaNegotiationProfile.ntpTimestamp()
        )
        return GeneratedAppleMediaOffer(data: data, ssrc: ssrc)
    }

    private func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VNCProtocolError.ioError("SecRandomCopyBytes failed: \(status)")
        }
        return data
    }

    private func writeUInt16BE(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 8) & 0xff)
        data[offset + 1] = UInt8(value & 0xff)
    }

    private func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }

    /// A minimal RTCP receiver-report used to prime the server's symmetric-RTP
    /// destination latch. PT=201 (RTCP RR) so it is never confused with video.
    private nonisolated func appleMediaUDPPrimer() -> Data {
        Data([0x80, 0xc9, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
    }

    /// Server-offered media ports override, e.g. `ROOTSHELL_VNC_MEDIA_PORTS=5900,5901`.
    private nonisolated func configuredAppleMediaPortOverride() -> [UInt16]? {
        guard let value = runtimeEnvironment["ROOTSHELL_VNC_MEDIA_PORTS"] else {
            return nil
        }
        let ports = value.split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        return ports.isEmpty ? nil : ports
    }

    /// Detect the server's AVC media message (`0x3f2` pseudo-rectangle) inside a
    /// decrypted ComCryption payload. Message type 1 carries the server's per-
    /// stream UDP ports; when present we (re)open the media UDP sockets to those
    /// ports. Returns true if a type-1 message was consumed.
    private func handleAppleAVCServerMediaMessageIfPresent(_ payload: Data) async throws -> Bool {
        guard let message = findAppleAVCMediaMessage(in: payload) else { return false }
        guard message.messageType == 1 else { return false }

        guard let transition = appleMediaGenerationTracker.beginMessageOne() else {
            log.warning("Ignoring duplicate AVC media message 1 while its answer is pending")
            return true
        }
        beginAppleMediaGeneration(transition)

        let ports = configuredAppleMediaPortOverride() ?? appleMediaServerPorts(from: message.body)
        guard !ports.isEmpty else {
            log.debug("Server AVC media type-1 had no usable UDP ports (body=\(message.body.count) bytes)")
            return true
        }

        let bindings = ports.map { AppleMediaUDPBinding(localPort: $0, remotePort: $0) }
        log.debug("Server AVC media type-1 offered UDP ports \(ports); opening symmetric sockets")
        try await startAppleMediaStreamUDPIfNeeded(bindings: bindings)

        // A type-1 AVC media message is the request for a fresh client media
        // configuration. The client must create its offers and keys, then
        // enqueue that configuration before message 2 arrives. Waiting
        // for the separate 0x456 control record happened to work at startup,
        // where it follows type 1 almost immediately, but a display resize
        // does not send 0x456 first: the server retransmits type 1 while it is
        // waiting for this response. Keep the 0x456 call site as an idempotent
        // compatibility path; this call owns the actual negotiation response.
        try await sendAppleMediaServerConfigurationIfNeeded()
        return true
    }

    /// Begin one message-1/answer media cycle. All fields reset here are
    /// scoped to the encoded media generation; the TCP/RFB connection, input
    /// path, UDP sockets, and installed RTP sink remain intact.
    private func beginAppleMediaGeneration(
        _ transition: AppleMediaNegotiationGenerationTracker.Transition
    ) {
        sentAppleMediaServerConfiguration = false
        sentAppleMediaPostAnswerViewerInfo = false
        sentAppleMediaInitialSetDisplay = false
        sentAppleMediaAutoFrameUpdate = false

        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        appleMediaRTPReorderBuffer.reset()
        appleMediaLastVideoIngestNanos = 0
        appleMediaLastVideoReleaseNanos = 0
        pendingAppleMediaRTPStream = nil
        confirmedAppleMediaRTPStream = nil

        // Message 2 installs fresh keys. Clear the old contexts now so an
        // early new-generation IRAP is buffered instead of being rejected by
        // authentication against the previous generation's keys.
        appleMediaSRTPKeys = nil
        appleMediaSRTPContexts.removeAll(keepingCapacity: true)
        appleMediaSRTPContextBySSRC.removeAll(keepingCapacity: true)
        appleMediaFeedbackRoutes.removeAll(keepingCapacity: true)
        appleMediaFeedbackRouteByRemoteSSRC.removeAll(keepingCapacity: true)
        appleMediaVideoLocalSSRCs.removeAll(keepingCapacity: true)
        appleMediaExpectsSRTP = true
        appleMediaPreKeyDatagrams.removeAll(keepingCapacity: true)
        appleMediaUnprotectFailures = 0

        appleMediaVideoSSRCChannels.removeAll(keepingCapacity: true)
        appleMediaReceptionStats.removeAll(keepingCapacity: true)
        appleMediaLastFrameLossFeedback.removeAll(keepingCapacity: true)
        appleMediaMostRecentFrameLossSSRC = nil
        appleMediaLastSRLSR = 0
        appleMediaLastSRArrivalNanos = 0
        appleMediaLastRTPEchoTimestampQ10 = 0
        appleRCTLPreviousRTPTimestamp = nil
        appleRCTLEchoTimestampArrivalNanos = 0
        appleRCTLTotalPacketsReceived = 0
        appleRCTLPacketsInterval = 0
        appleRCTLLostInterval = 0
        appleRCTLBurstLostInterval = 0
        appleRCTLLastDiagnosticNanos = 0
        appleMediaIngressPacketsSinceDiagnostic = 0
        appleMediaIngressProcessingNanosSinceDiagnostic = 0
        appleMediaIngressMaximumBatchSinceDiagnostic = 0
        // A display resize installs fresh media keys and SSRCs but does not
        // change the network path. Preserve the capacity learned by generation
        // one; resetting to the route prior here can immediately lose the new
        // generation's reference picture on a constrained path.
        if !transition.isReconfiguration {
            appleMediaRateController = nil
        }
        appleLastKeyframeRequestNanos = 0
        appleMediaLocalSSRC = 0

        if transition.isReconfiguration {
            log.info(
                "Beginning in-session Apple media generation \(transition.generation)")
            appleMediaGenerationSink?(
                transition.generation,
                activeAppleMediaTilesPerFrame)
        }
    }

    /// Locate a `0x3f2` AVC media pseudo-rectangle body inside a payload.
    private nonisolated func findAppleAVCMediaMessage(in payload: Data) -> (messageType: UInt16, body: Data)? {
        let marker = Data([0x00, 0x00, 0x03, 0xf2])
        guard let markerRange = payload.range(of: marker) else { return nil }
        let lengthStart = markerRange.upperBound
        guard lengthStart + 2 <= payload.endIndex else { return nil }
        let bodyLength = Int(payload[lengthStart]) << 8 | Int(payload[lengthStart + 1])
        let bodyStart = lengthStart + 2
        let bodyEnd = bodyStart + bodyLength
        guard bodyLength >= 4, bodyEnd <= payload.endIndex else { return nil }
        let body = Data(payload[bodyStart..<bodyEnd])
        let messageType = UInt16(body[body.startIndex + 2]) << 8 | UInt16(body[body.startIndex + 3])
        return (messageType, body)
    }

    /// Extract plausible per-stream UDP ports from a type-1 media message body.
    /// The message variants place 16-bit ports at two stride schemes
    /// (0x08/0x0e/0x14 and 0x0a/0x10/0x16); collect every nonzero
    /// candidate so we bind whichever the server actually uses.
    private nonisolated func appleMediaServerPorts(from body: Data) -> [UInt16] {
        let candidateOffsets = [0x08, 0x0a, 0x0e, 0x10, 0x14, 0x16]
        var ports: [UInt16] = []
        for offset in candidateOffsets {
            guard offset + 1 < body.count else { continue }
            let index = body.startIndex + offset
            let port = UInt16(body[index]) << 8 | UInt16(body[index + 1])
            if port >= 1024, !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }

    private func startAppleMediaStreamUDPIfNeeded(bindings: [AppleMediaUDPBinding]) async throws {
        var requestedBindings: [AppleMediaUDPBinding] = []
        for binding in bindings where !requestedBindings.contains(binding) {
            requestedBindings.append(binding)
        }

        if appleMediaUDPBindings == requestedBindings {
            return
        }

        // Incremental update: KEEP channels whose binding is unchanged and only
        // add/remove the difference. The old full stop-and-restart (media setup
        // grows the binding set from [5900] to [5900, 5901] mid-handshake)
        // closed the video channel while the server's first media burst was in
        // flight and dropped whatever sat in its receive buffer. When a band's
        // startup IRAP was in that window — a timing race, so it struck
        // intermittently — that band stayed black or corrupt for the entire
        // session, because this stream NEVER sends another IRAP.
        var keptBindings: [AppleMediaUDPBinding] = []
        var keptChannels: [PosixUDPChannel] = []
        var keptTasks: [Task<Void, Never>] = []
        for (index, binding) in appleMediaUDPBindings.enumerated() {
            if requestedBindings.contains(binding) {
                keptBindings.append(binding)
                if index < udpChannels.count { keptChannels.append(udpChannels[index]) }
                if index < udpReadTasks.count { keptTasks.append(udpReadTasks[index]) }
            } else {
                if index < udpReadTasks.count { udpReadTasks[index].cancel() }
                if index < udpChannels.count {
                    let closing = udpChannels[index]
                    // Unbind any SSRC routed to the channel being closed.
                    for (ssrc, channel) in appleMediaVideoSSRCChannels where channel === closing {
                        appleMediaVideoSSRCChannels.removeValue(forKey: ssrc)
                    }
                    await closing.close()
                }
            }
        }
        udpChannels = keptChannels
        udpReadTasks = keptTasks
        appleMediaUDPBindings = keptBindings

        for binding in requestedBindings where !keptBindings.contains(binding) {
            appleMediaUDPBindings.append(binding)
            try await startAppleMediaUDPChannel(binding: binding)
        }
    }

    private func startAppleMediaUDPChannel(binding: AppleMediaUDPBinding) async throws {
        // Configure the symmetric-port media socket:
        //   socket(AF_INET, DGRAM) + SO_REUSEADDR + SO_REUSEPORT
        //   + bind(INADDR_ANY:port) + connect(serverIP:port)
        // Symmetric RTP uses the same port both ends; SO_REUSEPORT is what lets
        // the viewer bind a UDP port the server already holds (loopback / same
        // machine). Network.framework does not reliably expose SO_REUSEPORT,
        // which is why the previous unconnected listener never received on
        // loopback.
        // On loopback the symmetric scheme (local==remote==same port)
        // self-delivers: server and client share an identical 4-tuple, so
        // SO_REUSEPORT hashing sends the server's packets to its own socket.
        // Ephemeral mode binds a distinct local port and relies on the server
        // latching our source (from the primer) — which gives clean loopback
        // delivery. Toggle with ROOTSHELL_VNC_MEDIA_UDP_EPHEMERAL=1.
        let ephemeral = runtimeEnvironment["ROOTSHELL_VNC_MEDIA_UDP_EPHEMERAL"] == "1"
        let channel = PosixUDPChannel(
            localPort: ephemeral ? nil : binding.localPort,
            remoteHost: host,
            remotePort: binding.remotePort,
            enableReusePort: true
        )
        try await channel.start()
        udpChannels.append(channel)
        let actualPort = await channel.localPort ?? binding.localPort ?? 0
        continuation?.yield(.appleMediaUDPStarted(localPort: actualPort))
        log.debug("Started Apple media UDP localPort=\(actualPort) remotePort=\(binding.remotePort)")

        // Symmetric RTP: send a zero-length / RTCP primer so the server latches
        // our source endpoint and (on loopback) so the connected 4-tuple is
        // established in both directions. Opt-in for experimentation.
        if runtimeEnvironment["ROOTSHELL_VNC_MEDIA_UDP_PRIME"] == "1" {
            try? await channel.send(appleMediaUDPPrimer())
        }

        let readTask = Task { [weak self, channel] in
            while !Task.isCancelled {
                do {
                    let datagrams = try await channel.receiveDatagramBatch()
                    await self?.handleAppleMediaUDPDatagrams(
                        datagrams,
                        from: channel)
                } catch is CancellationError {
                    break
                } catch {
                    self?.log.warning("UDP media receive ended: \(error.localizedDescription)")
                    break
                }
            }
        }
        udpReadTasks.append(readTask)
    }

    /// Keep a socket-drain batch on this actor until every packet has been
    /// authenticated and delivered. This preserves wire order while amortizing
    /// actor scheduling across the hundreds of RTP fragments in a Retina tile.
    private func handleAppleMediaUDPDatagrams(
        _ datagrams: [PosixUDPDatagram],
        from channel: PosixUDPChannel
    ) {
        let processingStart = DispatchTime.now().uptimeNanoseconds
        for datagram in datagrams {
            handleAppleMediaUDPDatagram(
                datagram.data,
                arrivalNanos: datagram.arrivalNanos,
                from: channel)
        }
        let processingEnd = DispatchTime.now().uptimeNanoseconds
        appleMediaIngressPacketsSinceDiagnostic += datagrams.count
        appleMediaIngressProcessingNanosSinceDiagnostic &+= processingEnd &- processingStart
        appleMediaIngressMaximumBatchSinceDiagnostic = max(
            appleMediaIngressMaximumBatchSinceDiagnostic,
            datagrams.count)
    }

    private nonisolated func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func stopAppleMediaUDP() async {
        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        appleMediaRTPReorderBuffer.reset()
        appleMediaPacketHandoff.reset()
        appleKeyframeRequestTask?.cancel()
        appleKeyframeRequestTask = nil
        appleRTCPReportTask?.cancel()
        appleRTCPReportTask = nil
        appleRCTLFeedbackTask?.cancel()
        appleRCTLFeedbackTask = nil
        appleRCTLPacketsInterval = 0
        appleRCTLLostInterval = 0
        appleRCTLBurstLostInterval = 0
        appleRCTLLastDiagnosticNanos = 0
        appleMediaIngressPacketsSinceDiagnostic = 0
        appleMediaIngressProcessingNanosSinceDiagnostic = 0
        appleMediaIngressMaximumBatchSinceDiagnostic = 0
        appleMediaRateController = nil
        appleMediaLastRTPEchoTimestampQ10 = 0
        appleRCTLPreviousRTPTimestamp = nil
        appleRCTLEchoTimestampArrivalNanos = 0
        appleRCTLTotalPacketsReceived = 0
        appleMediaVideoSSRCChannels.removeAll()
        appleMediaReceptionStats.removeAll()
        appleMediaLastFrameLossFeedback.removeAll()
        appleMediaMostRecentFrameLossSSRC = nil
        appleMediaPreKeyDatagrams.removeAll()
        appleMediaSRTPKeys = nil
        appleMediaSRTPContexts.removeAll()
        appleMediaSRTPContextBySSRC.removeAll()
        appleMediaFeedbackRoutes.removeAll()
        appleMediaFeedbackRouteByRemoteSSRC.removeAll()
        appleMediaVideoLocalSSRCs.removeAll()
        appleMediaLocalSSRC = 0
        appleLastKeyframeRequestNanos = 0
        for task in udpReadTasks {
            task.cancel()
        }
        udpReadTasks.removeAll()

        for channel in udpChannels {
            await channel.close()
        }
        udpChannels.removeAll()
        appleMediaUDPBindings.removeAll()
    }

    /// Build one SRTP receive context per server-to-viewer key so every media
    /// stream (audio, video, video2) can be decrypted; contexts are matched to
    /// packets by SSRC on first use.
    private func rebuildAppleMediaSRTPContexts() {
        guard let keys = appleMediaSRTPKeys else { return }
        appleMediaSRTPContexts.removeAll(keepingCapacity: true)
        appleMediaSRTPContextBySSRC.removeAll(keepingCapacity: true)
        appleMediaFeedbackRoutes.removeAll(keepingCapacity: true)
        appleMediaFeedbackRouteByRemoteSSRC.removeAll(keepingCapacity: true)

        func addVideoRoute(
            streamIndex: Int,
            serverToViewer: Data?,
            viewerToServer: Data?,
            localSSRC: UInt32?
        ) {
            guard let serverToViewer,
                  let viewerToServer,
                  let localSSRC,
                  serverToViewer.count >= 46,
                  viewerToServer.count >= 46,
                  let receiveContext = try? AppleSRTPContext(mediaKey: serverToViewer),
                  let sendRTCPContext = try? AppleSRTCPContext(mediaKey: viewerToServer),
                  let receiveRTCPContext = try? AppleSRTCPContext(mediaKey: serverToViewer)
            else { return }
            appleMediaSRTPContexts.append(receiveContext)
            appleMediaFeedbackRoutes.append(AppleMediaFeedbackRoute(
                receiveContext: receiveContext,
                sendRTCPContext: sendRTCPContext,
                receiveRTCPContext: receiveRTCPContext,
                localSSRC: localSSRC,
                streamIndex: streamIndex))
        }

        addVideoRoute(
            streamIndex: 1,
            serverToViewer: keys.videoServerToViewer,
            viewerToServer: keys.videoViewerToServer,
            localSSRC: appleMediaVideoLocalSSRCs.first)
        addVideoRoute(
            streamIndex: 2,
            serverToViewer: keys.video2ServerToViewer,
            viewerToServer: keys.video2ViewerToServer,
            localSSRC: appleMediaVideoLocalSSRCs.count > 1
                ? appleMediaVideoLocalSSRCs[1]
                : nil)

        if keys.audioServerToViewer.count >= 46,
           let audioContext = try? AppleSRTPContext(mediaKey: keys.audioServerToViewer) {
            appleMediaSRTPContexts.append(audioContext)
        }
        if appleMediaLocalSSRC == 0 {
            appleMediaLocalSSRC = generateAppleMediaLocalSSRC()
        }
        log.debug(
            "Configured \(appleMediaSRTPContexts.count) Apple media SRTP receive contexts, "
                + "videoFeedbackRoutes=\(appleMediaFeedbackRoutes.count)")

        // Replay any media that raced ahead of the keys, in arrival order.
        // This is what makes startup deterministic: the burst right after the
        // key record carries every band's ONLY IRAP, and losing any prefix of
        // it left that band dead for the whole session.
        if !appleMediaPreKeyDatagrams.isEmpty, !appleMediaSRTPContexts.isEmpty {
            let buffered = appleMediaPreKeyDatagrams
            appleMediaPreKeyDatagrams.removeAll()
            log.info("Replaying \(buffered.count) media datagrams buffered before SRTP keys arrived")
            for (datagram, channel) in buffered {
                handleAppleMediaUDPDatagram(
                    datagram,
                    // Waiting for the control-plane key record is not receiver
                    // congestion. Start arrival accounting when replay begins.
                    arrivalNanos: DispatchTime.now().uptimeNanoseconds,
                    from: channel)
            }
        }
    }

    private func generateAppleMediaLocalSSRC() -> UInt32 {
        guard let bytes = try? randomBytes(count: 4) else { return 0x5253_4801 }
        let base = bytes.startIndex
        var value: UInt32 = 0
        value = (value << 8) | UInt32(bytes[base])
        value = (value << 8) | UInt32(bytes[base + 1])
        value = (value << 8) | UInt32(bytes[base + 2])
        value = (value << 8) | UInt32(bytes[base + 3])
        return value
    }

    private var appleMediaFIRSeq: UInt8 = 0

    /// No-video-displayed recovery uses RR + PSFB FIR, followed by a reset of
    /// expected decoding order. Do not layer PLI and legacy FIR variants into
    /// the same compound packet; this profile uses the RFC 5104 FIR form.
    private func sendAppleMediaKeyframeRequest(mediaSSRC: UInt32, on channel: PosixUDPChannel) async {
        guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC) else { return }
        let sender = route.localSSRC
        var compound = Data()
        if let rr = buildAppleMediaReceiverReport(
            senderSSRC: sender,
            mediaSSRC: mediaSSRC) {
            compound.append(rr)
        }

        appleMediaFIRSeq &+= 1
        compound.append(appleMediaFullIntraRequestPacket(
            senderSSRC: sender,
            mediaSSRC: mediaSSRC,
            sequenceNumber: appleMediaFIRSeq))

        guard let protected = try? route.sendRTCPContext.protect(
            compound,
            senderSSRC: sender) else { return }
        dumpAppleMediaOutgoingRTCPIfRequested(plaintext: compound, protected: protected)
        try? await channel.send(protected)
        log.warning("Sent native no-video-displayed FIR media ssrc=0x\(String(mediaSSRC, radix: 16)) "
            + "feedbackStream=\(route.streamIndex) sequence=\(self.appleMediaFIRSeq)")
    }


    /// Emit a media RTP packet (post-SRTP for UDP, post-extraction for TCP),
    /// optionally dumping the exact bytes the video decoder will receive.
    /// Install a fast-path sink for decrypted video RTP. Pass `nil` to revert to
    /// buffering packets until a new sink is installed.
    public func setAppleMediaRTPSink(_ sink: (@Sendable (Data) -> Void)?) {
        let routedSink: (@Sendable (Data, Int?) -> Void)?
        if let sink {
            routedSink = { packet, _ in
                sink(packet)
            }
        } else {
            routedSink = nil
        }
        setAppleMediaRoutedRTPSink(routedSink)
    }

    /// Install a media sink that also identifies which negotiated display owns
    /// each video packet. Audio packets have no display index.
    public func setAppleMediaRoutedRTPSink(
        _ sink: (@Sendable (Data, Int?) -> Void)?
    ) {
        let drained = appleMediaPacketHandoff.installSink(sink)
        if drained.packetCount > 0 {
            log.info("Drained \(drained.packetCount) ordered startup RTP packets "
                + "(\(drained.byteCount) bytes) into the media sink")
        }
        if drained.overflowed {
            log.error("Media startup buffer overflowed; dropped \(drained.droppedPacketCount) newest packets")
            requestAppleMediaRecoveryAfterIngressOverflow()
        }
    }

    /// Preserve the live control/media session across app suspension while
    /// teaching the RTP reorderer that the next sequence can legitimately be
    /// more than half a UInt16 space ahead.
    public func noteAppleMediaInterruption() {
        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        appleMediaRTPReorderBuffer.markMediaInterruption()
        log.warning("Marked Apple media RTP stream interrupted; awaiting measured resume gap")
    }

    private func emitAppleMediaRTPPacket(_ packet: Data) {
        dumpAppleMediaDecodedRTPIfRequested(packet)
        let displayIndex = appleMediaRTPSSRC(packet)
            .flatMap { appleMediaFeedbackRouteByRemoteSSRC[$0] }
            .map { max(0, $0.streamIndex - 1) }
        if appleMediaPacketHandoff.deliver(
            packet,
            displayIndex: displayIndex
        ) == .overflow {
            log.error("Media ingress overflow while waiting for decoder sink")
        }
    }

    private func requestAppleMediaRecoveryAfterIngressOverflow() {
        guard let (ssrc, channel) = appleMediaVideoSSRCChannels.first else { return }
        requestAppleMediaKeyframeRateLimited(ssrc: ssrc, channel: channel)
        Task { [weak self] in
            try? await self?.requestFramebufferUpdate(incremental: false)
        }
    }

    private nonisolated func dumpAppleMediaOutgoingRTCPIfRequested(plaintext: Data, protected: Data) {
        guard let path = appleMediaOutgoingRTCPDumpPath else { return }
        let line = "RTCP plaintext=\(plaintext.map { String(format: "%02x", $0) }.joined()) "
            + "protected=\(protected.map { String(format: "%02x", $0) }.joined())\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private nonisolated func dumpAppleMediaDecodedRTPIfRequested(_ packet: Data) {
        guard let path = appleMediaDecodedRTPDumpPath else { return }
        var framed = Data()
        // Optional 8-byte big-endian nanosecond timestamp prefix for bitrate-over-
        // time analysis (ROOTSHELL_VNC_DUMP_RTP_TIMED=1).
        if appleMediaDecodedRTPDumpIncludesTimestamps {
            let t = DispatchTime.now().uptimeNanoseconds
            for shift in stride(from: 56, through: 0, by: -8) {
                framed.append(UInt8((t >> UInt64(shift)) & 0xFF))
            }
        }
        framed.append(UInt8((packet.count >> 8) & 0xFF))
        framed.append(UInt8(packet.count & 0xFF))
        framed.append(packet)
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: framed)
            try? handle.close()
        } else {
            try? framed.write(to: URL(fileURLWithPath: path))
        }
    }

    private func handleAppleMediaUDPDatagram(
        _ datagram: Data,
        arrivalNanos: UInt64,
        from channel: PosixUDPChannel
    ) {
        dumpAppleMediaUDPDatagramIfRequested(datagram)

        if isAppleMediaRTCPPacket(datagram) {
            handleAppleMediaServerSenderReport(datagram)
            continuation?.yield(.udpDatagram(datagram))
            return
        }

        guard let ssrc = appleMediaRTPSSRC(datagram) else {
            continuation?.yield(.udpDatagram(datagram))
            return
        }

        // STARTUP RACE: the server begins blasting the initial media burst —
        // parameter sets plus each band's one-and-only IRAP — immediately
        // after it sends the key control record, racing our processing of that
        // record. Any RTP that lands before the SRTP contexts exist used to be
        // undecryptable and lost; when a band's IRAP was in that prefix, the
        // band stayed dead/corrupt for the ENTIRE session (this stream never
        // repeats an IRAP), intermittently by pure timing. Buffer pre-key
        // datagrams and replay them in arrival order the moment keys arrive.
        if appleMediaSRTPContexts.isEmpty, appleMediaExpectsSRTP {
            if appleMediaPreKeyDatagrams.count >= 4096 {
                appleMediaPreKeyDatagrams.removeFirst()
            }
            appleMediaPreKeyDatagrams.append((datagram, channel))
            return
        }

        // Fast path: SSRC already bound to a context.
        if let context = appleMediaSRTPContextBySSRC[ssrc],
           let packet = try? context.unprotect(datagram) {
            bindAppleMediaFeedbackRouteIfAvailable(
                receiveContext: context,
                remoteSSRC: ssrc)
            acceptAppleMediaRTPPacket(
                packet,
                wireByteCount: datagram.count,
                arrivalNanos: arrivalNanos,
                from: channel)
            return
        }

        // Otherwise find the context whose key authenticates this SSRC.
        for context in appleMediaSRTPContexts {
            if let packet = try? context.unprotect(datagram) {
                appleMediaSRTPContextBySSRC[ssrc] = context
                bindAppleMediaFeedbackRouteIfAvailable(
                    receiveContext: context,
                    remoteSSRC: ssrc)
                acceptAppleMediaRTPPacket(
                    packet,
                    wireByteCount: datagram.count,
                    arrivalNanos: arrivalNanos,
                    from: channel)
                return
            }
        }

        // SRTP is configured but no key authenticates this packet: it is
        // ciphertext (or noise) and must NEVER travel toward the decoder —
        // VNCSession's .udpDatagram path used to feed these to the demuxer,
        // where the encrypted payload parsed as garbage NAL units and
        // permanently re-corrupted the video (~2 pkts/s on a live server).
        // Only a session with no SRTP contexts (plaintext/loopback debugging)
        // still forwards raw datagrams.
        if !appleMediaSRTPContexts.isEmpty {
            appleMediaUnprotectFailures &+= 1
            if appleMediaUnprotectFailures & 0xFF == 1 { // log 1st, then every 256th
                log.warning("Dropped undecryptable media datagram ssrc=0x\(String(ssrc, radix: 16)) "
                    + "count=\(self.appleMediaUnprotectFailures)")
            }
            return
        }

        acceptAppleMediaRTPPacket(
            datagram,
            wireByteCount: datagram.count,
            arrivalNanos: arrivalNanos,
            from: channel)
    }

    private func bindAppleMediaFeedbackRouteIfAvailable(
        receiveContext: AppleSRTPContext,
        remoteSSRC: UInt32
    ) {
        guard appleMediaFeedbackRouteByRemoteSSRC[remoteSSRC] == nil,
              let route = appleMediaFeedbackRoutes.first(where: {
                  $0.receiveContext === receiveContext
              }) else { return }
        appleMediaFeedbackRouteByRemoteSSRC[remoteSSRC] = route
        log.info(
            "Bound remote video ssrc=0x\(String(remoteSSRC, radix: 16)) "
                + "to feedback stream=\(route.streamIndex) localSSRC=0x"
                + String(route.localSSRC, radix: 16))
    }

    private func appleMediaFeedbackRoute(
        forRemoteSSRC remoteSSRC: UInt32
    ) -> AppleMediaFeedbackRoute? {
        appleMediaFeedbackRouteByRemoteSSRC[remoteSSRC]
            ?? appleMediaFeedbackRoutes.first
    }

    /// Test-only deterministic loss injection
    /// (`ROOTSHELL_VNC_TEST_DROP_VIDEO_AFTER_PACKETS=N` or `N:K`): after N
    /// accepted video packets, drop the next K (default 1), upstream of all
    /// reception bookkeeping, so the full native recovery chain runs as for
    /// real loss. A single dropped packet is healed silently by RTP
    /// retransmission; a burst defeats RTX and exercises confirmed-loss
    /// feedback plus keyframe recovery.
    private lazy var testVideoPacketDropCountdown: Int = {
        guard let spec = runtimeEnvironment[
            "ROOTSHELL_VNC_TEST_DROP_VIDEO_AFTER_PACKETS"] else { return Int.min }
        // One injection per process: a recovery reconnect must not be
        // re-damaged, or the recovery loop under test could never converge.
        guard !Self.testVideoPacketDropConsumed else { return Int.min }
        Self.testVideoPacketDropConsumed = true
        let parts = spec.split(separator: ":")
        if parts.count == 2, let after = Int(parts[0]), let burst = Int(parts[1]) {
            testVideoPacketDropBurst = max(1, burst)
            return after
        }
        return Int(spec) ?? Int.min
    }()
    private var testVideoPacketDropBurst = 1
    private nonisolated(unsafe) static var testVideoPacketDropConsumed = false

    /// Accept one decrypted RTP packet. Video packets pass through the bounded
    /// per-SSRC jitter buffer; non-video media can be delivered immediately.
    private func acceptAppleMediaRTPPacket(
        _ packet: Data,
        wireByteCount: Int,
        arrivalNanos: UInt64,
        from channel: PosixUDPChannel
    ) {
        guard let header = parseAppleMediaRTPHeader(packet) else { return }
        guard header.payloadType == 100 else {
            emitAppleMediaRTPPacket(packet)
            return
        }
        if testVideoPacketDropCountdown != Int.min {
            if testVideoPacketDropCountdown > 0 {
                testVideoPacketDropCountdown -= 1
            } else {
                testVideoPacketDropBurst -= 1
                if testVideoPacketDropBurst <= 0 {
                    testVideoPacketDropCountdown = Int.min
                }
                log.warning("TEST loss injection: dropping video RTP packet pre-ingress "
                    + "(remaining burst \(max(0, testVideoPacketDropBurst)))")
                return
            }
        }

        let isNew = appleMediaVideoSSRCChannels[header.ssrc] == nil
        appleMediaVideoSSRCChannels[header.ssrc] = channel
        if isNew {
            log.info("First video RTP for ssrc=0x\(String(header.ssrc, radix: 16))")
        }
        let requiredInitialSources = activeAppleMediaTilesPerFrame
            * appleMediaDisplayCount
        if !completedInitialAppleMediaNegotiation,
           appleMediaVideoSSRCChannels.count >= requiredInitialSources {
            completedInitialAppleMediaNegotiation = true
            Task { [weak self] in
                await self?.applyStagedVirtualDisplayAfterInitialVideo()
            }
        }
        if let awaitedGeneration = appleDisplayReconfigurationGeneration,
           appleMediaGenerationTracker.generation >= awaitedGeneration,
           appleMediaVideoSSRCChannels.count
                >= activeAppleMediaTilesPerFrame * appleMediaDisplayCount {
            appleDisplayReconfigurationGeneration = nil
            if let pendingRemoteDisplaySize,
               pendingRemoteDisplaySize != lastSentRemoteDisplaySize {
                Task { [weak self] in
                    await self?.applyQueuedVirtualDisplayAfterMediaReady()
                }
            }
        }

        let processingNanos = DispatchTime.now().uptimeNanoseconds
        let ingressQueueDelayNanos = processingNanos >= arrivalNanos
            ? processingNanos - arrivalNanos
            : 0
        let nowNanos = arrivalNanos
        let unique = updateAppleMediaReceptionStats(
            ssrc: header.ssrc,
            sequence: header.sequenceNumber)
        if unique {
            appleRCTLTotalPacketsReceived &+= 1
            appleRCTLPacketsInterval += 1
            updateAppleRCTLEchoTimestamp(
                header.timestamp,
                arrivalNanos: nowNanos)
            startAppleRTCPReportLoop()
            startAppleRCTLFeedbackLoop()

            if rateControlEnabled {
                let controller = appleMediaRateController ?? {
                    let created = AppleMediaRateController(
                        maxTargetBps: appleMediaRateControllerMaxBps,
                        initialTargetBps: appleMediaNetworkProfile.initialCapacityBps)
                    appleMediaRateController = created
                    return created
                }()
                let now = Double(arrivalNanos) / 1_000_000_000
                controller.onVideoPacket(
                    ssrc: header.ssrc,
                    rtpTimestamp: header.timestamp,
                    bytes: wireByteCount,
                    endOfFrame: header.marker,
                    queueDelaySeconds: Double(ingressQueueDelayNanos) / 1_000_000_000,
                    now: now)
                controller.update(now: now)
            }
        }

        let ingestClockNanos = DispatchTime.now().uptimeNanoseconds
        appleMediaLastVideoIngestNanos = ingestClockNanos
        if appleMediaLastVideoReleaseNanos == 0 {
            // Arm the dead-man from first ingest so a from-birth stall (never
            // a single released packet) is also detected.
            appleMediaLastVideoReleaseNanos = ingestClockNanos
        }
        let result = appleMediaRTPReorderBuffer.insert(
            packet: packet,
            ssrc: header.ssrc,
            sequence: header.sequenceNumber,
            nowNanos: nowNanos)
        processAppleMediaReorderResult(result)
        scheduleAppleMediaReorderFlush(nowNanos: nowNanos)
    }

    private func processAppleMediaReorderResult(_ result: AppleMediaRTPReorderBuffer.Result) {
        for request in result.retransmissionRequests {
            guard let channel = appleMediaVideoSSRCChannels[request.ssrc] else { continue }
            Task { [weak self] in
                await self?.sendAppleMediaNACK(
                    missingSequences: request.missingSequences,
                    mediaSSRC: request.ssrc,
                    on: channel)
            }
        }

        for gap in result.gaps {
            appleRCTLLostInterval += gap.missingPacketCount
            appleRCTLBurstLostInterval = max(
                appleRCTLBurstLostInterval,
                gap.missingPacketCount)

            if rateControlEnabled {
                let controller = appleMediaRateController ?? {
                    let created = AppleMediaRateController(
                        maxTargetBps: appleMediaRateControllerMaxBps,
                        initialTargetBps: appleMediaNetworkProfile.initialCapacityBps)
                    appleMediaRateController = created
                    return created
                }()
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                controller.onConfirmedLoss(count: gap.missingPacketCount, now: now)
                controller.update(now: now)
            }

            guard let channel = appleMediaVideoSSRCChannels[gap.ssrc] else { continue }
            let feedback = AppleMediaFrameLossFeedback(
                frameRTPTimestamp: gap.frameRTPTimestamp,
                receivedPacketCount: UInt16(truncatingIfNeeded:
                    appleMediaReceptionStats[gap.ssrc]?.received ?? 0),
                framePacketCount: UInt8(clamping: max(
                    gap.missingPacketCount,
                    gap.estimatedFramePacketCount)),
                lostPacketCount: UInt8(clamping: gap.missingPacketCount))
            appleMediaLastFrameLossFeedback[gap.ssrc] = feedback
            appleMediaMostRecentFrameLossSSRC = gap.ssrc
            log.warning("Confirmed video RTP loss ssrc=0x\(String(gap.ssrc, radix: 16)) "
                + "missing=\(gap.missingPacketCount) framePackets=\(feedback.framePacketCount) "
                + "frameTimestamp=\(feedback.frameRTPTimestamp) "
                + "frameSequence=\(gap.frameSequenceNumber.map(String.init) ?? "unknown")")
            Task { [weak self] in
                await self?.sendAppleMediaFrameLossFeedback(
                    feedback,
                    mediaSSRC: gap.ssrc,
                    on: channel)
            }
        }

        let packets = result.packets
        if !packets.isEmpty {
            appleMediaLastVideoReleaseNanos = DispatchTime.now().uptimeNanoseconds
        }
        for packet in packets {
            emitAppleMediaRTPPacket(packet)
        }
    }

    /// Send negotiated frame-loss feedback (PSFB AFB type 6). Unlike PLI/FIR,
    /// this signal requests a recovery IDR for an LTR-enabled screen stream.
    private func sendAppleMediaFrameLossFeedback(
        _ feedback: AppleMediaFrameLossFeedback,
        mediaSSRC: UInt32,
        on channel: PosixUDPChannel
    ) async {
        guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC) else { return }
        let sender = route.localSSRC
        var compound = Data()
        if let rr = buildAppleMediaReceiverReport(
            senderSSRC: sender,
            mediaSSRC: mediaSSRC) {
            compound.append(rr)
        }
        compound.append(appleMediaFrameLossPacket(
            senderSSRC: sender,
            mediaSSRC: mediaSSRC,
            feedback: feedback))

        guard let protected = try? route.sendRTCPContext.protect(
            compound,
            senderSSRC: sender) else { return }
        dumpAppleMediaOutgoingRTCPIfRequested(plaintext: compound, protected: protected)
        try? await channel.send(protected)
        log.warning("Sent AVConference frame-loss feedback ssrc=0x\(String(mediaSSRC, radix: 16)) "
            + "received=\(feedback.receivedPacketCount) framePackets=\(feedback.framePacketCount) "
            + "lost=\(feedback.lostPacketCount) feedbackStream=\(route.streamIndex)")
    }

    /// Confirm that a decode gate corresponds to transport-observed packet
    /// loss before arming the no-video-displayed FIR fail-safe.
    public func hasObservedVideoLossFeedback(ssrc requestedSSRC: UInt32? = nil) -> Bool {
        if let requestedSSRC,
           appleMediaLastFrameLossFeedback[requestedSSRC] != nil {
            return appleMediaVideoSSRCChannels[requestedSSRC] != nil
        }
        guard let recent = appleMediaMostRecentFrameLossSSRC else { return false }
        return appleMediaLastFrameLossFeedback[recent] != nil
            && appleMediaVideoSSRCChannels[recent] != nil
    }

    /// Whether the receive controller considers the path quiet enough for a
    /// large recovery IDR. Sending FIR while packets are still being lost just
    /// creates another undecodable burst and prolongs the black screen.
    /// `displayGated` relaxes the quiet requirement: with every band gated the
    /// screen is frozen anyway, so recovery latency dominates the tradeoff.
    public func isReadyForVideoKeyframeRecovery(displayGated: Bool = false) -> Bool {
        guard let controller = appleMediaRateController else { return true }
        return controller.isReadyForKeyframeRecovery(
            now: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000,
            displayGated: displayGated)
    }

    /// Proactively step the advertised receive capacity down before retrying a
    /// recovery IDR, and flush one RCTL packet so the reduced estimate is on
    /// the wire ahead of the FIR rather than up to 50 ms behind it.
    public func applyVideoRecoveryBackoff() async {
        guard rateControlEnabled, let controller = appleMediaRateController else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        guard controller.forceRecoveryBackoff(now: now) else { return }
        log.warning(
            "Recovery backoff before FIR retry: advertising "
                + "\(controller.bandwidthEstimateBps / 1_000) kbps "
                + "(attempt \(controller.recoveryAttemptCount))")
        await sendAppleMediaRCTLFeedback()
    }

    /// The recovery gate cleared; end the controller's recovery episode so the
    /// normal floor and utilization-gated ramp resume.
    public func noteVideoRecoveryComplete() {
        appleMediaRateController?.noteRecoveryComplete()
    }

    /// Ask the server to retransmit missing RTP packets while the per-SSRC
    /// jitter buffer holds newer packets. The media profile supports NACK and
    /// retransmission; without this step a single lost fragment
    /// becomes a missing HEVC picture and corrupts its dependent pictures.
    private func sendAppleMediaNACK(
        missingSequences: [UInt16],
        mediaSSRC: UInt32,
        on channel: PosixUDPChannel
    ) async {
        guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC) else { return }
        let entries = appleMediaGenericNACKEntries(missingSequences: missingSequences)
        guard !entries.isEmpty else { return }

        let sender = route.localSSRC
        var compound = Data()
        if let rr = buildAppleMediaReceiverReport(
            senderSSRC: sender,
            mediaSSRC: mediaSSRC) {
            compound.append(rr)
        }

        compound.append(0x81) // V=2, P=0, FMT=1 (Generic NACK)
        compound.append(0xcd) // PT=205 (RTPFB)
        let length = UInt16(2 + entries.count)
        compound.append(UInt8(length >> 8))
        compound.append(UInt8(length & 0xff))
        appendUInt32BE(sender, to: &compound)
        appendUInt32BE(mediaSSRC, to: &compound)
        for entry in entries {
            compound.append(UInt8(entry.packetID >> 8))
            compound.append(UInt8(entry.packetID & 0xff))
            compound.append(UInt8(entry.bitmask >> 8))
            compound.append(UInt8(entry.bitmask & 0xff))
        }

        guard let protected = try? route.sendRTCPContext.protect(
            compound,
            senderSSRC: sender) else { return }
        dumpAppleMediaOutgoingRTCPIfRequested(plaintext: compound, protected: protected)
        try? await channel.send(protected)
        log.debug("Requested RTP retransmission ssrc=0x\(String(mediaSSRC, radix: 16)) "
            + "missing=\(missingSequences.count) feedbackStream=\(route.streamIndex)")
    }

    private func scheduleAppleMediaReorderFlush(nowNanos: UInt64) {
        guard let deadline = appleMediaRTPReorderBuffer.nextDeadlineNanos else {
            appleMediaRTPReorderFlushTask?.cancel()
            appleMediaRTPReorderFlushTask = nil
            appleMediaRTPReorderScheduledDeadlineNanos = nil
            return
        }
        if let scheduled = appleMediaRTPReorderScheduledDeadlineNanos,
           scheduled <= deadline,
           appleMediaRTPReorderFlushTask != nil {
            return
        }

        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderScheduledDeadlineNanos = deadline
        // `nowNanos` is the socket arrival time. When ingress is catching up it
        // may be far behind the monotonic clock, so an already-expired loss
        // deadline must fire immediately instead of sleeping another 300 ms.
        let clockNow = DispatchTime.now().uptimeNanoseconds
        let delay = deadline > clockNow ? deadline - clockNow : 0
        appleMediaRTPReorderFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int64(min(delay, UInt64(Int64.max)))))
            guard !Task.isCancelled else { return }
            await self?.flushAppleMediaRTPReorderBuffer()
        }
    }

    private func flushAppleMediaRTPReorderBuffer() {
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        let now = DispatchTime.now().uptimeNanoseconds
        let result = appleMediaRTPReorderBuffer.flushExpired(nowNanos: now)
        processAppleMediaReorderResult(result)
        scheduleAppleMediaReorderFlush(nowNanos: now)
    }

    /// Request a fresh IDR for the video stream, from outside the transport.
    /// Used by the decode pipeline's recovery paths when startup, a damaged
    /// reference chain, or an asynchronous decoder failure needs a fresh IRAP.
    /// A light 150 ms floor guards against concurrent recovery triggers.
    public func requestVideoKeyframe(ssrc requestedSSRC: UInt32? = nil) async {
        let target: (UInt32, PosixUDPChannel)?
        if let requestedSSRC, let channel = appleMediaVideoSSRCChannels[requestedSSRC] {
            target = (requestedSSRC, channel)
        } else {
            target = appleMediaVideoSSRCChannels.first.map { ($0.key, $0.value) }
        }
        guard let (ssrc, channel) = target else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- appleLastKeyframeRequestNanos > 150_000_000 else { return }
        appleLastKeyframeRequestNanos = now
        await sendAppleMediaKeyframeRequest(mediaSSRC: ssrc, on: channel)
    }

    /// Send a keyframe request at most once per second so bursty loss doesn't
    /// trigger a flood of IDRs.
    private func requestAppleMediaKeyframeRateLimited(ssrc: UInt32, channel: PosixUDPChannel) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- appleLastKeyframeRequestNanos > 1_000_000_000 else { return }
        appleLastKeyframeRequestNanos = now
        Task { [weak self] in
            await self?.sendAppleMediaKeyframeRequest(mediaSSRC: ssrc, on: channel)
        }
    }

    // MARK: - RTCP Receiver Reports (bitrate feedback)

    /// Update per-SSRC reception counters used to build Receiver Reports.
    @discardableResult
    private func updateAppleMediaReceptionStats(ssrc: UInt32, sequence: UInt16) -> Bool {
        var stats = appleMediaReceptionStats[ssrc] ?? AppleMediaReceptionStats()
        if !stats.recentSequences.insert(sequence) {
            return false
        }

        if !stats.initialized {
            stats.baseSeq = UInt32(sequence)
            stats.maxSeq = sequence
            stats.received = 1
            stats.initialized = true
        } else {
            let forwardDelta = sequence &- stats.maxSeq // UInt16 wraparound
            if forwardDelta < 0x8000 {
                if sequence < stats.maxSeq { stats.cycles &+= 0x1_0000 } // wrapped past 0xffff
                stats.maxSeq = sequence
            }
            stats.received &+= 1
        }
        appleMediaReceptionStats[ssrc] = stats
        return true
    }

    /// Parse the server's SRTCP Sender Report to capture the LSR/DLSR round-trip
    /// timestamp the server needs to estimate RTT.
    private func handleAppleMediaServerSenderReport(_ datagram: Data) {
        var decoded: Data?
        for route in appleMediaFeedbackRoutes {
            if let rtcp = try? route.receiveRTCPContext.unprotect(datagram) {
                decoded = rtcp
                break
            }
        }
        guard let rtcp = decoded, rtcp.count >= 20 else { return }
        let base = rtcp.startIndex
        guard rtcp[base + 1] == 200 else { return } // PT = Sender Report
        // NTP timestamp is 8 bytes at offset 8; LSR is its middle 32 bits.
        let lsr = UInt32(rtcp[base + 10]) << 24 | UInt32(rtcp[base + 11]) << 16
            | UInt32(rtcp[base + 12]) << 8 | UInt32(rtcp[base + 13])
        appleMediaLastSRLSR = lsr
        appleMediaLastSRArrivalNanos = DispatchTime.now().uptimeNanoseconds
    }

    private func startAppleRTCPReportLoop() {
        guard appleRTCPReportTask == nil else { return }
        let testFIR = runtimeEnvironment["ROOTSHELL_VNC_TEST_FIR"] == "1"
        appleRTCPReportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await self?.sendAppleMediaReceiverReport()
                if testFIR { await self?.sendTestKeyframeRequest() }
            }
        }
    }

    /// Diagnostic: force a keyframe request so we can verify the server honors
    /// our FIR (a fresh IDR should appear in the stream after each one).
    private func sendTestKeyframeRequest() async {
        guard let (ssrc, channel) = appleMediaVideoSSRCChannels.first else { return }
        await sendAppleMediaKeyframeRequest(mediaSSRC: ssrc, on: channel)
    }

    /// Start the RTCP APP "RCTL" rate-control feedback loop. Native sends this at
    /// ~20 Hz (every 50 ms); it is what makes the server's encoder ADAPT its
    /// bitrate (drop when idle, ramp under motion). Without it the server encodes
    /// at a constant maximum, pinning CPU and shredding frames on any load.
    private func startAppleRCTLFeedbackLoop() {
        guard appleRCTLFeedbackTask == nil else { return }
        guard rctlEnabled else { return }
        appleRCTLFeedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                await self?.recoverWedgedAppleMediaReorderBufferIfNeeded()
                await self?.sendAppleMediaRCTLFeedback()
            }
        }
    }

    /// Timestamps for the video release dead-man below.
    private var appleMediaLastVideoIngestNanos: UInt64 = 0
    private var appleMediaLastVideoReleaseNanos: UInt64 = 0

    /// Dead-man for a wedged jitter buffer: video RTP is being ingested but
    /// nothing has been released downstream for well over the maximum gap
    /// wait. This can occur when a confirmed loss lands inside a media
    /// renegotiation window: subsequent packets remain queued and
    /// the display stayed black while audio continued. Resetting the buffer
    /// re-anchors sequence tracking; the resulting jump surfaces as a normal
    /// loss and heals through keyframe recovery.
    private func recoverWedgedAppleMediaReorderBufferIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard appleMediaLastVideoIngestNanos != 0,
              now &- appleMediaLastVideoIngestNanos < 500_000_000,
              appleMediaLastVideoReleaseNanos != 0,
              now &- appleMediaLastVideoReleaseNanos > 1_500_000_000 else { return }
        log.error(
            "Video jitter buffer stalled (ingest live, no release for >1.5 s, "
                + "\(appleMediaRTPReorderBuffer.queuedPacketCount) queued); resetting")
        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        appleMediaRTPReorderBuffer.reset()
        appleMediaLastVideoReleaseNanos = now
    }

    /// Apply the feedback-only RTP receive-accounting rules. Update the echo
    /// only when a forward-moving RTP timestamp begins, then send the
    /// low-precision form selected by Apple's video-stream configuration.
    private func updateAppleRCTLEchoTimestamp(
        _ timestamp: UInt32,
        arrivalNanos: UInt64
    ) {
        guard let previous = appleRCTLPreviousRTPTimestamp else {
            appleRCTLPreviousRTPTimestamp = timestamp
            return
        }
        let distance = timestamp &- previous
        guard distance != 0, distance < 0x8000_0000 else { return }
        appleRCTLPreviousRTPTimestamp = timestamp
        appleMediaLastRTPEchoTimestampQ10 =
            appleMediaRCTLLowPrecisionEchoTimestamp(timestamp)
        appleRCTLEchoTimestampArrivalNanos = arrivalNanos
    }

    /// Build and send one RTCP APP "RCTL" rate-control feedback packet:
    /// `80 CC 00 07 [SSRC] "RCTL" [20-byte payload]`, SRTCP-protected. The
    /// 20-byte payload carries our measured received bitrate (kbps), loss,
    /// one-way delay and timestamps so the server can size its encoder to us.
    private func sendAppleMediaRCTLFeedback() async {
        guard !appleMediaFeedbackRoutes.isEmpty else { return }

        let targets: [(AppleMediaFeedbackRoute, [PosixUDPChannel])]
        if appleMediaFeedbackRouteByRemoteSSRC.isEmpty {
            targets = appleMediaFeedbackRoutes.map { ($0, udpChannels) }
        } else {
            var resolved: [(AppleMediaFeedbackRoute, [PosixUDPChannel])] =
                appleMediaFeedbackRouteByRemoteSSRC.compactMap { remoteSSRC, route in
                guard let channel = appleMediaVideoSSRCChannels[remoteSSRC] else { return nil }
                return (route, [channel])
            }
            let resolvedStreams = Set(resolved.map { $0.0.streamIndex })
            resolved.append(contentsOf: appleMediaFeedbackRoutes
                .filter { !resolvedStreams.contains($0.streamIndex) }
                .map { ($0, udpChannels) })
            targets = resolved
        }
        guard targets.contains(where: { !$0.1.isEmpty }) else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let intervalPackets = appleRCTLPacketsInterval
        let intervalLost = appleRCTLLostInterval
        let burst = appleRCTLBurstLostInterval
        appleRCTLPacketsInterval = 0
        appleRCTLLostInterval = 0
        appleRCTLBurstLostInterval = 0

        let nowSeconds = Double(now) / 1_000_000_000
        if let controller = appleMediaRateController {
            controller.update(now: nowSeconds)
        }

        // RCTL carries estimated receive capacity. It is the feedback input to
        // the peer's encoder controller, not an observed activity bitrate.
        let estimatedKbps = rateControlEnabled
            ? Double(appleMediaRateController?.bandwidthEstimateBps
                ?? UInt32(appleMediaRateControllerMaxBps)) / 1_000
            : 65_535
        let bweKbps = runtimeEnvironment["ROOTSHELL_VNC_RCTL_BWE_KBPS"]
            .flatMap(Double.init) ?? estimatedKbps
        let bwe = UInt16(min(65_535, max(0, bweKbps.rounded())))

        let burstyLoss = UInt8(min(15, burst))
        let lossPercent = appleMediaRCTLIntervalLossPercent(
            received: intervalPackets,
            lost: intervalLost)
        let cumulativeReceivedPacketCount = UInt16(
            truncatingIfNeeded: appleRCTLTotalPacketsReceived)
        let owrdSeconds = appleMediaRateController?.owrdSeconds ?? 0
        let owrd = UInt16(min(65535, (owrdSeconds * 8192).rounded()))
        let ts = UInt16(truncatingIfNeeded: Int(nowSeconds * 1024))          // Q10 s
        let echo = appleMediaLastRTPEchoTimestampQ10
        let ageMilliseconds = appleRCTLEchoTimestampArrivalNanos == 0
            ? 0
            : (now &- appleRCTLEchoTimestampArrivalNanos) / 1_000_000
        let age = UInt16(min(UInt64(UInt16.max), ageMilliseconds))
        let feedback = AppleMediaRCTLFeedback(
            lossPercent: lossPercent,
            echoTimestamp: echo,
            measurementAgeMilliseconds: age,
            localTimestampQ10: ts,
            owrdQ13: owrd,
            burstyLoss: burstyLoss,
            cumulativeReceivedPacketCount: cumulativeReceivedPacketCount,
            bandwidthEstimateKbps: bwe)

        if intervalLost > 0 {
            log.warning(
                "RCTL congestion feedback bwe=\(bwe)kbps receivedPackets="
                    + "\(intervalPackets) lostPackets=\(intervalLost) "
                    + "loss=\(lossPercent)% burst=\(burstyLoss)")
        }

        if appleRCTLLastDiagnosticNanos == 0
            || now &- appleRCTLLastDiagnosticNanos >= 1_000_000_000 {
            appleRCTLLastDiagnosticNanos = now
            let receivedKbps = Int(
                (appleMediaRateController?.throughputBps(now: nowSeconds) ?? 0) / 1_000)
            let queuePeakMilliseconds = Int(
                (appleMediaRateController?.peakQueueDelaySeconds ?? 0) * 1_000)
            let ingressPackets = appleMediaIngressPacketsSinceDiagnostic
            let ingressProcessingMilliseconds =
                appleMediaIngressProcessingNanosSinceDiagnostic / 1_000_000
            let ingressMaximumBatch = appleMediaIngressMaximumBatchSinceDiagnostic
            appleMediaIngressPacketsSinceDiagnostic = 0
            appleMediaIngressProcessingNanosSinceDiagnostic = 0
            appleMediaIngressMaximumBatchSinceDiagnostic = 0
            log.info(
                "RCTL bwe=\(bwe)kbps received=\(receivedKbps)kbps "
                    + "echoQ10=\(echo) age=\(age)ms loss=\(lossPercent)% "
                    + "burst=\(burstyLoss) "
                    + "packetCount=\(cumulativeReceivedPacketCount & 0x0fff) "
                    + "ingressQueuePeak=\(queuePeakMilliseconds)ms "
                    + "ingressPackets=\(ingressPackets) ingressCPU="
                    + "\(ingressProcessingMilliseconds)ms maxBatch=\(ingressMaximumBatch) "
                    + "reorderQueued=\(appleMediaRTPReorderBuffer.queuedPacketCount)")
        }

        // The feedback-only profile sends an RCTL APP packet by itself;
        // ordinary Receiver Reports have their own 1 Hz loop below.
        for (route, channels) in targets {
            let app = appleMediaRCTLPacket(
                senderSSRC: route.localSSRC,
                feedback: feedback)
            guard let protected = try? route.sendRTCPContext.protect(
                app,
                senderSSRC: route.localSSRC) else { continue }
            dumpAppleMediaOutgoingRTCPIfRequested(
                plaintext: app,
                protected: protected)
            // Before RTP identifies the display socket, send each display's
            // own SRTCP packet on every candidate. Afterwards the authenticated
            // receive mapping selects one route and one channel.
            for channel in channels {
                try? await channel.send(protected)
            }
        }

    }

    /// Ceiling for the receive-capacity estimator (bps). The bearer only sets
    /// the initial prior; the ceiling is the 60 Mbps negotiated screen tier on
    /// every path. RCTL serializes kbps as UInt16; estimates above that only
    /// delay a later loss response because several reductions would still
    /// encode as the same saturated value.
    private var appleMediaRateControllerMaxBps: Double {
        AppleMediaRateController.nativeScreenMaximumBitrateBps
    }

    private func sendAppleMediaReceiverReport() async {
        for (mediaSSRC, channel) in appleMediaVideoSSRCChannels {
            guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC),
                  let rr = buildAppleMediaReceiverReport(
                    senderSSRC: route.localSSRC,
                    mediaSSRC: mediaSSRC),
                  let protected = try? route.sendRTCPContext.protect(
                    rr,
                    senderSSRC: route.localSSRC) else { continue }
            try? await channel.send(protected)
        }
    }

    /// Build an RTCP Receiver Report (RFC 3550) reporting reception quality for
    /// each video source, so the server's congestion controller can size the
    /// bitrate to the link.
    private func buildAppleMediaReceiverReport(
        senderSSRC: UInt32,
        mediaSSRC: UInt32? = nil
    ) -> Data? {
        let sources = appleMediaReceptionStats.filter { ssrc, stats in
            stats.initialized && (mediaSSRC == nil || mediaSSRC == ssrc)
        }
        guard !sources.isEmpty else { return nil }

        let now = DispatchTime.now().uptimeNanoseconds
        let dlsr: UInt32
        if appleMediaLastSRArrivalNanos > 0 {
            let elapsed = now &- appleMediaLastSRArrivalNanos
            dlsr = UInt32(truncatingIfNeeded: (elapsed &* 65_536) / 1_000_000_000)
        } else {
            dlsr = 0
        }

        let reportCount = min(sources.count, 31)
        let lengthWords = 1 + 6 * reportCount // total 32-bit words - 1

        var rr = Data()
        rr.append(0x80 | UInt8(reportCount)) // V=2, P=0, RC
        rr.append(201) // PT = Receiver Report
        rr.append(UInt8((lengthWords >> 8) & 0xff))
        rr.append(UInt8(lengthWords & 0xff))
        appendUInt32BE(senderSSRC, to: &rr)

        for (ssrc, original) in sources.prefix(reportCount) {
            var stats = original
            let extendedMax = stats.cycles | UInt32(stats.maxSeq)
            let expected = extendedMax &- stats.baseSeq &+ 1
            let expectedInterval = expected &- stats.expectedPrior
            let receivedInterval = stats.received &- stats.receivedPrior
            let lostInterval = Int64(expectedInterval) - Int64(receivedInterval)
            var fraction: UInt8 = 0
            if expectedInterval != 0 && lostInterval > 0 {
                let ratio: Int64 = (lostInterval << 8) / Int64(expectedInterval)
                fraction = UInt8(min(Int64(255), ratio))
            }
            let cumulativeSigned: Int64 = Int64(expected) - Int64(stats.received)
            let cumulativeLost = UInt32(max(Int64(0), min(cumulativeSigned, Int64(0xff_ffff))))

            stats.expectedPrior = expected
            stats.receivedPrior = stats.received
            appleMediaReceptionStats[ssrc] = stats

            appendUInt32BE(ssrc, to: &rr)
            appendUInt32BE((UInt32(fraction) << 24) | cumulativeLost, to: &rr)
            appendUInt32BE(extendedMax, to: &rr)
            appendUInt32BE(0, to: &rr) // interarrival jitter (RTP timestamps are 0; not meaningful)
            appendUInt32BE(appleMediaLastSRLSR, to: &rr)
            appendUInt32BE(dlsr, to: &rr)
        }
        return rr
    }

    private nonisolated func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private nonisolated func appleMediaRTPSSRC(_ datagram: Data) -> UInt32? {
        guard datagram.count >= 12 else { return nil }
        let base = datagram.startIndex
        guard (datagram[base] >> 6) == 2 else { return nil }
        return UInt32(datagram[base + 8]) << 24
            | UInt32(datagram[base + 9]) << 16
            | UInt32(datagram[base + 10]) << 8
            | UInt32(datagram[base + 11])
    }

    private nonisolated func dumpAppleMediaSRTPKeysIfRequested(_ keys: [Data]) {
        guard let path = runtimeEnvironment["ROOTSHELL_VNC_DUMP_SRTP_KEYS"] else { return }
        var blob = Data()
        for key in keys {
            blob.append(UInt8(key.count))
            blob.append(key)
        }
        try? blob.write(to: URL(fileURLWithPath: path))
    }

    private nonisolated func dumpAppleMediaUDPDatagramIfRequested(_ datagram: Data) {
        guard let path = appleMediaUDPDatagramDumpPath else { return }
        var framed = Data()
        framed.append(UInt8((datagram.count >> 8) & 0xFF))
        framed.append(UInt8(datagram.count & 0xFF))
        framed.append(datagram)
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: framed)
            try? handle.close()
        } else {
            try? framed.write(to: URL(fileURLWithPath: path))
        }
    }

    private nonisolated func isAppleMediaRTCPPacket(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let packetType = data[data.startIndex + 1]
        return packetType >= 192 && packetType <= 223
    }
}

private extension UUID {
    var bytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}
