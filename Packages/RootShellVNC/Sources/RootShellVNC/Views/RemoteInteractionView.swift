#if canImport(UIKit)
import SwiftUI
import UIKit
import RFBProtocol

/// Transparent UIKit input surface shared by Adaptive and Full Quality modes.
/// UIKit is used here because SwiftUI gestures do not expose mouse buttons,
/// hover, scroll-wheel events, touch counts, or key-up events consistently.
struct RemoteInteractionView: UIViewRepresentable {
    @Binding var viewport: RemoteViewportState
    @Binding var keyboardActive: Bool

    let framebufferSize: CGSize
    let touchHandler: TouchInputHandler
    let keyboardHandler: KeyboardInputHandler

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
            keyboardActive: keyboardActive)
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
final class RemoteInputUIView: UIScrollView, UIKeyInput, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    var onViewportChange: ((RemoteViewportState) -> Void)?
    var onKeyboardActiveChange: ((Bool) -> Void)?

    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler
    private var framebufferSize: CGSize = .zero
    private var viewport = RemoteViewportState()
    private var softwareKeyboardRequested = false
    private var pressedKeysyms: [Int: UInt32] = [:]
    private var lastPointerPoint: (x: UInt16, y: UInt16)?
    private var pointerDragActive = false
    private var lastKnownFramebufferPoint: (x: UInt16, y: UInt16)?
    private var lastScrollPoint: (x: UInt16, y: UInt16)?
    private var scrollPointAccumulator = ScrollPointAccumulator()
    private var previousScrollContentOffset = CGPoint.zero
    private var scrollCanvasConfigured = false
    private var isPositioningScrollCanvas = false
    private var directScrollPhaseActive = false
    private var momentumScrollPhaseActive = false
    private var nativeScrollSequence: UInt64 = 0
    private var pendingNativeScrollEnd: UInt64?
    private let suppressedInputView = UIView(frame: .zero)

    private lazy var pinchRecognizer = UIPinchGestureRecognizer(
        target: self,
        action: #selector(handlePinch(_:)))
    private lazy var viewportPanRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleViewportPan(_:)))
    private lazy var pointerPanRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handlePointerPan(_:)))
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
        configureNativeScrolling()
        configureRecognizers()
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
        keyboardActive: Bool
    ) {
        self.framebufferSize = framebufferSize
        self.viewport = viewport
        self.viewport.clampOffset(
            viewSize: bounds.size,
            framebufferSize: framebufferSize)

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
        configureScrollCanvasIfNeeded()
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

    /// Use UIScrollView's public touch/trackpad physics so direct manipulation,
    /// acceleration, and deceleration are generated by UIKit rather than by a
    /// custom multiplier or timer.
    private func configureNativeScrolling() {
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        isDirectionalLockEnabled = false
        decelerationRate = .normal
        delaysContentTouches = false
        canCancelContentTouches = true
        contentInsetAdjustmentBehavior = .never

        // Scroll-wheel/trackpad events have zero UIKit touches. Accept both
        // those and one direct finger; pointer drags remain on their separate
        // indirect-pointer recognizer.
        panGestureRecognizer.minimumNumberOfTouches = 0
        panGestureRecognizer.maximumNumberOfTouches = 1
        panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        panGestureRecognizer.allowedScrollTypesMask = .all
        panGestureRecognizer.addTarget(
            self,
            action: #selector(handleNativeScrollState(_:)))
    }

    private func configureScrollCanvasIfNeeded() {
        guard !scrollCanvasConfigured, bounds.width > 0, bounds.height > 0 else { return }
        isPositioningScrollCanvas = true
        contentSize = CGSize(width: 1_000_000, height: 1_000_000)
        contentOffset = CGPoint(
            x: (contentSize.width - bounds.width) / 2,
            y: (contentSize.height - bounds.height) / 2)
        previousScrollContentOffset = contentOffset
        scrollCanvasConfigured = true
        isPositioningScrollCanvas = false
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        beginScrollInteractionIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollCanvasConfigured, !isPositioningScrollCanvas else { return }
        // UIScrollView content offset moves opposite to CGEvent scroll delta.
        // Keeping this sign is what gives both natural touch and trackpad input
        // the same direction as Apple's native client.
        let deltaX = previousScrollContentOffset.x - contentOffset.x
        let deltaY = previousScrollContentOffset.y - contentOffset.y
        if isDecelerating {
            beginMomentumScrollPhaseIfNeeded()
        } else {
            beginScrollInteractionIfNeeded()
        }
        previousScrollContentOffset = contentOffset
        let points = scrollPointAccumulator.consume(
            deltaX: deltaX,
            deltaY: deltaY)
        guard points.x != 0 || points.y != 0 else { return }

        updateLastScrollPoint()
        sendScrollSample(
            pointDeltaX: points.x,
            pointDeltaY: points.y,
            scrollPhase: isDecelerating ? .none : .changed,
            momentumPhase: isDecelerating ? .changed : .none)
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        endDirectScrollPhase(.ended)
        if !decelerate {
            finishScrollInteraction()
        }
    }

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        // UIKit normally calls didEndDragging first, but keep the wire
        // lifecycle valid even on platforms where indirect scrolling omits it.
        endDirectScrollPhase(.ended)
        beginMomentumScrollPhaseIfNeeded()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        endMomentumScrollPhase(.ended)
        finishScrollInteraction()
    }

    /// Scroll-wheel sequences do not consistently use the dragging delegate
    /// callbacks on every UIKit platform. Observe the public pan state as a
    /// lifecycle fallback; direct-touch delegate callbacks remain idempotent.
    @objc private func handleNativeScrollState(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            // A fresh gesture interrupts momentum. Close that phase explicitly
            // before sending the next direct-scroll begin.
            if momentumScrollPhaseActive {
                endMomentumScrollPhase(.ended)
                finishScrollInteraction()
            }
            if pendingNativeScrollEnd != nil {
                endDirectScrollPhase(.ended)
                finishScrollInteraction()
            }
            nativeScrollSequence &+= 1
            beginScrollInteractionIfNeeded()
        case .cancelled, .failed:
            cancelScrollInteraction()
        case .ended:
            let sequence = nativeScrollSequence
            pendingNativeScrollEnd = sequence
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pendingNativeScrollEnd == sequence else { return }
                self.pendingNativeScrollEnd = nil
                guard self.directScrollPhaseActive,
                      !self.isDragging,
                      !self.isDecelerating else { return }
                self.endDirectScrollPhase(.ended)
                self.finishScrollInteraction()
            }
        default:
            break
        }
    }

    private func beginScrollInteractionIfNeeded() {
        guard !directScrollPhaseActive else { return }
        if momentumScrollPhaseActive {
            endMomentumScrollPhase(.ended)
        }
        directScrollPhaseActive = true
        pendingNativeScrollEnd = nil
        lastScrollPoint = nil
        scrollPointAccumulator.reset()
        previousScrollContentOffset = contentOffset
        updateLastScrollPoint()
        if let point = lastScrollPoint {
            touchHandler.handleGesture(
                kind: .began,
                x: point.x,
                y: point.y)
        }
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: .began,
            momentumPhase: .none)
    }

    private func beginMomentumScrollPhaseIfNeeded() {
        guard !momentumScrollPhaseActive else { return }
        endDirectScrollPhase(.ended)
        momentumScrollPhaseActive = true
        updateLastScrollPoint()
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: .none,
            momentumPhase: .began)
    }

    private func endDirectScrollPhase(_ phase: AppleScrollEvent.Phase) {
        pendingNativeScrollEnd = nil
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

    private func endMomentumScrollPhase(_ phase: AppleScrollEvent.Phase) {
        guard momentumScrollPhaseActive else { return }
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: .none,
            momentumPhase: phase)
        momentumScrollPhaseActive = false
    }

    private func cancelScrollInteraction() {
        endDirectScrollPhase(.cancelled)
        endMomentumScrollPhase(.cancelled)
        finishScrollInteraction()
    }

    private func updateLastScrollPoint() {
        if let point = framebufferPoint(
            for: panGestureRecognizer.location(in: self)) {
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
        momentumPhase: AppleScrollEvent.Phase
    ) {
        guard let point = lastScrollPoint else { return }
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
        lastScrollPoint = nil
        scrollPointAccumulator.reset()
        pendingNativeScrollEnd = nil

        // The large canvas exists only to let UIKit generate public scroll
        // physics. Recenter between sequences so it can never reach an edge
        // and silently stop delivering offset changes.
        guard scrollCanvasConfigured else {
            previousScrollContentOffset = contentOffset
            return
        }
        isPositioningScrollCanvas = true
        let center = CGPoint(
            x: (contentSize.width - bounds.width) / 2,
            y: (contentSize.height - bounds.height) / 2)
        setContentOffset(center, animated: false)
        previousScrollContentOffset = center
        isPositioningScrollCanvas = false
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

        pinchRecognizer.allowedTouchTypes = directTouchTypes
        pinchRecognizer.delegate = self

        viewportPanRecognizer.minimumNumberOfTouches = 2
        viewportPanRecognizer.maximumNumberOfTouches = 2
        viewportPanRecognizer.allowedTouchTypes = directTouchTypes
        viewportPanRecognizer.delegate = self

        pointerPanRecognizer.minimumNumberOfTouches = 1
        pointerPanRecognizer.maximumNumberOfTouches = 1
        pointerPanRecognizer.allowedTouchTypes = pointerTypes
        pointerPanRecognizer.allowedScrollTypesMask = []
        pointerPanRecognizer.delegate = self

        tapRecognizer.numberOfTapsRequired = 1
        tapRecognizer.allowedTouchTypes = allPointerTypes
        tapRecognizer.delegate = self

        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.allowedTouchTypes = allPointerTypes
        doubleTapRecognizer.delegate = self
        tapRecognizer.require(toFail: doubleTapRecognizer)

        rightTapRecognizer.numberOfTouchesRequired = 2
        rightTapRecognizer.allowedTouchTypes = directTouchTypes
        rightTapRecognizer.delegate = self

        longPressRecognizer.minimumPressDuration = 0.5
        longPressRecognizer.allowedTouchTypes = directTouchTypes
        longPressRecognizer.delegate = self

        hoverRecognizer.delegate = self

        for recognizer in [
            pinchRecognizer,
            viewportPanRecognizer,
            pointerPanRecognizer,
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

    @objc private func handlePointerPan(_ recognizer: UIPanGestureRecognizer) {
        focusForHardwareKeyboardIfNeeded(recognizer)
        switch recognizer.state {
        case .began, .changed:
            guard let point = framebufferPoint(for: recognizer.location(in: self)) else { return }
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
              let point = framebufferPoint(for: recognizer.location(in: self)) else { return }
        focusForHardwareKeyboardIfNeeded(recognizer)
        if recognizer.buttonMask.contains(.secondary) {
            touchHandler.handleRightClick(x: point.x, y: point.y)
        } else {
            touchHandler.handleTap(x: point.x, y: point.y)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(for: recognizer.location(in: self)) else { return }
        focusForHardwareKeyboardIfNeeded(recognizer)
        touchHandler.handleDoubleTap(x: point.x, y: point.y)
    }

    @objc private func handleRightTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(for: recognizer.location(in: self)) else { return }
        touchHandler.handleRightClick(x: point.x, y: point.y)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let point = framebufferPoint(for: recognizer.location(in: self)) else { return }
        touchHandler.handleRightClick(x: point.x, y: point.y)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        // Changing UIScrollView.bounds for trackpad physics can produce hover
        // updates under a stationary cursor. Never turn those into remote
        // pointer motion while a direct or momentum scroll is active.
        guard !directScrollPhaseActive,
              !momentumScrollPhaseActive,
              !isDragging,
              !isDecelerating,
              recognizer.state == .began || recognizer.state == .changed,
              let point = framebufferPoint(for: recognizer.location(in: self)) else { return }
        focusForHardwareKeyboard()
        touchHandler.handleMove(x: point.x, y: point.y)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pointerPanRecognizer,
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
        CGPoint(
            x: contentLocation.x - bounds.origin.x,
            y: contentLocation.y - bounds.origin.y)
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
