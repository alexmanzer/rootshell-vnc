#if canImport(UIKit)
import SwiftUI
import UIKit
import RFBProtocol
import RFBRendering

/// Transparent UIKit input surface shared by Adaptive and Full Quality modes.
/// UIKit is used here because SwiftUI gestures do not expose mouse buttons,
/// hover, scroll-wheel events, touch counts, or key-up events consistently.
struct RemoteInteractionView: UIViewRepresentable {
    @Binding var viewport: RemoteViewportState
    @Binding var keyboardActive: Bool

    let framebufferSize: CGSize
    let touchHandler: TouchInputHandler
    let keyboardHandler: KeyboardInputHandler
    let remoteCursor: RemoteCursor?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> RemoteInputUIView {
        let view = RemoteInputUIView(
            touchHandler: touchHandler,
            keyboardHandler: keyboardHandler)
        view.onViewportChange = { [weak coordinator = context.coordinator] state in
            coordinator?.parent.viewport = state
        }
        view.onKeyboardActiveChange = { [weak coordinator = context.coordinator] active in
            coordinator?.parent.keyboardActive = active
        }
        return view
    }

    func updateUIView(_ uiView: RemoteInputUIView, context: Context) {
        context.coordinator.parent = self
        uiView.update(
            framebufferSize: framebufferSize,
            viewport: viewport,
            keyboardActive: keyboardActive,
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
final class RemoteInputUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    var onViewportChange: ((RemoteViewportState) -> Void)?
    var onKeyboardActiveChange: ((Bool) -> Void)?

    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler
    private var framebufferSize: CGSize = .zero
    private var viewport = RemoteViewportState()
    private var softwareKeyboardRequested = false
    private var pressedKeysyms: [Int: UInt32] = [:]
    private var lastPointerPoint: (x: UInt16, y: UInt16)?
    private var remoteCursor: RemoteCursor?
    private var pointerDragActive = false
    private var lastKnownFramebufferPoint: (x: UInt16, y: UInt16)?
    private var lastScrollPoint: (x: UInt16, y: UInt16)?
    private var scrollPointAccumulator = ScrollPointAccumulator()
    private var previousScrollTranslation = CGPoint.zero
    private var directScrollPhaseActive = false
    private var momentumScrollPhaseActive = false
    private weak var activeScrollRecognizer: UIPanGestureRecognizer?
    private var lastDirectScrollVelocity = CGPoint.zero
    private var lastDirectScrollVelocityTimestamp: CFTimeInterval = 0
    private var previousScrollTimestamp: CFTimeInterval = 0
    private var syntheticMomentumVelocity = CGPoint.zero
    private var syntheticMomentumLastTimestamp: CFTimeInterval = 0
    private var momentumDisplayLink: CADisplayLink?
    private let suppressedInputView = UIView(frame: .zero)
    #if DEBUG
    private let inputLog = VNCLogger(category: "InputRouting")
    private var inputLogBudget = 128
    #endif

    private lazy var scrollRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleNativeScrollState(_:)))
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
    private lazy var longPressRecognizer = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handleLongPress(_:)))
    private lazy var hoverRecognizer = UIHoverGestureRecognizer(
        target: self,
        action: #selector(handleHover(_:)))
    private lazy var pointerInteraction = UIPointerInteraction(delegate: self)
    init(
        touchHandler: TouchInputHandler,
        keyboardHandler: KeyboardInputHandler
    ) {
        self.touchHandler = touchHandler
        self.keyboardHandler = keyboardHandler
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityLabel = "Remote desktop input"
        configureRecognizers()
        addInteraction(pointerInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        }
        super.willMove(toWindow: newWindow)
    }

    /// Suppress the software keyboard while retaining hardware-keyboard focus
    /// after mouse/trackpad interaction. The explicit keyboard button switches
    /// this back to the system keyboard on touch devices.
    override var inputView: UIView? {
        softwareKeyboardRequested ? nil : suppressedInputView
    }

    override var inputAccessoryView: UIView? {
        softwareKeyboardRequested ? keyboardAccessory : nil
    }

    var hasText: Bool { true }

    private lazy var keyboardAccessory: UIToolbar = {
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(
                title: "Done",
                primaryAction: UIAction { [weak self] _ in
                    self?.dismissKeyboard()
                })
        ]
        toolbar.sizeToFit()
        return toolbar
    }()

    func update(
        framebufferSize: CGSize,
        viewport: RemoteViewportState,
        keyboardActive: Bool,
        remoteCursor: RemoteCursor?
    ) {
        self.framebufferSize = framebufferSize
        self.viewport = viewport
        self.viewport.clampOffset(
            viewSize: bounds.size,
            framebufferSize: framebufferSize)

        if self.remoteCursor?.image !== remoteCursor?.image {
            self.remoteCursor = remoteCursor
            pointerInteraction.invalidate()
        }

        guard keyboardActive != softwareKeyboardRequested else { return }
        softwareKeyboardRequested = keyboardActive
        if keyboardActive {
            if !isFirstResponder { becomeFirstResponder() }
            reloadInputViews()
        } else if isFirstResponder {
            resignFirstResponder()
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
        for character in text {
            keyboardHandler.handleKeyTap(character)
        }
    }

    func deleteBackward() {
        keyboardHandler.handleKeyPress(.delete)
        keyboardHandler.handleKeyRelease(.delete)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = Int(key.keyCode.rawValue)
            // UIKey.characters is the text produced by the active keyboard
            // layout after Shift/Option are applied (for example, "!" instead
            // of "1"). charactersIgnoringModifiers loses that information.
            let keysym = KeyboardInputHandler.keysymForHIDUsage(
                UInt32(usage),
                characters: key.characters)
            guard keysym != 0 else {
                unhandled.insert(press)
                continue
            }
            pressedKeysyms[usage] = keysym
            keyboardHandler.handleKeysym(downFlag: true, keysym: keysym)
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseHardwarePresses(presses)
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseHardwarePresses(presses)
        if !unhandled.isEmpty {
            super.pressesCancelled(unhandled, with: event)
        }
    }

    private func releaseHardwarePresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = Int(key.keyCode.rawValue)
            guard let keysym = pressedKeysyms.removeValue(forKey: usage) else {
                unhandled.insert(press)
                continue
            }
            keyboardHandler.handleKeysym(downFlag: false, keysym: keysym)
        }
        return unhandled
    }

    private func releaseAllPressedKeys() {
        for keysym in pressedKeysyms.values {
            keyboardHandler.handleKeysym(downFlag: false, keysym: keysym)
        }
        pressedKeysyms.removeAll()
    }

    private func releasePointerDrag() {
        if pointerDragActive, let point = lastPointerPoint {
            touchHandler.handleDragEnd(x: point.x, y: point.y)
        }
        pointerDragActive = false
        lastPointerPoint = nil
    }

    /// UIKit exposes touch and indirect-pointer scrolling through the same pan
    /// recognizer, but Catalyst does not consistently expose a deceleration
    /// phase. Consume its direct translation and always generate the momentum
    /// tail from the final measured velocity ourselves.
    @objc private func handleNativeScrollState(_ recognizer: UIPanGestureRecognizer) {
        logInputRoute(
            "scroll state=\(recognizer.state.rawValue) "
            + "translation=\(recognizer.translation(in: self))")
        switch recognizer.state {
        case .began:
            if momentumScrollPhaseActive {
                endMomentumScrollPhase()
                finishScrollInteraction()
            }
            activeScrollRecognizer = recognizer
            lastDirectScrollVelocity = .zero
            lastDirectScrollVelocityTimestamp = 0
            let translation = recognizer.translation(in: self)
            previousScrollTranslation = translation
            previousScrollTimestamp = CACurrentMediaTime()
            beginScrollInteractionIfNeeded(
                using: recognizer,
                initialTranslation: translation)
        case .changed:
            guard activeScrollRecognizer === recognizer else { return }
            let translation = recognizer.translation(in: self)
            let now = CACurrentMediaTime()
            let elapsed = now - previousScrollTimestamp
            let deltaX = translation.x - previousScrollTranslation.x
            let deltaY = translation.y - previousScrollTranslation.y
            let reportedVelocity = recognizer.velocity(in: self)
            if hypot(reportedVelocity.x, reportedVelocity.y) >= 1 {
                rememberScrollVelocity(reportedVelocity, at: now)
            } else if elapsed > 0, elapsed <= 0.1 {
                rememberScrollVelocity(CGPoint(
                    x: deltaX / CGFloat(elapsed),
                    y: deltaY / CGFloat(elapsed)), at: now)
            }
            let points = scrollPointAccumulator.consume(
                deltaX: deltaX,
                deltaY: deltaY)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            guard points.x != 0 || points.y != 0 else { return }
            sendScrollSample(
                pointDeltaX: points.x,
                pointDeltaY: points.y,
                scrollPhase: .changed)
        case .ended:
            guard activeScrollRecognizer === recognizer else { return }
            rememberScrollVelocity(recognizer.velocity(in: self))
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
        using recognizer: UIPanGestureRecognizer,
        initialTranslation: CGPoint
    ) {
        guard !directScrollPhaseActive else { return }
        if momentumScrollPhaseActive {
            endMomentumScrollPhase()
        }
        directScrollPhaseActive = true
        lastScrollPoint = nil
        scrollPointAccumulator.reset()
        captureScrollPoint(using: recognizer)
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
        let initialPoints = scrollPointAccumulator.consume(
            deltaX: initialTranslation.x,
            deltaY: initialTranslation.y)
        sendScrollSample(
            pointDeltaX: initialPoints.x,
            pointDeltaY: initialPoints.y,
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

    /// Preserve the final public pan velocity and generate a consistent tail
    /// on every platform instead of depending on UIKit's private scroll phase.
    @discardableResult
    private func beginSyntheticMomentumIfNeeded() -> Bool {
        guard momentumDisplayLink == nil else { return false }
        guard CACurrentMediaTime() - lastDirectScrollVelocityTimestamp <= 0.15 else {
            return false
        }
        let speed = hypot(lastDirectScrollVelocity.x, lastDirectScrollVelocity.y)
        guard speed >= 25 else { return false }

        let maximumSpeed: CGFloat = 12_000
        let scale = min(1, maximumSpeed / speed)
        syntheticMomentumVelocity = CGPoint(
            x: lastDirectScrollVelocity.x * scale,
            y: lastDirectScrollVelocity.y * scale)
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

    private func rememberScrollVelocity(
        _ velocity: CGPoint,
        at timestamp: CFTimeInterval = CACurrentMediaTime()
    ) {
        // Some platforms report zero from the terminal callback. Retain the
        // newest meaningful changed-state sample instead of erasing it.
        guard hypot(velocity.x, velocity.y) >= 1 else { return }
        lastDirectScrollVelocity = velocity
        lastDirectScrollVelocityTimestamp = timestamp
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

        let points = scrollPointAccumulator.consume(
            deltaX: syntheticMomentumVelocity.x * elapsed,
            deltaY: syntheticMomentumVelocity.y * elapsed)
        if points.x != 0 || points.y != 0 {
            sendScrollSample(
                pointDeltaX: points.x,
                pointDeltaY: points.y,
                scrollPhase: .none,
                momentumPhase: .changed)
        }

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

    private func cancelScrollInteraction() {
        endDirectScrollPhase(.cancelled)
        endMomentumScrollPhase()
        finishScrollInteraction()
    }

    private func captureScrollPoint(using recognizer: UIPanGestureRecognizer) {
        // For UIEvent.scroll, UIKit's zero-touch pan location is the actual
        // trackpad pointer position at gesture begin. iPadOS may not deliver
        // intervening hover callbacks, so a cached hover point can remain at
        // the last click and route the gesture to the wrong remote view.
        if let point = framebufferPoint(for: recognizer.location(in: self)) {
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
        logInputRoute(
            "send scroll delta=(\(pointDeltaX),\(pointDeltaY)) "
            + "phase=\(scrollPhase.rawValue) pos=(\(point.x),\(point.y))")
        touchHandler.handleScroll(
            x: point.x,
            y: point.y,
            pointDeltaX: pointDeltaX,
            pointDeltaY: pointDeltaY,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase)
    }

    private func finishScrollInteraction() {
        guard !directScrollPhaseActive, !momentumScrollPhaseActive else { return }
        activeScrollRecognizer = nil
        lastScrollPoint = nil
        scrollPointAccumulator.reset()
        lastDirectScrollVelocity = .zero
        lastDirectScrollVelocityTimestamp = 0
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

        scrollRecognizer.minimumNumberOfTouches = 0
        scrollRecognizer.maximumNumberOfTouches = 1
        scrollRecognizer.allowedTouchTypes = directTouchTypes
        scrollRecognizer.allowedScrollTypesMask = .all
        scrollRecognizer.delegate = self

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

        longPressRecognizer.minimumPressDuration = 0.5
        longPressRecognizer.allowedTouchTypes = directTouchTypes
        longPressRecognizer.delegate = self

        hoverRecognizer.allowedTouchTypes = pointerTypes
        hoverRecognizer.delegate = self

        for recognizer in [
            scrollRecognizer,
            pinchRecognizer,
            viewportPanRecognizer,
            pointerDragRecognizer,
            tapRecognizer,
            doubleTapRecognizer,
            rightTapRecognizer,
            longPressRecognizer,
            hoverRecognizer,
        ] {
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
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
            guard let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
            lastPointerPoint = point
            pointerDragActive = true
            touchHandler.handleDrag(x: point.x, y: point.y)
        case .ended, .cancelled, .failed:
            releasePointerDrag()
        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
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
        touchHandler.handleDoubleTap(x: point.x, y: point.y)
    }

    @objc private func handleRightTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        touchHandler.handleRightClick(x: point.x, y: point.y)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        touchHandler.handleRightClick(x: point.x, y: point.y)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
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

    /// Adopt the remote cursor's silhouette so shape changes (I-beam, resize
    /// arrows, pointing hand) show without a server round trip. The pointer
    /// itself stays fully local; nil falls back to the system arrow.
    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard let cursor = remoteCursor,
              framebufferSize.width > 0,
              let frame = viewport.displayedFrame(
                viewSize: bounds.size,
                framebufferSize: framebufferSize),
              frame.width > 0 else { return nil }

        // Cursor pixels arrive in framebuffer units; the pointer is drawn in
        // view points.
        let scale = frame.width / framebufferSize.width
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        guard scale > 0,
              let scaledPath = cursor.shapePath.copy(using: &transform),
              !scaledPath.isEmpty else { return nil }
        return UIPointerStyle(shape: .path(UIBezierPath(cgPath: scaledPath)))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive event: UIEvent
    ) -> Bool {
        switch event.type {
        case .scroll:
            let accepted = gestureRecognizer === scrollRecognizer
            if accepted { logInputRoute("received UIEvent.scroll") }
            return accepted
        case .hover:
            return gestureRecognizer === hoverRecognizer
        default:
            return true
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pointerDragRecognizer,
           !gestureRecognizer.buttonMask.isEmpty {
            return gestureRecognizer.buttonMask.contains(.primary)
        }
        return true
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
            UInt16(min(CGFloat(UInt16.max), max(0, point.x))),
            UInt16(min(CGFloat(UInt16.max), max(0, point.y))))
        lastKnownFramebufferPoint = result
        return result
    }

    private func visibleLocation(for contentLocation: CGPoint) -> CGPoint {
        contentLocation
    }

    private func logInputRoute(_ message: String) {
        #if DEBUG
        guard inputLogBudget > 0 else { return }
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
        guard !isFirstResponder else { return }
        softwareKeyboardRequested = false
        becomeFirstResponder()
    }

    private func dismissKeyboard() {
        softwareKeyboardRequested = false
        resignFirstResponder()
        onKeyboardActiveChange?(false)
    }
}
#endif
