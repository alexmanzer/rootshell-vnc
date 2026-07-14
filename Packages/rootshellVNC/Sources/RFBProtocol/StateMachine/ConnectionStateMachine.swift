import Foundation

/// A pure, synchronous state machine for the RFB connection lifecycle.
///
/// Given the current state and an event, `handle(event:)` returns a list
/// of actions the transport layer should perform and transitions the
/// internal state accordingly.
///
/// This type has no I/O dependencies and is safe to use from any context.
public struct ConnectionStateMachine: Sendable {

    // MARK: - State

    /// The current connection state.
    public private(set) var state: ConnectionState = .idle

    /// The negotiated protocol version (set after version exchange).
    public private(set) var negotiatedVersion: ProtocolVersion?

    /// The security type selected during handshake.
    public private(set) var selectedSecurityType: SecurityType?

    /// The server's initialization info (set after ServerInit).
    public private(set) var serverInit: ServerInit?

    /// Current framebuffer geometry. Unlike `serverInit`, these values track
    /// successful DesktopSize changes for all later update requests.
    public private(set) var framebufferWidth: UInt16 = 0
    public private(set) var framebufferHeight: UInt16 = 0

    /// The preferred pixel format to request from the server.
    public var preferredPixelFormat: PixelFormat

    /// The preferred encoding list to request from the server.
    public var preferredEncodings: [Encoding]

    public var securityPolicy: VNCSecurityPolicy
    public var hasUsername: Bool

    public static let defaultPreferredEncodings: [Encoding] = [
        // Prefer copyRect (cheap) then raw (simple, reliable).
        // ZRLE/Zlib are available through the renderer but left to higher-level
        // configuration so tests and callers can choose their own risk profile.
        .copyRect, .raw,
        // Pseudo-encodings (informational, server-initiated).
        .cursor, .desktopSize, .extendedDesktopSize,
        .encryptionInfo, .serverDisplayInfo,
        .mediaStreamOffer, .mediaStreamAnswer,
    ]

    // MARK: - Init

    public init(
        preferredPixelFormat: PixelFormat = .bgra8888,
        preferredEncodings: [Encoding] = ConnectionStateMachine.defaultPreferredEncodings,
        securityPolicy: VNCSecurityPolicy = .automatic,
        hasUsername: Bool = false
    ) {
        self.preferredPixelFormat = preferredPixelFormat
        self.preferredEncodings = preferredEncodings
        self.securityPolicy = securityPolicy
        self.hasUsername = hasUsername
    }

    // MARK: - Event handling

    /// Process an event and return the actions the transport layer should perform.
    public mutating func handle(event: ConnectionEvent) -> [ConnectionAction] {
        switch (state, event) {

        // MARK: idle / connecting → waitingForProtocolVersion

        case (.idle, .connected):
            state = .waitingForProtocolVersion
            return []

        case (.connecting, .connected):
            state = .waitingForProtocolVersion
            return []

        // MARK: waitingForProtocolVersion → waitingForSecurityTypes

        case (.waitingForProtocolVersion, .receivedProtocolVersion(let serverVersion)):
            let ourVersion: ProtocolVersion
            if serverVersion.isApple {
                // Apple ARD: echo back their version to activate Apple extensions.
                ourVersion = serverVersion
            } else if serverVersion.isAtLeast(.v3_8) {
                ourVersion = .v3_8
            } else if serverVersion.isAtLeast(.v3_7) {
                ourVersion = .v3_7
            } else if serverVersion.isAtLeast(.v3_3) {
                ourVersion = .v3_3
            } else {
                state = .failed(.unsupportedVersion)
                return [.reportError(.unsupportedVersion)]
            }

            negotiatedVersion = ourVersion
            state = .waitingForSecurityTypes
            return [.sendProtocolVersion(ourVersion)]

        // MARK: waitingForSecurityTypes → authenticating / waitingForAuthResult

        case (.waitingForSecurityTypes, .receivedSecurityTypes(let types)):
            guard !types.isEmpty else {
                let error = VNCProtocolError.authenticationFailed("Server offered no security types")
                state = .failed(error)
                return [.reportError(error)]
            }

            guard let selected = selectBestSecurityType(from: types) else {
                let error = VNCProtocolError.authenticationFailed(
                    "The server does not offer the requested security method")
                state = .failed(error)
                return [.reportError(error)]
            }
            selectedSecurityType = selected

            switch selected {
            case .none:
                // No authentication needed.
                // For 3.8+ the server still sends a SecurityResult.
                // For 3.3/3.7 it may go straight to ServerInit.
                if let v = negotiatedVersion, v.isAtLeast(.v3_8) {
                    state = .waitingForAuthResult
                    return [.sendSecurityType(selected)]
                } else {
                    state = .waitingForServerInit
                    return [.sendSecurityType(selected), .requestServerInit]
                }

            default:
                state = .authenticating(selected)
                return [.sendSecurityType(selected)]
            }

        case (.waitingForSecurityTypes, .receivedServerSelectedSecurityType(let selected)):
            guard securityTypeIsAllowed(selected) else {
                let error = VNCProtocolError.authenticationFailed(
                    "The server selected a security method that violates the configured policy")
                state = .failed(error)
                return [.reportError(error)]
            }
            selectedSecurityType = selected
            switch selected {
            case .none:
                state = .waitingForServerInit
                return [.requestServerInit]
            default:
                state = .authenticating(selected)
                return []
            }

        // MARK: authenticating

        case (.authenticating(let secType), .receivedAuthChallenge(let challenge)):
            return [.performAuthentication(secType, challenge)]

        case (.authenticating, .authenticationSucceeded):
            state = .waitingForServerInit
            return [.requestServerInit]

        case (.authenticating, .authenticationFailed(let reason)):
            let error = VNCProtocolError.authenticationFailed(reason)
            state = .failed(error)
            return [.reportError(error)]

        // MARK: waitingForAuthResult

        case (.waitingForAuthResult, .authenticationSucceeded):
            state = .waitingForServerInit
            return [.requestServerInit]

        case (.waitingForAuthResult, .authenticationFailed(let reason)):
            let error = VNCProtocolError.authenticationFailed(reason)
            state = .failed(error)
            return [.reportError(error)]

        // MARK: waitingForServerInit → operational

        case (.waitingForServerInit, .receivedServerInit(let si)):
            serverInit = si
            framebufferWidth = si.framebufferWidth
            framebufferHeight = si.framebufferHeight
            state = .operational

            return [
                .sendSetPixelFormat(preferredPixelFormat),
                .sendSetEncodings(preferredEncodings),
                .sendFramebufferUpdateRequest(
                    incremental: false,
                    width: si.framebufferWidth,
                    height: si.framebufferHeight
                ),
            ]

        // MARK: operational

        case (.operational, .receivedFramebufferUpdate(let rects)):
            if let resize = rects.last(where: \.isSuccessfulDesktopResize) {
                framebufferWidth = resize.width
                framebufferHeight = resize.height
            }
            var actions: [ConnectionAction] = [.updateFramebuffer(rects)]
            if framebufferWidth > 0, framebufferHeight > 0 {
                actions.append(.sendFramebufferUpdateRequest(
                    incremental: true,
                    width: framebufferWidth,
                    height: framebufferHeight
                ))
            }
            return actions

        case (.operational, .receivedBell):
            return [.notifyBell]

        case (.operational, .receivedServerCutText(let text)):
            return [.notifyClipboard(text)]

        case (.operational, .receivedEncryptionInfo):
            return [.sendEncryptionResponse]

        case (.operational, .receivedAppleDisplayInfo):
            // Display info is informational; no response action needed.
            return []

        case (.operational, .receivedMediaStreamOffer(let offer)):
            let answer = AppleMediaStreamAnswer(streamID: offer.streamID, accepted: true)
            return [.sendMediaStreamAnswer(answer)]

        // MARK: disconnect (from any state)

        case (_, .userRequestedDisconnect):
            state = .disconnecting
            return [.disconnect]

        case (_, .connectionLost(let error)):
            state = .failed(error)
            return [.reportError(error)]

        // MARK: unexpected events

        default:
            return [.reportError(.unexpectedMessage)]
        }
    }

    // MARK: - Helpers

    /// Transition from idle to connecting (for callers that track
    /// the TCP establishment separately).
    public mutating func beginConnecting() {
        state = .connecting
    }

    // MARK: - Security type selection

    private func selectBestSecurityType(from types: [SecurityType]) -> SecurityType? {
        // A diagnostic override must never downgrade an explicitly encrypted
        // session. Handle this policy before consulting process state.
        if securityPolicy == .requireEncryption {
            return types.contains(.vencrypt) ? .vencrypt : nil
        }

        if let forced = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_SECURITY_TYPE"] {
            let selected: SecurityType? = {
                switch forced.lowercased() {
                case "none": return SecurityType.none
                case "vnc", "vncAuthentication".lowercased(): return .vncAuthentication
                case "apple30", "dh": return .apple30
                case "mac", "macAuthentication".lowercased(), "type33": return .macAuthentication
                default:
                    if let raw = UInt8(forced) {
                        return SecurityType(rawValue: raw)
                    }
                    return nil
                }
            }()
            if let selected, types.contains(selected) {
                return selected
            }
        }

        switch securityPolicy {
        case .none:
            return types.contains(.none) ? SecurityType.none : nil
        case .vncAuthentication:
            return types.contains(.vncAuthentication) ? .vncAuthentication : nil
        case .apple30:
            return types.contains(.apple30) ? .apple30 : nil
        case .macAuthentication:
            return types.contains(.macAuthentication) ? .macAuthentication : nil
        case .requireEncryption:
            // Handled before diagnostic overrides above.
            return types.contains(.vencrypt) ? .vencrypt : nil
        case .automatic:
            if negotiatedVersion?.isApple == true, hasUsername {
                if types.contains(.macAuthentication) { return .macAuthentication }
                if types.contains(.apple30) { return .apple30 }
            }
            // TigerVNC commonly offers anonymous TLSVnc alongside VncAuth.
            // NIOSSL cannot negotiate anonymous cipher suites, so take the
            // interoperable choice when both outer types are present. X509-
            // only servers (including secured wayvnc) still select VeNCrypt.
            if types.contains(.vncAuthentication) { return .vncAuthentication }
            if types.contains(.vencrypt) { return .vencrypt }
            if types.contains(.none) { return SecurityType.none }
            return nil
        }
    }

    /// RFB 3.3 does not let the client choose a type, but a server-selected
    /// type still has to satisfy the user's policy before any authentication
    /// or ClientInit bytes are sent.
    private func securityTypeIsAllowed(_ type: SecurityType) -> Bool {
        switch securityPolicy {
        case .requireEncryption:
            return type == .vencrypt
        case .none:
            return type == .none
        case .vncAuthentication:
            return type == .vncAuthentication
        case .apple30:
            return type == .apple30
        case .macAuthentication:
            return type == .macAuthentication
        case .automatic:
            switch type {
            case .none, .vncAuthentication, .vencrypt, .apple30, .macAuthentication:
                return true
            default:
                return false
            }
        }
    }
}
