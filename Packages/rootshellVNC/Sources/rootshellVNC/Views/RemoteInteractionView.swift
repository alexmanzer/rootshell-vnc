#if canImport(UIKit)
import SwiftUI
import UIKit
#if targetEnvironment(macCatalyst)
import AppKit
#endif
import RFBProtocol
import RFBRendering
import GameController

/// Transparent UIKit input surface shared by Adaptive and Full Quality modes.
/// UIKit is used here because SwiftUI gestures do not expose mouse buttons,
/// hover, scroll-wheel events, touch counts, or key-up events consistently.
struct RemoteInteractionView: UIViewRepresentable {
    @Binding var viewport: RemoteViewportState
    let viewportPanningMode: RemoteViewportPanningMode
    @Binding var keyboardActive: Bool
    @Binding var hardwareKeyboardAttached: Bool

    let framebufferSize: CGSize
    let touchHandler: TouchInputHandler
    let keyboardHandler: KeyboardInputHandler
    let keyboardCapture: VNCKeyboardCapture
    let framebufferOrigin: CGPoint
    let requestPasswordSend: () -> Void
    let requestDictation: () -> Void
    let toggleFullScreen: (() -> Void)?
    let disconnect: () -> Void
    let remoteCursor: RemoteCursor?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> RemoteInputUIView {
        let view = RemoteInputUIView(
            touchHandler: touchHandler,
            keyboardHandler: keyboardHandler,
            keyboardCapture: keyboardCapture,
            requestPasswordSend: requestPasswordSend,
            requestDictation: requestDictation,
            toggleFullScreen: toggleFullScreen,
            disconnect: disconnect)
        view.onViewportChange = { [weak coordinator = context.coordinator] state in
            coordinator?.parent.viewport = state
        }
        view.onKeyboardActiveChange = { [weak coordinator = context.coordinator] active in
            coordinator?.parent.keyboardActive = active
        }
        view.onHardwareKeyboardAttachedChange = {
            [weak coordinator = context.coordinator] attached in
            guard let coordinator else { return }
            coordinator.parent.hardwareKeyboardAttached = attached
            if attached {
                coordinator.parent.keyboardActive = false
            }
        }
        DispatchQueue.main.async { [weak view] in
            view?.publishHardwareKeyboardAvailability()
        }
        return view
    }

    func updateUIView(_ uiView: RemoteInputUIView, context: Context) {
        context.coordinator.parent = self
        uiView.update(
            framebufferSize: framebufferSize,
            viewport: viewport,
            viewportPanningMode: viewportPanningMode,
            keyboardActive: keyboardActive,
            keyboardCaptured: keyboardCapture.isCaptured,
            inputViewsGeneration: keyboardCapture.inputViewsGeneration,
            framebufferOrigin: framebufferOrigin,
            requestPasswordSend: requestPasswordSend,
            requestDictation: requestDictation,
            toggleFullScreen: toggleFullScreen,
            disconnect: disconnect,
            remoteCursor: remoteCursor)
    }

    @MainActor
    final class Coordinator {
        var parent: RemoteInteractionView

        init(parent: RemoteInteractionView) {
            self.parent = parent
        }
    }
}

@MainActor
final class RemoteInputUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate,
    UIPointerInteractionDelegate {
    var onViewportChange: ((RemoteViewportState) -> Void)?
    var onKeyboardActiveChange: ((Bool) -> Void)?
    var onHardwareKeyboardAttachedChange: ((Bool) -> Void)?

    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler
    private let keyboardCapture: VNCKeyboardCapture
    private var requestPasswordSend: () -> Void
    private var requestDictation: () -> Void
    private var toggleFullScreen: (() -> Void)?
    private var disconnect: () -> Void
    private lazy var hardwareKeyboard = HardwareKeyboardController(
        keyboardHandler: keyboardHandler)
    private var framebufferSize: CGSize = .zero
    private var framebufferOrigin: CGPoint = .zero
    private var viewport = RemoteViewportState()
    private var viewportPanningMode = RemoteViewportPanningMode.edge
    private var softwareKeyboardRequested = false
    private var lastSeenInputViewsGeneration: UInt64 = 0
    private var lastPointerPoint: (x: UInt16, y: UInt16)?
    private var remoteCursor: RemoteCursor?
    private var pointerDragActive = false
    private var touchHoldDragLastPoint: (x: UInt16, y: UInt16)?
    private var touchHoldDragActive = false
    private var lastKnownFramebufferPoint: (x: UInt16, y: UInt16)?
    private var lastScrollPoint: (x: UInt16, y: UInt16)?
    private var scrollPointAccumulator = ScrollPointAccumulator()
    private var wheelUnitAccumulator = ScrollWheelUnitAccumulator()
    private var horizontalScrollIntentFilter = HorizontalScrollIntentFilter()
    private var previousScrollTranslation = CGPoint.zero
    private var directScrollPhaseActive = false
    private var momentumScrollPhaseActive = false
    private weak var activeScrollRecognizer: UIGestureRecognizer?
    private var activeScrollUsesDirectTouch = false
    private var releaseVelocityEstimator = ScrollReleaseVelocityEstimator()
    private var previousScrollTimestamp: CFTimeInterval = 0
    private var syntheticMomentumVelocity = CGPoint.zero
    private var syntheticMomentumLastTimestamp: CFTimeInterval = 0
    private var momentumDisplayLink: CADisplayLink?
    private var edgeScrollPointerLocation: CGPoint?
    private var edgeScrollLastTimestamp: CFTimeInterval = 0
    private var edgeScrollIsDragging = false
    private var edgeScrollDisplayLink: CADisplayLink?
    private var hoverUsesIndirectPointer = true
    private var pointerDragUsesIndirectPointer = true
    /// A direct touch that lands during a fling catches it, exactly like
    /// touching a decelerating native scroll view: the fling stops and that
    /// touch must never click or hold-drag. Set at the catching touch-down,
    /// cleared by the next touch-down or by whichever recognizer consumes it.
    private var momentumCatchPending = false
    private var momentumCatchTimestamp: CFTimeInterval = 0
    private let suppressedInputView = UIView(frame: .zero)
    private var consumedRemoteAliasUsages: Set<UInt32> = []
    /// Supplemental toolbar modifiers held around each physical key until its
    /// matching key-up. Reference counts keep overlapping physical presses
    /// from releasing a shared synthetic modifier too early.
    private var supplementalModifierState = SupplementalHardwareModifierState()
    private weak var monitoredCatalystKeyboardInput: GCKeyboardInput?
    #if DEBUG
    private let inputLog = VNCLogger(category: "InputRouting")
    private var inputLogBudget = 128
    #endif

    private lazy var scrollRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleNativeScrollState(_:)))
    private lazy var directTouchRecognizer: DirectTouchGestureRecognizer = {
        let recognizer = DirectTouchGestureRecognizer(
            target: self,
            action: #selector(handleDirectTouchState(_:)))
        recognizer.onTouchDown = { [weak self] location in
            guard let self else { return false }
            if self.catchMomentumFlingIfActive() {
                self.momentumCatchPending = true
                self.momentumCatchTimestamp = CACurrentMediaTime()
                return true
            }
            self.momentumCatchPending = false
            self.momentumCatchTimestamp = 0
            self.positionRemotePointerForTouch(at: location)
            return false
        }
        return recognizer
    }()
    private lazy var pinchRecognizer = UIPinchGestureRecognizer(
        target: self,
        action: #selector(handlePinch(_:)))
    private lazy var viewportPanRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleViewportPan(_:)))
    private lazy var pointerDragRecognizer = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handlePointerDrag(_:)))
    private lazy var tapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleTap(_:)))
    private lazy var doubleTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleDoubleTap(_:)))
    private lazy var rightTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleRightTap(_:)))
    private lazy var hoverRecognizer = UIHoverGestureRecognizer(
        target: self,
        action: #selector(handleHover(_:)))
    private lazy var pointerInteraction = UIPointerInteraction(delegate: self)
    #if targetEnvironment(macCatalyst)
    private lazy var secondaryClickInteraction = UIContextMenuInteraction(delegate: self)
    private var catalystCursor: NSCursor?
    private var catalystCursorDisplayScale: CGFloat = 0
    #else
    /// UIPointerShape outlines every scanline in a bitmap silhouette, which
    /// makes detailed macOS cursors look striped or duplicated on iPad. Keep
    /// one ordinary image view under the locally tracked pointer instead.
    private lazy var remoteCursorImageView: UIImageView = {
        let imageView = UIImageView(frame: .zero)
        imageView.isHidden = true
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleToFill
        imageView.layer.magnificationFilter = .linear
        imageView.layer.minificationFilter = .linear
        return imageView
    }()
    private var remoteCursorHoverLocation: CGPoint?
    #endif

    override var keyCommands: [UIKeyCommand]? {
        guard keyboardCapture.isCaptured else { return viewerCommandKeyCommands }
        #if targetEnvironment(macCatalyst)
        return reservedHostKeyCommands
            + standardRemoteKeyCommands
            + remoteNavigationKeyCommands
            + viewerCommandKeyCommands
            + remoteControlKeyCommands
        #else
        return reservedHostKeyCommands
            + commandCompatibilityKeyCommands
            + standardRemoteKeyCommands
            + remoteNavigationKeyCommands
            + viewerCommandKeyCommands
            + remoteCommandKeyCommands
        #endif
    }

    /// Explicit commands for the small set of chords owned by a containing
    /// app. Keeping these on the focused VNC responder avoids relying on menu
    /// command arbitration, which is not consistent across iPad and Catalyst.
    private lazy var reservedHostKeyCommands: [UIKeyCommand] = {
        keyboardCapture.reservedHostShortcuts.flatMap { shortcut in
            var signatures = [(
                input: shortcut.input,
                modifiers: Self.uiModifiers(for: shortcut.modifiers)
            )]

            // UIKit reports shifted punctuation differently by platform:
            // iPad commonly uses "[" + Shift while Catalyst menu commands use
            // "{" without Shift for the same physical key. Claim both forms.
            if shortcut.modifiers.contains(.shift),
               let shiftedInput = Self.shiftedHostShortcutInput(shortcut.input) {
                var modifiers = Self.uiModifiers(for: shortcut.modifiers)
                modifiers.remove(.shift)
                signatures.append((shiftedInput, modifiers))
            }

            return signatures.map { signature in
                let command = UIKeyCommand(
                    input: signature.input,
                    modifierFlags: signature.modifiers,
                    action: #selector(handleReservedHostShortcut(_:)))
                command.wantsPriorityOverSystemBehavior = true
                command.allowsAutomaticLocalization = false
                return command
            }
        }
    }()

    private lazy var commandCompatibilityKeyCommands: [UIKeyCommand] = {
        [
            ("h", String(localized: "Command-H", bundle: .module)),
            ("m", String(localized: "Command-M", bundle: .module)),
        ].map { input, title in
            let command = UIKeyCommand(
                input: input,
                modifierFlags: [.control, .alternate],
                action: #selector(handleCommandCompatibilityAlias(_:)))
            command.discoverabilityTitle = title
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            return command
        }
    }()

    private lazy var standardRemoteKeyCommands: [UIKeyCommand] = {
        RemoteCommand.allCases.filter { remoteCommand in
            !isReservedHostShortcut(
                input: Self.uiInput(for: remoteCommand.shortcut.input),
                modifiers: Self.uiModifiers(for: remoteCommand.shortcut.modifiers))
        }.map { remoteCommand in
            let command = UIKeyCommand(
                input: Self.uiInput(for: remoteCommand.shortcut.input),
                modifierFlags: Self.uiModifiers(
                    for: remoteCommand.shortcut.modifiers),
                action: #selector(handleStandardRemoteCommand(_:)))
            command.discoverabilityTitle = remoteCommand.title
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            return command
        }
    }()

    /// Arrow keys are navigation commands to UIKit, so they may be consumed
    /// by the focus system before a hardware `UIPress` reaches this view.
    /// Explicitly claiming the unmodified variants keeps them on the VNC
    /// responder path while keyboard capture is active.
    private lazy var remoteNavigationKeyCommands: [UIKeyCommand] = {
        [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
        ].map { input in
            let command = UIKeyCommand(
                input: input,
                modifierFlags: [],
                action: #selector(handleRemoteNavigationKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            return command
        }
    }()

    private lazy var viewerCommandKeyCommands: [UIKeyCommand] = [
        makeViewerCommand(
            title: String(localized: "Type User Password", bundle: .module),
            input: "p",
            modifiers: [.control, .shift],
            action: #selector(handlePasswordCommand(_:))),
        makeViewerCommand(
            title: String(localized: "Dictate", bundle: .module),
            input: "l",
            modifiers: [.control, .alternate],
            action: #selector(handleDictationCommand(_:))),
        makeViewerCommand(
            title: String(localized: "Toggle Full Screen", bundle: .module),
            input: "f",
            modifiers: [.control, .shift],
            action: #selector(handleFullScreenCommand(_:))),
        makeViewerCommand(
            title: String(localized: "Close Connection", bundle: .module),
            input: "q",
            modifiers: [.alternate, .command],
            action: #selector(handleDisconnectCommand(_:))),
    ]

    private func makeViewerCommand(
        title: String,
        input: String,
        modifiers: UIKeyModifierFlags,
        action: Selector
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifiers,
            action: action)
        command.discoverabilityTitle = title
        command.wantsPriorityOverSystemBehavior = true
        command.allowsAutomaticLocalization = false
        return command
    }

    #if targetEnvironment(macCatalyst)

    private lazy var remoteControlKeyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        let inputs = "abcdefghijklmnopqrstuvwxyz0123456789 -=[]\\;',./`"
        for input in inputs {
            for modifiers: UIKeyModifierFlags in [.control, [.control, .shift]] {
                if Self.isReservedViewerShortcut(
                    input: String(input),
                    modifiers: modifiers
                ) || Self.isStandardRemoteShortcut(
                    input: String(input),
                    modifiers: modifiers
                ) || isReservedHostShortcut(
                    input: String(input),
                    modifiers: modifiers
                ) {
                    continue
                }
                let command = UIKeyCommand(
                    input: String(input),
                    modifierFlags: modifiers,
                    action: #selector(handleControlKeyCommand(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        for input in [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
        ] {
            let command = UIKeyCommand(
                input: input,
                modifierFlags: .control,
                action: #selector(handleControlKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }()
    #else
    private lazy var remoteCommandKeyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        let inputs = "abcdefghijklmnopqrstuvwxyz0123456789 -=[]\\;',./`"
        let modifierVariants: [UIKeyModifierFlags] = [
            .command,
            [.command, .shift],
            [.command, .alternate],
            [.command, .control],
            [.command, .shift, .alternate],
            [.command, .shift, .control],
            [.command, .alternate, .control],
            [.command, .shift, .alternate, .control],
        ]

        // Declare iPadOS app-management shortcuts first. Command-H (Home) and
        // Command-M (Minimize) otherwise compete with system behavior before
        // UIKit delivers ordinary presses to the remote input view.
        for input in ["h", "m"] {
            commands.append(makeRemoteCommand(input: input, modifiers: .command))
        }

        for input in inputs {
            for modifiers in modifierVariants {
                if Self.isReservedViewerShortcut(
                    input: String(input),
                    modifiers: modifiers)
                    || isReservedHostShortcut(
                        input: String(input),
                        modifiers: modifiers)
                    || (modifiers == .command && (input == "h" || input == "m")) {
                    continue
                }
                commands.append(makeRemoteCommand(
                    input: String(input),
                    modifiers: modifiers))
            }
        }
        return commands
    }()

    private func makeRemoteCommand(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifiers,
            action: #selector(handleRemoteCommandKey(_:)))
        command.wantsPriorityOverSystemBehavior = true
        command.allowsAutomaticLocalization = false
        return command
    }
    #endif

    init(
        touchHandler: TouchInputHandler,
        keyboardHandler: KeyboardInputHandler,
        keyboardCapture: VNCKeyboardCapture,
        requestPasswordSend: @escaping () -> Void,
        requestDictation: @escaping () -> Void,
        toggleFullScreen: (() -> Void)?,
        disconnect: @escaping () -> Void
    ) {
        self.touchHandler = touchHandler
        self.keyboardHandler = keyboardHandler
        self.keyboardCapture = keyboardCapture
        self.requestPasswordSend = requestPasswordSend
        self.requestDictation = requestDictation
        self.toggleFullScreen = toggleFullScreen
        self.disconnect = disconnect
        self.lastSeenInputViewsGeneration = keyboardCapture.inputViewsGeneration
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityLabel = String(localized: "Remote desktop input", bundle: .module)
        configureRecognizers()
        #if targetEnvironment(macCatalyst)
        // Catalyst surfaces a trackpad secondary click as a touchless button
        // event that only the context-menu machinery consumes — it never
        // reaches touchesBegan or tap recognizers, even with buttonMaskRequired.
        addInteraction(secondaryClickInteraction)
        #else
        addInteraction(pointerInteraction)
        addSubview(remoteCursorImageView)
        #endif
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: UIWindow.didResignKeyNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(softwareKeyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(softwareKeyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidConnect(_:)),
            name: .GCKeyboardDidConnect,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidDisconnect(_:)),
            name: .GCKeyboardDidDisconnect,
            object: nil)
        #if targetEnvironment(macCatalyst)
        configureCatalystKeyboardMonitor(for: GCKeyboard.coalesced)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func publishHardwareKeyboardAvailability() {
        onHardwareKeyboardAttachedChange?(GCKeyboard.coalesced != nil)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        releaseAllPressedKeys()
        return super.resignFirstResponder()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            releasePointerDrag()
            releaseAllPressedKeys()
            cancelScrollInteraction()
            stopEdgeScrolling()
            #if !targetEnvironment(macCatalyst)
            remoteCursorHoverLocation = nil
            remoteCursorImageView.isHidden = true
            #endif
        }
        super.willMove(toWindow: newWindow)
    }

    /// Suppress the software keyboard while retaining hardware-keyboard focus
    /// after mouse/trackpad interaction. The explicit keyboard button switches
    /// this back to the system keyboard on touch devices. Container apps can
    /// atomically replace the primary and accessory views through
    /// ``VNCKeyboardCapture/inputViews``.
    override var inputView: UIView? {
        switch keyboardCapture.inputViews.primary {
        case .packageDefault:
            return softwareKeyboardRequested ? nil : suppressedInputView
        case .systemKeyboard:
            return nil
        case .custom(let view):
            return view
        case .systemKeyboardWhenRequested(let fallback):
            return softwareKeyboardRequested ? nil : fallback
        }
    }

    /// The container app supplies an optional keyboard toolbar in the same
    /// atomic snapshot as the primary input view. visionOS has no input
    /// accessory to override, so a host toolbar there goes unshown.
    #if !os(visionOS)
    override var inputAccessoryView: UIView? {
        keyboardCapture.inputViews.accessory
    }
    #endif

    var hasText: Bool { true }

    func update(
        framebufferSize: CGSize,
        viewport: RemoteViewportState,
        viewportPanningMode: RemoteViewportPanningMode,
        keyboardActive: Bool,
        keyboardCaptured: Bool,
        inputViewsGeneration: UInt64,
        framebufferOrigin: CGPoint,
        requestPasswordSend: @escaping () -> Void,
        requestDictation: @escaping () -> Void,
        toggleFullScreen: (() -> Void)?,
        disconnect: @escaping () -> Void,
        remoteCursor: RemoteCursor?
    ) {
        self.framebufferSize = framebufferSize
        self.framebufferOrigin = framebufferOrigin
        self.viewport = viewport
        if self.viewportPanningMode != viewportPanningMode {
            stopEdgeScrolling()
            self.viewportPanningMode = viewportPanningMode
        }
        self.requestPasswordSend = requestPasswordSend
        self.requestDictation = requestDictation
        self.toggleFullScreen = toggleFullScreen
        self.disconnect = disconnect
        self.viewport.clampOffset(
            viewSize: bounds.size,
            framebufferSize: framebufferSize)

        if self.remoteCursor?.image !== remoteCursor?.image {
            self.remoteCursor = remoteCursor
            #if targetEnvironment(macCatalyst)
            catalystCursor = nil
            catalystCursorDisplayScale = 0
            if hoverRecognizer.state == .began || hoverRecognizer.state == .changed {
                applyCatalystCursor()
            }
            #else
            updateRemoteCursorImage(at: remoteCursorHoverLocation)
            pointerInteraction.invalidate()
            #endif
        }

        let keyboardModeChanged = keyboardActive != softwareKeyboardRequested
        softwareKeyboardRequested = keyboardActive
        let inputViewsChanged = inputViewsGeneration != lastSeenInputViewsGeneration
        lastSeenInputViewsGeneration = inputViewsGeneration
        if keyboardCaptured {
            if !isFirstResponder { becomeFirstResponder() }
            if keyboardModeChanged || (inputViewsChanged && isFirstResponder) {
                reloadInputViews()
            }
        } else {
            releaseAllPressedKeys()
            if inputViewsChanged, isFirstResponder {
                reloadInputViews()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var adjusted = viewport
        adjusted.clampOffset(
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        if adjusted != viewport {
            viewport = adjusted
            onViewportChange?(adjusted)
        }
    }

    func insertText(_ text: String) {
        let modifiers = keyboardCapture.supplementalModifiers
        var dispatched = false
        for character in text {
            dispatched = keyboardHandler.handleKeyTap(
                character,
                supplementalModifiers: modifiers) || dispatched
        }
        if dispatched, !modifiers.isEmpty {
            keyboardCapture.onSupplementalModifiersConsumed?()
        }
    }

    func deleteBackward() {
        let modifiers = keyboardCapture.supplementalModifiers
        let dispatched = keyboardHandler.handleKeysymTap(
            KeyboardInputHandler.keysymBackspace,
            supplementalModifiers: modifiers)
        if dispatched, !modifiers.isEmpty {
            keyboardCapture.onSupplementalModifiersConsumed?()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard keyboardCapture.isCaptured else {
            super.pressesBegan(presses, with: event)
            return
        }
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = UInt32(key.keyCode.rawValue)
            // Some UIKit configurations bypass UIKeyCommand arbitration and
            // deliver Command chords directly here. Claim host-owned chords
            // before the generic hardware path can send their target key to
            // VNC. Any modifier downs already sent are released below.
            if let shortcut = reservedHostShortcut(matching: key) {
                releaseAllPressedKeys()
                keyboardCapture.onReservedHostShortcut?(shortcut)
                continue
            }
            if handleCommandCompatibilityAlias(key: key, usage: usage) {
                continue
            }
            #if !targetEnvironment(macCatalyst)
            if handleRemoteSystemAlias(key: key, usage: usage) {
                continue
            }
            #endif
            // Control/Command are represented by separate RFB modifier events.
            // UIKit may put an ASCII control byte in `characters` for those
            // chords, so use the printable layout result instead.
            let characters = KeyboardInputHandler.hardwareCharacters(
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                controlOrCommandDown: !key.modifierFlags
                    .intersection([.control, .command]).isEmpty)
            let keysym = KeyboardInputHandler.keysymForHIDUsage(
                usage,
                characters: characters)
            guard keysym != 0 else {
                unhandled.insert(press)
                continue
            }
            beginSupplementalModifiersIfNeeded(for: usage)
            _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    /// The containing app's capture toggle reaches this through the responder
    /// chain. Host integrations toggle only the reserved-shortcut destination;
    /// standalone viewers retain the broad keyboard-capture behavior.
    @objc func toggleVNCKeyboardCapture(_ sender: Any?) {
        keyboardCapture.toggleCaptureMode()
        if !keyboardCapture.isCaptured {
            softwareKeyboardRequested = false
            onKeyboardActiveChange?(false)
            releaseAllPressedKeys()
            reloadInputViews()
        } else {
            becomeFirstResponder()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(toggleVNCKeyboardCapture(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func handleReservedHostShortcut(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured,
              let shortcut = reservedHostShortcut(matching: command) else { return }
        releaseAllPressedKeys()
        keyboardCapture.onReservedHostShortcut?(shortcut)
    }

    @objc private func handleStandardRemoteCommand(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured,
              let remoteCommand = Self.remoteCommand(matching: command) else { return }
        releaseAllPressedKeys()
        keyboardHandler.handleRemoteCommand(remoteCommand)
    }

    @objc private func handleRemoteNavigationKey(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured,
              let input = command.input else { return }

        let usage: UInt32
        switch input {
        case UIKeyCommand.inputUpArrow: usage = 0x52
        case UIKeyCommand.inputDownArrow: usage = 0x51
        case UIKeyCommand.inputLeftArrow: usage = 0x50
        case UIKeyCommand.inputRightArrow: usage = 0x4F
        default: return
        }

        beginSupplementalModifiersIfNeeded(for: usage)
        let keysym = KeyboardInputHandler.keysymForHIDUsage(
            usage,
            characters: input)
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    @objc private func handleCommandCompatibilityAlias(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured,
              let character = command.input?.lowercased().first,
              character == "h" || character == "m" else { return }
        releaseAllPressedKeys()
        keyboardHandler.handleCommandTap(character)
    }

    private func handleCommandCompatibilityAlias(
        key: UIKey,
        usage: UInt32
    ) -> Bool {
        let flags = key.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        guard flags == [.control, .alternate] else { return false }

        let character: Character
        switch usage {
        case 0x0B: character = "h"
        case 0x10: character = "m"
        default: return false
        }

        releaseAllPressedKeys()
        if consumedRemoteAliasUsages.insert(usage).inserted {
            keyboardHandler.handleCommandTap(character)
        }
        return true
    }

    @objc private func handlePasswordCommand(_ command: UIKeyCommand) {
        requestPasswordSend()
    }

    @objc private func handleDictationCommand(_ command: UIKeyCommand) {
        requestDictation()
    }

    @objc private func handleFullScreenCommand(_ command: UIKeyCommand) {
        toggleFullScreen?()
    }

    @objc private func handleDisconnectCommand(_ command: UIKeyCommand) {
        disconnect()
    }

    private static func remoteCommand(matching command: UIKeyCommand) -> RemoteCommand? {
        guard let input = command.input else { return nil }
        let modifiers = command.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        return RemoteCommand.allCases.first {
            uiInput(for: $0.shortcut.input) == input
                && uiModifiers(for: $0.shortcut.modifiers) == modifiers
        }
    }

    private static func uiInput(for input: RemoteCommandInput) -> String {
        switch input {
        case .character(let character): String(character)
        case .upArrow: UIKeyCommand.inputUpArrow
        case .downArrow: UIKeyCommand.inputDownArrow
        case .leftArrow: UIKeyCommand.inputLeftArrow
        case .rightArrow: UIKeyCommand.inputRightArrow
        case .escape: UIKeyCommand.inputEscape
        case .delete: "\u{8}"
        }
    }

    private static func uiModifiers(
        for modifiers: RemoteCommandModifiers
    ) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    private static func isStandardRemoteShortcut(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        RemoteCommand.allCases.contains {
            uiInput(for: $0.shortcut.input) == input
                && uiModifiers(for: $0.shortcut.modifiers) == modifiers
        }
    }

    private static func isReservedViewerShortcut(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        let signature = (input.lowercased(), modifiers)
        return signature == ("p", [.control, .shift])
            || signature == ("l", [.control, .alternate])
            || signature == ("f", [.control, .shift])
            || signature == ("q", [.alternate, .command])
    }

    private func isReservedHostShortcut(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection([
            .control, .alternate, .shift, .command,
        ])
        return keyboardCapture.reservedHostShortcuts.contains { shortcut in
            shortcut.input.lowercased() == input.lowercased()
                && Self.uiModifiers(for: shortcut.modifiers) == normalizedModifiers
        }
    }

    private func reservedHostShortcut(
        matching command: UIKeyCommand
    ) -> VNCHostKeyboardShortcut? {
        guard let input = command.input else { return nil }
        let modifiers = command.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        return keyboardCapture.reservedHostShortcuts.first { shortcut in
            if shortcut.input.lowercased() == input.lowercased(),
               Self.uiModifiers(for: shortcut.modifiers) == modifiers {
                return true
            }

            guard shortcut.modifiers.contains(.shift),
                  Self.shiftedHostShortcutInput(shortcut.input)?.lowercased()
                    == input.lowercased() else { return false }
            var shiftedModifiers = Self.uiModifiers(for: shortcut.modifiers)
            shiftedModifiers.remove(.shift)
            return shiftedModifiers == modifiers
        }
    }

    private func reservedHostShortcut(
        matching key: UIKey
    ) -> VNCHostKeyboardShortcut? {
        let modifiers = key.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        let unmodifiedInput = key.charactersIgnoringModifiers.lowercased()
        let modifiedInput = key.characters.lowercased()

        return keyboardCapture.reservedHostShortcuts.first { shortcut in
            let shortcutInput = shortcut.input.lowercased()
            let shortcutModifiers = Self.uiModifiers(for: shortcut.modifiers)
            if shortcutModifiers == modifiers,
               (shortcutInput == unmodifiedInput || shortcutInput == modifiedInput) {
                return true
            }

            guard shortcut.modifiers.contains(.shift),
                  let shiftedInput = Self.shiftedHostShortcutInput(shortcut.input)?
                    .lowercased(),
                  shiftedInput == modifiedInput else { return false }

            // Physical UIKey events normally retain Shift, while Catalyst can
            // normalize shifted punctuation to the produced character and
            // omit Shift. Accept both representations of the same key chord.
            if shortcutModifiers == modifiers { return true }
            var normalizedModifiers = shortcutModifiers
            normalizedModifiers.remove(.shift)
            return normalizedModifiers == modifiers
        }
    }

    private static func shiftedHostShortcutInput(_ input: String) -> String? {
        switch input {
        case "[": "{"
        case "]": "}"
        case "\\": "|"
        default: nil
        }
    }

    private static func uiModifiers(
        for modifiers: VNCKeyboardModifiers
    ) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    @objc private func hardwareKeyboardDidConnect(_ notification: Notification) {
        onHardwareKeyboardAttachedChange?(true)
        #if targetEnvironment(macCatalyst)
        configureCatalystKeyboardMonitor(
            for: notification.object as? GCKeyboard ?? GCKeyboard.coalesced)
        #endif
    }

    @objc private func hardwareKeyboardDidDisconnect(_ notification: Notification) {
        // GameController may post before `coalesced` drops the disconnected
        // instance. Read it on the next main-loop turn so multiple connected
        // keyboards are handled correctly too.
        DispatchQueue.main.async { [weak self] in
            self?.publishHardwareKeyboardAvailability()
        }
        #if targetEnvironment(macCatalyst)
        if GCKeyboard.coalesced == nil {
            configureCatalystKeyboardMonitor(for: nil)
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// UIKit can translate Control-M into Return before delivering it to a
    /// Catalyst responder. GameController exposes the underlying physical key
    /// independently, so use it as a narrow fallback for the Command-H/M
    /// compatibility aliases. All other keys continue through UIKit.
    private func configureCatalystKeyboardMonitor(for keyboard: GCKeyboard?) {
        let input = keyboard?.keyboardInput
        guard monitoredCatalystKeyboardInput !== input else { return }
        monitoredCatalystKeyboardInput?.keyChangedHandler = nil
        monitoredCatalystKeyboardInput = input
        input?.keyChangedHandler = { [weak self] keyboard, _, keyCode, pressed in
            let alias: (usage: UInt32, character: Character)?
            switch keyCode {
            case .keyH: alias = (0x0B, "h")
            case .keyM: alias = (0x10, "m")
            default: alias = nil
            }
            guard let alias else { return }

            let controlDown = keyboard.button(forKeyCode: .leftControl)?.isPressed == true
                || keyboard.button(forKeyCode: .rightControl)?.isPressed == true
            let optionDown = keyboard.button(forKeyCode: .leftAlt)?.isPressed == true
                || keyboard.button(forKeyCode: .rightAlt)?.isPressed == true
            let shiftDown = keyboard.button(forKeyCode: .leftShift)?.isPressed == true
                || keyboard.button(forKeyCode: .rightShift)?.isPressed == true
            let commandDown = keyboard.button(forKeyCode: .leftGUI)?.isPressed == true
                || keyboard.button(forKeyCode: .rightGUI)?.isPressed == true
            let isExactAlias = controlDown && optionDown && !shiftDown && !commandDown

            Task { @MainActor [weak self] in
                self?.handleCatalystCommandCompatibilityAlias(
                    usage: alias.usage,
                    character: alias.character,
                    pressed: pressed,
                    isExactAlias: isExactAlias)
            }
        }
    }

    private func handleCatalystCommandCompatibilityAlias(
        usage: UInt32,
        character: Character,
        pressed: Bool,
        isExactAlias: Bool
    ) {
        guard pressed else {
            consumedRemoteAliasUsages.remove(usage)
            return
        }
        guard keyboardCapture.isCaptured, isExactAlias else { return }
        releaseAllPressedKeys()
        if consumedRemoteAliasUsages.insert(usage).inserted {
            keyboardHandler.handleCommandTap(character)
        }
    }

    @objc private func handleControlKeyCommand(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured else { return }
        ensureModifierKeys(for: command.modifierFlags)

        let usage: UInt32?
        if command.input == UIKeyCommand.inputUpArrow {
            usage = 0x52
        } else if command.input == UIKeyCommand.inputDownArrow {
            usage = 0x51
        } else if command.input == UIKeyCommand.inputLeftArrow {
            usage = 0x50
        } else if command.input == UIKeyCommand.inputRightArrow {
            usage = 0x4F
        } else if let character = command.input?.lowercased().first {
            usage = Self.controlCommandHIDUsages[character]
        } else {
            usage = nil
        }
        guard let usage else { return }
        let characters = command.input ?? ""
        let keysym = KeyboardInputHandler.keysymForHIDUsage(
            usage,
            characters: characters)
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    private func ensureModifierKeys(for flags: UIKeyModifierFlags) {
        let input = GCKeyboard.coalesced?.keyboardInput
        ensureModifier(
            enabled: flags.contains(.control),
            leftUsage: 0xE0,
            rightUsage: 0xE4,
            rightPressed: input?.button(forKeyCode: .rightControl)?.isPressed == true,
            leftKeysym: KeyboardInputHandler.keysymControlL,
            rightKeysym: KeyboardInputHandler.keysymControlR)
        ensureModifier(
            enabled: flags.contains(.shift),
            leftUsage: 0xE1,
            rightUsage: 0xE5,
            rightPressed: input?.button(forKeyCode: .rightShift)?.isPressed == true,
            leftKeysym: KeyboardInputHandler.keysymShiftL,
            rightKeysym: KeyboardInputHandler.keysymShiftR)
        ensureModifier(
            enabled: flags.contains(.alternate),
            leftUsage: 0xE2,
            rightUsage: 0xE6,
            rightPressed: input?.button(forKeyCode: .rightAlt)?.isPressed == true,
            leftKeysym: KeyboardInputHandler.keysymAltL,
            rightKeysym: KeyboardInputHandler.keysymAltR)
        ensureModifier(
            enabled: flags.contains(.command),
            leftUsage: 0xE3,
            rightUsage: 0xE7,
            rightPressed: input?.button(forKeyCode: .rightGUI)?.isPressed == true,
            leftKeysym: KeyboardInputHandler.keysymSuperL,
            rightKeysym: KeyboardInputHandler.keysymSuperR)
    }

    private func ensureModifier(
        enabled: Bool,
        leftUsage: UInt32,
        rightUsage: UInt32,
        rightPressed: Bool,
        leftKeysym: UInt32,
        rightKeysym: UInt32
    ) {
        guard enabled,
              !hardwareKeyboard.contains(usage: leftUsage),
              !hardwareKeyboard.contains(usage: rightUsage) else { return }
        _ = hardwareKeyboard.press(
            usage: rightPressed ? rightUsage : leftUsage,
            keysym: rightPressed ? rightKeysym : leftKeysym)
    }

    private static func hidUsage(forCommandInput input: String) -> UInt32? {
        switch input {
        case UIKeyCommand.inputUpArrow: return 0x52
        case UIKeyCommand.inputDownArrow: return 0x51
        case UIKeyCommand.inputLeftArrow: return 0x50
        case UIKeyCommand.inputRightArrow: return 0x4F
        case UIKeyCommand.inputHome: return 0x4A
        case UIKeyCommand.inputEnd: return 0x4D
        case UIKeyCommand.inputPageUp: return 0x4B
        case UIKeyCommand.inputPageDown: return 0x4E
        case UIKeyCommand.inputEscape: return 0x29
        case "\r": return 0x28
        case "\t": return 0x2B
        default:
            guard let character = input.lowercased().first else { return nil }
            return controlCommandHIDUsages[character]
        }
    }

    private static let controlCommandHIDUsages: [Character: UInt32] = {
        var result: [Character: UInt32] = [:]
        for (offset, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            result[character] = UInt32(0x04 + offset)
        }
        for (offset, character) in "1234567890".enumerated() {
            result[character] = UInt32(0x1E + offset)
        }
        result[" "] = 0x2C
        result["-"] = 0x2D
        result["="] = 0x2E
        result["/"] = 0x38
        result["\\"] = 0x31
        result["["] = 0x2F
        result["]"] = 0x30
        result[";"] = 0x33
        result["'"] = 0x34
        result[","] = 0x36
        result["."] = 0x37
        result["`"] = 0x35
        return result
    }()
    #else
    @objc private func handleRemoteCommandKey(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured,
              let input = command.input,
              let character = input.lowercased().first,
              let usage = Self.remoteCommandHIDUsages[character] else { return }

        ensureLeftModifier(
            command.modifierFlags.contains(.control),
            usage: 0xE0,
            keysym: KeyboardInputHandler.keysymControlL)
        ensureLeftModifier(
            command.modifierFlags.contains(.shift),
            usage: 0xE1,
            keysym: KeyboardInputHandler.keysymShiftL)
        ensureLeftModifier(
            command.modifierFlags.contains(.alternate),
            usage: 0xE2,
            keysym: KeyboardInputHandler.keysymAltL)
        ensureLeftModifier(
            command.modifierFlags.contains(.command),
            usage: 0xE3,
            keysym: KeyboardInputHandler.keysymSuperL)

        let keysym = KeyboardInputHandler.keysymForHIDUsage(
            usage,
            characters: input)
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    private func handleRemoteSystemAlias(
        key: UIKey,
        usage: UInt32
    ) -> Bool {
        let flags = key.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        var modifiers: RemoteCommandModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let input: RemoteCommandInput
        switch usage {
        case 0x52: input = .upArrow
        case 0x51: input = .downArrow
        case 0x50: input = .leftArrow
        case 0x4F: input = .rightArrow
        case 0x29: input = .escape
        case 0x2A, 0x4C: input = .delete
        default:
            guard let character = key.charactersIgnoringModifiers
                .lowercased().first else { return false }
            input = .character(character)
        }

        let command = RemoteCommand.allCases.first(where: {
            $0.shortcut == RemoteCommandShortcut(
                input: input,
                modifiers: modifiers)
        })
        guard let command else { return false }

        // Alias modifiers may already have reached RFB before UIKit delivers
        // the target key. Clear them, consume the target through key-up, and
        // send one clean remote command chord.
        releaseAllPressedKeys()
        if consumedRemoteAliasUsages.insert(usage).inserted {
            keyboardHandler.handleRemoteCommand(command)
        }
        return true
    }

    private func ensureLeftModifier(
        _ enabled: Bool,
        usage: UInt32,
        keysym: UInt32
    ) {
        guard enabled, !hardwareKeyboard.contains(usage: usage) else { return }
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    private static let remoteCommandHIDUsages: [Character: UInt32] = {
        var result: [Character: UInt32] = [:]
        for (offset, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            result[character] = UInt32(0x04 + offset)
        }
        for (offset, character) in "1234567890".enumerated() {
            result[character] = UInt32(0x1E + offset)
        }
        result[" "] = 0x2C
        result["-"] = 0x2D
        result["="] = 0x2E
        result["["] = 0x2F
        result["]"] = 0x30
        result["\\"] = 0x31
        result[";"] = 0x33
        result["'"] = 0x34
        result["`"] = 0x35
        result[","] = 0x36
        result["."] = 0x37
        result["/"] = 0x38
        return result
    }()
    #endif

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseHardwarePresses(presses)
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        consumedRemoteAliasUsages.removeAll()
        releaseAllPressedKeys()
        super.pressesCancelled(presses, with: event)
    }

    private func releaseHardwarePresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = UInt32(key.keyCode.rawValue)
            if consumedRemoteAliasUsages.remove(usage) != nil {
                continue
            }
            guard hardwareKeyboard.release(usage: usage) else {
                unhandled.insert(press)
                continue
            }
            endSupplementalModifiers(for: usage)
        }
        return unhandled
    }

    private func releaseAllPressedKeys() {
        hardwareKeyboard.releaseAll()
        releaseAllSupplementalModifiers()
    }

    private func beginSupplementalModifiersIfNeeded(for usage: UInt32) {
        // Modifier-only presses already have explicit physical transitions.
        guard !(0xE0...0xE7).contains(usage),
              !supplementalModifierState.contains(usage: usage) else { return }

        let configured = keyboardCapture.supplementalModifiers
        guard !configured.isEmpty else { return }
        let keysyms = KeyboardInputHandler.keysyms(for: configured).filter {
            !physicalModifierIsPressed(for: $0)
        }

        // Beginning with an empty list still records a repeat sentinel when
        // every configured modifier is already held physically.
        supplementalModifierState.begin(usage: usage, keysyms: keysyms)
            .forEach(sendSupplementalTransition)
        keyboardCapture.onSupplementalModifiersConsumed?()
    }

    private func endSupplementalModifiers(for usage: UInt32) {
        supplementalModifierState.end(usage: usage)
            .forEach(sendSupplementalTransition)
    }

    private func releaseAllSupplementalModifiers() {
        supplementalModifierState.releaseAll()
            .forEach(sendSupplementalTransition)
    }

    private func sendSupplementalTransition(_ transition: HardwareKeyboardTransition) {
        keyboardHandler.handleKeysym(
            downFlag: transition.downFlag,
            keysym: transition.keysym)
    }

    private func physicalModifierIsPressed(for keysym: UInt32) -> Bool {
        switch keysym {
        case KeyboardInputHandler.keysymControlL:
            return hardwareKeyboard.contains(usage: 0xE0)
                || hardwareKeyboard.contains(usage: 0xE4)
        case KeyboardInputHandler.keysymShiftL:
            return hardwareKeyboard.contains(usage: 0xE1)
                || hardwareKeyboard.contains(usage: 0xE5)
        case KeyboardInputHandler.keysymAltL:
            return hardwareKeyboard.contains(usage: 0xE2)
                || hardwareKeyboard.contains(usage: 0xE6)
        case KeyboardInputHandler.keysymSuperL:
            return hardwareKeyboard.contains(usage: 0xE3)
                || hardwareKeyboard.contains(usage: 0xE7)
        default:
            return false
        }
    }

    @objc private func applicationWillResignActive() {
        releaseAllPressedKeys()
        releasePointerDrag()
        releaseTouchHoldDrag()
        stopEdgeScrolling()
        #if !targetEnvironment(macCatalyst)
        remoteCursorHoverLocation = nil
        remoteCursorImageView.isHidden = true
        #endif
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        releaseAllPressedKeys()
        releasePointerDrag()
        releaseTouchHoldDrag()
        stopEdgeScrolling()
        #if !targetEnvironment(macCatalyst)
        remoteCursorHoverLocation = nil
        remoteCursorImageView.isHidden = true
        #endif
    }

    private func releasePointerDrag() {
        if pointerDragActive, let point = lastPointerPoint {
            touchHandler.handleDragEnd(x: point.x, y: point.y)
        }
        pointerDragActive = false
        lastPointerPoint = nil
    }

    /// Catalyst does not consistently expose a deceleration phase for its
    /// UIEvent.scroll pan. Consume the direct translation and always generate
    /// the momentum tail ourselves from displacement over the gesture's
    /// trailing window, the same way native scroll views derive a fling.
    @objc private func handleNativeScrollState(_ recognizer: UIPanGestureRecognizer) {
        stopEdgeScrolling()
        logInputRoute(
            "scroll state=\(recognizer.state.rawValue) "
            + "translation=\(recognizer.translation(in: self))")
        switch recognizer.state {
        case .began:
            if momentumScrollPhaseActive {
                endMomentumScrollPhase()
                finishScrollInteraction()
            }
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            activeScrollRecognizer = recognizer
            activeScrollUsesDirectTouch = false
            let translation = recognizer.translation(in: self)
            let now = CACurrentMediaTime()
            releaseVelocityEstimator.reset()
            releaseVelocityEstimator.record(position: translation, at: now)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            beginScrollInteractionIfNeeded(
                at: recognizer.location(in: self),
                initialTranslation: translation)
        case .changed:
            guard activeScrollRecognizer === recognizer else { return }
            let translation = recognizer.translation(in: self)
            let now = CACurrentMediaTime()
            let deltaX = translation.x - previousScrollTranslation.x
            let deltaY = translation.y - previousScrollTranslation.y
            releaseVelocityEstimator.record(position: translation, at: now)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            sendFilteredScrollDelta(
                deltaX: deltaX,
                deltaY: deltaY,
                scrollPhase: .changed)
        case .ended:
            guard activeScrollRecognizer === recognizer else { return }
            flushPendingScrollDelta()
            endDirectScrollPhase(.ended)
            if !beginSyntheticMomentumIfNeeded() {
                finishScrollInteraction()
            }
        case .cancelled, .failed:
            guard activeScrollRecognizer === recognizer else { return }
            cancelScrollInteraction()
        default:
            break
        }
    }

    private func beginScrollInteractionIfNeeded(
        at location: CGPoint,
        initialTranslation: CGPoint
    ) {
        guard !directScrollPhaseActive else { return }
        if momentumScrollPhaseActive {
            endMomentumScrollPhase()
        }
        directScrollPhaseActive = true
        lastScrollPoint = nil
        scrollPointAccumulator.reset()
        horizontalScrollIntentFilter.reset()
        captureScrollPoint(at: location)
        if let point = lastScrollPoint {
            // The Apple scroll record carries coordinates, but remote WebKit
            // hit-testing still follows the server's current pointer. Sync it
            // explicitly before the gesture envelope just like a local hover.
            lastPointerPoint = point
            touchHandler.handleMove(x: point.x, y: point.y)
            touchHandler.handleGesture(
                kind: .began,
                x: point.x,
                y: point.y)
        }
        sendFilteredScrollDelta(
            deltaX: initialTranslation.x,
            deltaY: initialTranslation.y,
            scrollPhase: .began,
            momentumPhase: .none)
    }

    private func beginMomentumScrollPhaseIfNeeded() {
        guard !momentumScrollPhaseActive else { return }
        endDirectScrollPhase(.ended)
        momentumScrollPhaseActive = true
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: .none,
            momentumPhase: .began)
    }

    /// Derive the fling from displacement over the gesture's trailing window
    /// and generate a consistent tail on every platform instead of depending
    /// on UIKit's private scroll phase.
    @discardableResult
    private func beginSyntheticMomentumIfNeeded() -> Bool {
        guard momentumDisplayLink == nil else { return false }
        let releaseVelocity = releaseVelocityEstimator.releaseVelocity(
            at: CACurrentMediaTime())
        let speed = hypot(releaseVelocity.x, releaseVelocity.y)
        guard speed >= 25 else { return false }

        let maximumSpeed: CGFloat = 12_000
        let scale = min(1, maximumSpeed / speed)
        syntheticMomentumVelocity = CGPoint(
            x: releaseVelocity.x * scale,
            y: releaseVelocity.y * scale)
        syntheticMomentumLastTimestamp = 0
        beginMomentumScrollPhaseIfNeeded()

        let link = CADisplayLink(target: self, selector: #selector(stepSyntheticMomentum(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        momentumDisplayLink = link
        logInputRoute(
            "synthetic momentum velocity=(\(syntheticMomentumVelocity.x),"
                + "\(syntheticMomentumVelocity.y))")
        return true
    }

    @objc private func stepSyntheticMomentum(_ displayLink: CADisplayLink) {
        guard momentumDisplayLink === displayLink,
              momentumScrollPhaseActive else {
            stopSyntheticMomentum()
            return
        }

        let elapsed: CFTimeInterval
        if syntheticMomentumLastTimestamp == 0 {
            elapsed = displayLink.duration
        } else {
            elapsed = min(0.05, displayLink.timestamp - syntheticMomentumLastTimestamp)
        }
        syntheticMomentumLastTimestamp = displayLink.timestamp

        sendFilteredScrollDelta(
            deltaX: syntheticMomentumVelocity.x * elapsed,
            deltaY: syntheticMomentumVelocity.y * elapsed,
            scrollPhase: .none,
            momentumPhase: .changed)

        // UIScrollView.DecelerationRate.normal is 0.998 per millisecond.
        let decay = pow(CGFloat(0.998), CGFloat(elapsed * 1_000))
        syntheticMomentumVelocity.x *= decay
        syntheticMomentumVelocity.y *= decay
        if hypot(syntheticMomentumVelocity.x, syntheticMomentumVelocity.y) < 5 {
            endMomentumScrollPhase()
            finishScrollInteraction()
        }
    }

    private func stopSyntheticMomentum() {
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        syntheticMomentumVelocity = .zero
        syntheticMomentumLastTimestamp = 0
    }

    private func endDirectScrollPhase(_ phase: AppleScrollEvent.Phase) {
        guard directScrollPhaseActive else { return }
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: phase,
            momentumPhase: .none)
        if let point = lastScrollPoint {
            touchHandler.handleGesture(
                kind: .ended,
                x: point.x,
                y: point.y)
        }
        directScrollPhaseActive = false
    }

    private func endMomentumScrollPhase() {
        guard momentumScrollPhaseActive else { return }
        stopSyntheticMomentum()
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: .none,
            momentumPhase: .ended)
        momentumScrollPhaseActive = false
    }

    /// Stop an active synthetic fling because new input arrived, the way a
    /// native scroll view halts deceleration on contact. Returns true when a
    /// fling was actually caught.
    @discardableResult
    private func catchMomentumFlingIfActive() -> Bool {
        guard momentumScrollPhaseActive else { return false }
        endMomentumScrollPhase()
        finishScrollInteraction()
        return true
    }

    /// Trackpad tap-to-click and pencil contacts never create direct touches,
    /// so the touch recognizer's fling catch cannot see them, and their tap
    /// recognition is further delayed by double-tap disambiguation. Catch at
    /// raw touch-down instead; the click that follows still lands normally.
    /// Direct touches are left to the touch recognizer, whose catch also
    /// suppresses the accidental click.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .direct }) {
            stopEdgeScrolling()
        }
        if touches.contains(where: { $0.type != .direct }) {
            catchMomentumFlingIfActive()
        }
        #if !targetEnvironment(macCatalyst)
        // Catalyst never delivers secondary clicks as indirect-pointer
        // touches; they arrive as a touchless button event consumed by
        // secondaryClickInteraction instead.
        handleSecondaryPointerDown(in: touches, event: event)
        #endif
        super.touchesBegan(touches, with: event)
    }

    /// A context-menu interaction also owns held primary-button input, which
    /// can cancel a Finder drag before it moves. Route an actual trackpad
    /// secondary button from its raw mask instead, leaving primary holds under
    /// the dedicated drag recognizer's exclusive control.
    private func handleSecondaryPointerDown(
        in touches: Set<UITouch>,
        event: UIEvent?
    ) {
        guard let event,
              event.buttonMask.contains(.secondary),
              !event.buttonMask.contains(.primary),
              let touch = touches.first(where: {
                  $0.type == .indirectPointer
              }),
              let point = framebufferPoint(
                  for: touch.location(in: self)) else { return }
        focusForHardwareKeyboard()
        touchHandler.handleRightClick(x: point.x, y: point.y)
    }

    private func cancelScrollInteraction() {
        endDirectScrollPhase(.cancelled)
        endMomentumScrollPhase()
        finishScrollInteraction()
    }

    private func captureScrollPoint(at location: CGPoint) {
        // For UIEvent.scroll, UIKit supplies the actual trackpad pointer
        // position at gesture begin. Direct touch supplies its committed start
        // location. Either is more reliable than the last cached hover point.
        if let point = framebufferPoint(for: location) {
            lastScrollPoint = point
        } else if let lastKnownFramebufferPoint {
            lastScrollPoint = lastKnownFramebufferPoint
        } else if let center = framebufferPoint(for: CGPoint(
            x: bounds.midX,
            y: bounds.midY)) {
            lastScrollPoint = center
        }
    }

    private func sendScrollSample(
        pointDeltaX: Int32,
        pointDeltaY: Int32,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        guard let point = lastScrollPoint else { return }
        let coarse = wheelUnitAccumulator.consume(
            pointDeltaX: pointDeltaX,
            pointDeltaY: pointDeltaY)
        logInputRoute(
            "send scroll delta=(\(pointDeltaX),\(pointDeltaY)) "
            + "coarse=(\(coarse.x),\(coarse.y)) "
            + "phase=\(scrollPhase.rawValue) pos=(\(point.x),\(point.y))")
        touchHandler.handleScroll(
            x: point.x,
            y: point.y,
            pointDeltaX: pointDeltaX,
            pointDeltaY: pointDeltaY,
            coarseDeltaX: coarse.x,
            coarseDeltaY: coarse.y,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase)
    }

    private func sendFilteredScrollDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        var filtered: CGPoint
        if activeScrollUsesDirectTouch {
            filtered = horizontalScrollIntentFilter.consume(
                deltaX: deltaX,
                deltaY: deltaY)
            if horizontalScrollIntentFilter.isHorizontallyLocked {
                // Trackpad scroll events already contain system acceleration;
                // raw finger translation does not. A modest horizontal gain
                // lets AppKit's fluid swipe tracking reach the commit distance
                // during an ordinary finger stroke instead of requiring an
                // edge-to-edge fling.
                filtered.x *= 2
            }
        } else {
            // UIKit's UIEvent.scroll stream already carries the trackpad's
            // native directional intent. Preserve it byte-for-byte instead
            // of applying touch-oriented axis correction to a working path.
            filtered = CGPoint(x: deltaX, y: deltaY)
        }
        if filtered.x == 0, filtered.y == 0, scrollPhase == .began {
            // Preserve the lifecycle boundary even while the opening motion
            // is buffered for an axis-intent decision.
            sendScrollSample(
                pointDeltaX: 0,
                pointDeltaY: 0,
                scrollPhase: .began,
                momentumPhase: momentumPhase)
            return
        }
        sendAccumulatedScrollDelta(
            filtered,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase)
    }

    private func flushPendingScrollDelta() {
        guard activeScrollUsesDirectTouch else { return }
        sendAccumulatedScrollDelta(
            horizontalScrollIntentFilter.flush(),
            scrollPhase: .changed)
    }

    private func sendAccumulatedScrollDelta(
        _ delta: CGPoint,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        let points = scrollPointAccumulator.consume(
            deltaX: delta.x,
            deltaY: delta.y)
        guard points.x != 0 || points.y != 0 else { return }
        sendScrollSample(
            pointDeltaX: points.x,
            pointDeltaY: points.y,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase)
    }

    private func finishScrollInteraction() {
        guard !directScrollPhaseActive, !momentumScrollPhaseActive else { return }
        activeScrollRecognizer = nil
        lastScrollPoint = nil
        scrollPointAccumulator.reset()
        wheelUnitAccumulator.reset()
        horizontalScrollIntentFilter.reset()
        activeScrollUsesDirectTouch = false
        releaseVelocityEstimator.reset()
        previousScrollTimestamp = 0
        previousScrollTranslation = .zero
    }

    private func configureRecognizers() {
        let directTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        let pointerTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        let allPointerTypes = directTouchTypes + pointerTypes

        // UIKit represents trackpad/wheel scrolling as a zero-touch pan. Keep
        // it separate from the ordinary one-finger recognizer: the delegate
        // admits only UIEvent.scroll here and only direct touches there.
        scrollRecognizer.minimumNumberOfTouches = 0
        scrollRecognizer.maximumNumberOfTouches = 1
        scrollRecognizer.allowedTouchTypes = directTouchTypes
        scrollRecognizer.allowedScrollTypesMask = .all
        scrollRecognizer.delegate = self

        directTouchRecognizer.allowedTouchTypes = directTouchTypes
        directTouchRecognizer.delegate = self

        pinchRecognizer.allowedTouchTypes = directTouchTypes
        pinchRecognizer.delegate = self

        viewportPanRecognizer.minimumNumberOfTouches = 2
        viewportPanRecognizer.maximumNumberOfTouches = 2
        viewportPanRecognizer.allowedTouchTypes = directTouchTypes
        viewportPanRecognizer.delegate = self

        // A pan waits for a movement threshold before beginning, which can
        // move off a narrow scrollbar thumb before remote button-down. Begin
        // at the exact primary-button location and keep tracking while held.
        pointerDragRecognizer.minimumPressDuration = 0
        pointerDragRecognizer.allowableMovement = .greatestFiniteMagnitude
        pointerDragRecognizer.numberOfTouchesRequired = 1
        pointerDragRecognizer.allowedTouchTypes = pointerTypes
        pointerDragRecognizer.delegate = self

        tapRecognizer.numberOfTapsRequired = 1
        tapRecognizer.allowedTouchTypes = allPointerTypes
        tapRecognizer.delegate = self

        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.allowedTouchTypes = allPointerTypes
        doubleTapRecognizer.delegate = self
        tapRecognizer.require(toFail: pointerDragRecognizer)
        doubleTapRecognizer.require(toFail: pointerDragRecognizer)
        tapRecognizer.require(toFail: doubleTapRecognizer)

        rightTapRecognizer.numberOfTouchesRequired = 2
        rightTapRecognizer.allowedTouchTypes = directTouchTypes
        rightTapRecognizer.delegate = self

        hoverRecognizer.allowedTouchTypes = pointerTypes
        hoverRecognizer.delegate = self

        for recognizer in [
            scrollRecognizer,
            directTouchRecognizer,
            pinchRecognizer,
            viewportPanRecognizer,
            pointerDragRecognizer,
            tapRecognizer,
            doubleTapRecognizer,
            rightTapRecognizer,
            hoverRecognizer,
        ] {
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        stopEdgeScrolling()
        viewport.zoom(
            by: recognizer.scale,
            around: visibleLocation(for: recognizer.location(in: self)),
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        recognizer.scale = 1
        onViewportChange?(viewport)
    }

    @objc private func handleViewportPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        stopEdgeScrolling()
        let translation = recognizer.translation(in: self)
        viewport.pan(
            by: CGSize(width: translation.x, height: translation.y),
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        recognizer.setTranslation(.zero, in: self)
        onViewportChange?(viewport)
    }

    @objc private func handlePointerDrag(_ recognizer: UILongPressGestureRecognizer) {
        focusForHardwareKeyboardIfNeeded(recognizer)
        switch recognizer.state {
        case .began, .changed:
            catchMomentumFlingIfActive()
            let location = recognizer.location(in: self)
            #if !targetEnvironment(macCatalyst)
            // Hover updates pause while the trackpad button is down. Advance
            // the custom remote-cursor image from the drag stream without
            // sending a zero-button pointer event that would release the item.
            updateRemoteCursorImage(at: location)
            #endif
            if pointerDragUsesIndirectPointer {
                updatePointerPanning(at: location, isDragging: true)
            } else {
                stopEdgeScrolling()
            }
            guard let point = framebufferPoint(for: location) else { return }
            lastPointerPoint = point
            pointerDragActive = true
            touchHandler.handleDrag(x: point.x, y: point.y)
        case .ended, .cancelled, .failed:
            stopEdgeScrolling()
            releasePointerDrag()
        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        if momentumCatchPending {
            // The touch that stopped a fling belongs to the scroll
            // interaction; catching never clicks the remote desktop.
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            return
        }
        // A pointer click during a fling stops it; the click still lands,
        // matching a trackpad click on a decelerating native view.
        catchMomentumFlingIfActive()
        focusForHardwareKeyboardIfNeeded(recognizer)
        if recognizer.buttonMask.contains(.secondary) {
            touchHandler.handleRightClick(x: point.x, y: point.y)
        } else {
            touchHandler.handleTap(x: point.x, y: point.y)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        focusForHardwareKeyboardIfNeeded(recognizer)
        if momentumCatchPending
            || (momentumCatchTimestamp > 0
                && CACurrentMediaTime() - momentumCatchTimestamp <= 0.75) {
            // The first tap of the pair caught the fling; deliver only the
            // second as an ordinary click, as a native scroll view would.
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            touchHandler.handleTap(x: point.x, y: point.y)
            return
        }
        catchMomentumFlingIfActive()
        touchHandler.handleDoubleTap(x: point.x, y: point.y)
    }

    @objc private func handleRightTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        if catchMomentumFlingIfActive() || momentumCatchPending {
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            return
        }
        touchHandler.handleRightClick(x: point.x, y: point.y)
    }

    @objc private func handleDirectTouchState(
        _ recognizer: DirectTouchGestureRecognizer
    ) {
        guard let mode = recognizer.mode else { return }
        switch (mode, recognizer.state) {
        case (.scroll, .began):
            if momentumScrollPhaseActive {
                endMomentumScrollPhase()
                finishScrollInteraction()
            }
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            activeScrollRecognizer = recognizer
            activeScrollUsesDirectTouch = true
            let beginTimestamp = CACurrentMediaTime()
            releaseVelocityEstimator.reset()
            releaseVelocityEstimator.record(
                position: recognizer.translation,
                at: beginTimestamp)
            previousScrollTranslation = recognizer.translation
            previousScrollTimestamp = beginTimestamp
            beginScrollInteractionIfNeeded(
                at: recognizer.currentLocation,
                initialTranslation: recognizer.translation)
        case (.scroll, .changed):
            guard activeScrollRecognizer === recognizer else { return }
            let now = CACurrentMediaTime()
            let translation = recognizer.translation
            let deltaX = translation.x - previousScrollTranslation.x
            let deltaY = translation.y - previousScrollTranslation.y
            releaseVelocityEstimator.record(position: translation, at: now)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            sendFilteredScrollDelta(
                deltaX: deltaX,
                deltaY: deltaY,
                scrollPhase: .changed)
        case (.scroll, .ended):
            guard activeScrollRecognizer === recognizer else { return }
            flushPendingScrollDelta()
            endDirectScrollPhase(.ended)
            if !beginSyntheticMomentumIfNeeded() {
                finishScrollInteraction()
            }
        case (.scroll, .cancelled):
            guard activeScrollRecognizer === recognizer else { return }
            cancelScrollInteraction()
        case (.drag, .began):
            guard let point = framebufferPoint(
                for: recognizer.currentLocation) else { return }
            touchHoldDragLastPoint = point
            touchHoldDragActive = true
            lastPointerPoint = point
            touchHandler.handleDrag(x: point.x, y: point.y)
        case (.drag, .changed):
            guard touchHoldDragActive,
                  let point = framebufferPoint(
                    for: recognizer.currentLocation) else { return }
            touchHoldDragLastPoint = point
            lastPointerPoint = point
            touchHandler.handleDrag(x: point.x, y: point.y)
        case (.drag, .ended), (.drag, .cancelled):
            releaseTouchHoldDrag()
        default:
            break
        }
    }

    private func positionRemotePointerForTouch(at location: CGPoint) {
        guard let point = framebufferPoint(for: location) else { return }
        lastPointerPoint = point
        touchHandler.handleMove(x: point.x, y: point.y)
    }

    private func releaseTouchHoldDrag() {
        if touchHoldDragActive, let point = touchHoldDragLastPoint {
            touchHandler.handleDragEnd(x: point.x, y: point.y)
        }
        resetTouchHoldDrag()
    }

    private func resetTouchHoldDrag() {
        touchHoldDragLastPoint = nil
        touchHoldDragActive = false
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        #if targetEnvironment(macCatalyst)
        if recognizer.state == .ended || recognizer.state == .cancelled {
            stopEdgeScrolling()
            NSCursor.arrow.set()
            return
        }
        if recognizer.state == .began || recognizer.state == .changed {
            applyCatalystCursor()
        }
        #else
        if recognizer.state == .ended || recognizer.state == .cancelled {
            stopEdgeScrolling()
            remoteCursorHoverLocation = nil
            remoteCursorImageView.isHidden = true
            return
        }
        if recognizer.state == .began || recognizer.state == .changed {
            updateRemoteCursorImage(at: recognizer.location(in: self))
        }
        #endif

        if !hoverUsesIndirectPointer {
            stopEdgeScrolling()
        } else if !directScrollPhaseActive,
                  !momentumScrollPhaseActive,
                  !pointerDragActive,
                  recognizer.state == .began || recognizer.state == .changed {
            updatePointerPanning(
                at: recognizer.location(in: self),
                isDragging: false)
        }

        guard !directScrollPhaseActive,
              !momentumScrollPhaseActive,
              !pointerDragActive,
              recognizer.state == .began || recognizer.state == .changed,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        guard lastPointerPoint?.x != point.x
                || lastPointerPoint?.y != point.y else { return }
        lastPointerPoint = point
        logInputRoute("hover pos=(\(point.x),\(point.y))")
        focusForHardwareKeyboard()
        touchHandler.handleMove(x: point.x, y: point.y)
    }

    private func updatePointerPanning(
        at location: CGPoint,
        isDragging: Bool
    ) {
        switch viewportPanningMode {
        case .edge:
            updateEdgeScrolling(at: location, isDragging: isDragging)
        case .continuous:
            stopEdgeScrolling()
            let translation = viewport.cursorFollowingTranslation(
                for: location,
                viewSize: bounds.size,
                framebufferSize: framebufferSize)
            guard translation != .zero else { return }
            viewport.pan(
                by: translation,
                viewSize: bounds.size,
                framebufferSize: framebufferSize)
            onViewportChange?(viewport)
        }
    }

    private func updateEdgeScrolling(
        at location: CGPoint,
        isDragging: Bool
    ) {
        edgeScrollPointerLocation = location
        edgeScrollIsDragging = isDragging
        let translation = viewport.edgeScrollTranslation(
            for: location,
            viewSize: bounds.size,
            framebufferSize: framebufferSize,
            elapsedTime: 1.0 / 60.0)
        guard translation != .zero else {
            stopEdgeScrolling()
            return
        }
        guard edgeScrollDisplayLink == nil else { return }
        edgeScrollLastTimestamp = 0
        let link = CADisplayLink(
            target: self,
            selector: #selector(stepEdgeScrolling(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        edgeScrollDisplayLink = link
    }

    @objc private func stepEdgeScrolling(_ displayLink: CADisplayLink) {
        guard edgeScrollDisplayLink === displayLink,
              let location = edgeScrollPointerLocation,
              window != nil else {
            stopEdgeScrolling()
            return
        }
        let elapsed: CFTimeInterval
        if edgeScrollLastTimestamp == 0 {
            elapsed = displayLink.duration
        } else {
            elapsed = min(0.05, displayLink.timestamp - edgeScrollLastTimestamp)
        }
        edgeScrollLastTimestamp = displayLink.timestamp

        let translation = viewport.edgeScrollTranslation(
            for: location,
            viewSize: bounds.size,
            framebufferSize: framebufferSize,
            elapsedTime: elapsed)
        guard translation != .zero else {
            stopEdgeScrolling()
            return
        }
        viewport.pan(
            by: translation,
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        onViewportChange?(viewport)

        guard let point = framebufferPoint(for: location),
              lastPointerPoint?.x != point.x
                || lastPointerPoint?.y != point.y else { return }
        lastPointerPoint = point
        if edgeScrollIsDragging {
            touchHandler.handleDrag(x: point.x, y: point.y)
        } else {
            touchHandler.handleMove(x: point.x, y: point.y)
        }
    }

    private func stopEdgeScrolling() {
        edgeScrollDisplayLink?.invalidate()
        edgeScrollDisplayLink = nil
        edgeScrollPointerLocation = nil
        edgeScrollLastTimestamp = 0
        edgeScrollIsDragging = false
    }

    #if targetEnvironment(macCatalyst)
    /// Catalyst uses the macOS cursor compositor. Feeding the remote bitmap to
    /// NSCursor preserves the server-selected resize/I-beam/hand cursor, its
    /// colors, and its hotspot; UIPointerShape is an iPad pointer-morphing API
    /// and is not reliably applied to the Mac arrow.
    private func applyCatalystCursor() {
        guard let remoteCursor else {
            NSCursor.arrow.set()
            return
        }

        // Cursor size is a local accessibility/display preference. Remote
        // framebuffer zoom and Retina scaling must not shrink or enlarge it.
        // AppleVNCServer's cursor dimensions are already expressed in local
        // points, not Retina backing pixels.
        let displayScale: CGFloat = 1
        if catalystCursor == nil
            || abs(catalystCursorDisplayScale - displayScale) > 0.001 {
            let image = UIImage(
                cgImage: remoteCursor.image,
                scale: displayScale,
                orientation: .up)
            catalystCursor = NSCursor(
                image: image,
                hotSpot: CGPoint(
                    x: CGFloat(remoteCursor.hotspotX) / displayScale,
                    y: CGFloat(remoteCursor.hotspotY) / displayScale))
            catalystCursorDisplayScale = displayScale
        }
        catalystCursor?.set()
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    /// Draw the server-selected bitmap at the locally delivered hover point.
    /// This remains as responsive as UIKit's pointer because it does not wait
    /// for the remote cursor-position echo; only shape changes cross the wire.
    private func updateRemoteCursorImage(at location: CGPoint?) {
        remoteCursorHoverLocation = location
        guard let location, let remoteCursor else {
            remoteCursorImageView.isHidden = true
            remoteCursorImageView.image = nil
            return
        }

        remoteCursorImageView.image = UIImage(
            cgImage: remoteCursor.image,
            scale: 1,
            orientation: .up)
        remoteCursorImageView.frame = CGRect(
            x: location.x - CGFloat(remoteCursor.hotspotX),
            y: location.y - CGFloat(remoteCursor.hotspotY),
            width: CGFloat(remoteCursor.width),
            height: CGFloat(remoteCursor.height))
        remoteCursorImageView.isHidden = false
        bringSubviewToFront(remoteCursorImageView)
    }
    #endif

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard !directScrollPhaseActive,
              !momentumScrollPhaseActive,
              !pointerDragActive,
              scrollRecognizer.state != .began,
              scrollRecognizer.state != .changed,
              let point = framebufferPoint(for: request.location) else {
            return defaultRegion
        }
        if lastPointerPoint?.x != point.x || lastPointerPoint?.y != point.y {
            lastPointerPoint = point
            logInputRoute("pointer interaction pos=(\(point.x),\(point.y))")
            focusForHardwareKeyboard()
            touchHandler.handleMove(x: point.x, y: point.y)
        }
        return defaultRegion
    }

    /// iPad has no public bitmap-backed UIPointerShape. Hide its synthetic
    /// pointer while the local image overlay above displays the exact remote
    /// cursor; nil retains the ordinary system pointer.
    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        remoteCursor == nil ? nil : .hidden()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive event: UIEvent
    ) -> Bool {
        switch event.type {
        case .scroll:
            let accepted = gestureRecognizer === scrollRecognizer
            if accepted {
                logInputRoute("received UIEvent.scroll")
                // Trackpad contact surfaces here before the pan recognizer
                // has any movement to begin with (the scroll stream's
                // may-begin phase). Fingers returning to the trackpad must
                // catch an active fling exactly like a finger on glass; the
                // synthetic tail emits no UIEvents, so any scroll event
                // during momentum is real user contact.
                catchMomentumFlingIfActive()
            }
            return accepted
        case .hover:
            guard gestureRecognizer === hoverRecognizer else { return false }
            hoverUsesIndirectPointer = event.allTouches?.contains {
                $0.type == .pencil
            } != true
            return true
        default:
            if gestureRecognizer === scrollRecognizer {
                return false
            }
            if gestureRecognizer === pointerDragRecognizer {
                if !event.buttonMask.isEmpty,
                   !event.buttonMask.contains(.primary) {
                    // Reject before recognition so a secondary click is not
                    // consumed by the zero-delay primary drag recognizer.
                    return false
                }
                pointerDragUsesIndirectPointer = event.allTouches?.contains {
                    $0.type == .pencil
                } != true
            }
            return true
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pointerDragRecognizer,
           !gestureRecognizer.buttonMask.isEmpty {
            return gestureRecognizer.buttonMask.contains(.primary)
        }
        #if targetEnvironment(macCatalyst)
        // The context-menu interaction also recognizes a held primary button,
        // which would cancel an in-flight remote drag (e.g. a Finder drag)
        // before it moves. Primary input belongs exclusively to
        // pointerDragRecognizer; the interaction's recognizers may begin only
        // for the touchless secondary-click event.
        if !isOwnRecognizer(gestureRecognizer),
           pointerDragActive || gestureRecognizer.buttonMask.contains(.primary) {
            return false
        }
        #endif
        return true
    }

    private func isOwnRecognizer(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer === scrollRecognizer
            || recognizer === directTouchRecognizer
            || recognizer === pinchRecognizer
            || recognizer === viewportPanRecognizer
            || recognizer === pointerDragRecognizer
            || recognizer === tapRecognizer
            || recognizer === doubleTapRecognizer
            || recognizer === rightTapRecognizer
            || recognizer === hoverRecognizer
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let pair = Set([ObjectIdentifier(gestureRecognizer), ObjectIdentifier(otherGestureRecognizer)])
        return pair == Set([
            ObjectIdentifier(pinchRecognizer),
            ObjectIdentifier(viewportPanRecognizer),
        ])
    }

    private func framebufferPoint(for location: CGPoint) -> (x: UInt16, y: UInt16)? {
        guard let point = viewport.framebufferPoint(
            for: visibleLocation(for: location),
            viewSize: bounds.size,
            framebufferSize: framebufferSize) else { return nil }
        let result = (
            UInt16(min(
                CGFloat(UInt16.max),
                max(0, point.x + framebufferOrigin.x))),
            UInt16(min(
                CGFloat(UInt16.max),
                max(0, point.y + framebufferOrigin.y))))
        lastKnownFramebufferPoint = result
        return result
    }

    private func visibleLocation(for contentLocation: CGPoint) -> CGPoint {
        contentLocation
    }

    private func logInputRoute(_ message: String) {
        #if DEBUG
        guard VNCDiagnostics.isEnabled("ROOTSHELL_VNC_TRACE_INPUT"),
              inputLogBudget > 0 else { return }
        inputLogBudget -= 1
        inputLog.info(message)
        #endif
    }

    private func focusForHardwareKeyboardIfNeeded(_ recognizer: UIGestureRecognizer) {
        if !recognizer.buttonMask.isEmpty {
            focusForHardwareKeyboard()
        }
    }

    private func focusForHardwareKeyboard() {
        if keyboardCapture.automaticallyCapturesOnInteraction {
            keyboardCapture.capture()
        }
        guard !isFirstResponder else { return }
        softwareKeyboardRequested = false
        becomeFirstResponder()
    }

    private func dismissKeyboard() {
        softwareKeyboardRequested = false
        reloadInputViews()
        onKeyboardActiveChange?(false)
    }

    @objc private func softwareKeyboardWillHide() {
        guard softwareKeyboardRequested else { return }
        softwareKeyboardRequested = false
        onKeyboardActiveChange?(false)
    }

    @objc private func softwareKeyboardDidHide() {
        guard softwareKeyboardRequested else { return }
        softwareKeyboardRequested = false
        onKeyboardActiveChange?(false)
    }
}

/// Resolves a one-finger direct touch exactly once. Motion wins immediately
/// and becomes a scroll; a stationary hold becomes a remote mouse drag. Using
/// one recognizer avoids the timing races that occur when a pan and long press
/// compete for the same touch sequence.
@MainActor
final class DirectTouchGestureRecognizer: UIGestureRecognizer {
    enum Mode {
        case scroll
        case drag
    }

    private(set) var mode: Mode?
    private(set) var currentLocation = CGPoint(x: 0, y: 0)
    private(set) var translation = CGPoint(x: 0, y: 0)
    /// Called at touch-down with the touch location. Returning true marks the
    /// touch as captured by an active scroll fling: hold-to-drag is skipped so
    /// the catching finger can only rest or continue scrolling.
    var onTouchDown: ((CGPoint) -> Bool)?

    private let movementSlop: CGFloat = 6
    private let holdDuration: TimeInterval = 0.3
    private var trackedTouch: UITouch?
    private var startLocation = CGPoint(x: 0, y: 0)
    private var holdTimer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible,
              trackedTouch == nil,
              touches.count == 1,
              event.allTouches?.count == 1,
              let touch = touches.first else {
            rejectGesture()
            return
        }

        trackedTouch = touch
        currentLocation = touch.location(in: view)
        startLocation = currentLocation
        translation = CGPoint(x: 0, y: 0)
        let capturedByFling = onTouchDown?(currentLocation) ?? false
        if !capturedByFling {
            scheduleHoldTimer()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        updateMetrics(for: trackedTouch)

        if mode == nil {
            guard hypot(translation.x, translation.y) >= movementSlop else { return }
            invalidateHoldTimer()
            mode = .scroll
            state = .began
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        updateMetrics(for: trackedTouch)
        invalidateHoldTimer()
        state = mode == nil ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        invalidateHoldTimer()
        state = mode == nil ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        invalidateHoldTimer()
        mode = nil
        trackedTouch = nil
        currentLocation = CGPoint(x: 0, y: 0)
        startLocation = CGPoint(x: 0, y: 0)
        translation = CGPoint(x: 0, y: 0)
    }

    private func scheduleHoldTimer() {
        invalidateHoldTimer()
        let timer = Timer(
            timeInterval: holdDuration,
            target: self,
            selector: #selector(commitHold),
            userInfo: nil,
            repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func invalidateHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func updateMetrics(for touch: UITouch) {
        let location = touch.location(in: view)
        currentLocation = location
        translation = CGPoint(
            x: location.x - startLocation.x,
            y: location.y - startLocation.y)
    }

    private func rejectGesture() {
        invalidateHoldTimer()
        switch state {
        case .possible:
            state = .failed
        case .began, .changed:
            state = .cancelled
        default:
            break
        }
    }

    @objc private func commitHold() {
        holdTimer = nil
        guard state == .possible, trackedTouch != nil else { return }
        mode = .drag
        state = .began
    }
}

#if targetEnvironment(macCatalyst)
extension RemoteInputUIView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let point = framebufferPoint(for: location) else { return nil }
        catchMomentumFlingIfActive()
        focusForHardwareKeyboard()
        touchHandler.handleRightClick(x: point.x, y: point.y)
        // The remote desktop owns the contextual action; suppress a local menu.
        return nil
    }
}
#endif
#endif
