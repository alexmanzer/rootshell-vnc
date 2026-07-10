#if canImport(UIKit)
import SwiftUI
import UIKit

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
final class RemoteInputUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
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
    private lazy var scrollRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleScroll(_:)))

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
            let keysym = KeyboardInputHandler.keysymForHIDUsage(
                UInt32(usage),
                characters: key.charactersIgnoringModifiers)
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

    private func configureRecognizers() {
        let directTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        let allPointerTypes = directTypes + [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]

        pinchRecognizer.allowedTouchTypes = directTypes
        pinchRecognizer.delegate = self

        viewportPanRecognizer.minimumNumberOfTouches = 2
        viewportPanRecognizer.maximumNumberOfTouches = 2
        viewportPanRecognizer.allowedTouchTypes = directTypes
        viewportPanRecognizer.delegate = self

        pointerPanRecognizer.minimumNumberOfTouches = 1
        pointerPanRecognizer.maximumNumberOfTouches = 1
        pointerPanRecognizer.allowedTouchTypes = allPointerTypes
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
        rightTapRecognizer.allowedTouchTypes = directTypes
        rightTapRecognizer.delegate = self

        longPressRecognizer.minimumPressDuration = 0.5
        longPressRecognizer.allowedTouchTypes = directTypes
        longPressRecognizer.delegate = self

        scrollRecognizer.minimumNumberOfTouches = 0
        scrollRecognizer.maximumNumberOfTouches = 0
        scrollRecognizer.allowedScrollTypesMask = .all
        scrollRecognizer.delegate = self

        hoverRecognizer.delegate = self

        for recognizer in [
            pinchRecognizer,
            viewportPanRecognizer,
            pointerPanRecognizer,
            tapRecognizer,
            doubleTapRecognizer,
            rightTapRecognizer,
            longPressRecognizer,
            scrollRecognizer,
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
            around: recognizer.location(in: self),
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
        guard recognizer.state == .began || recognizer.state == .changed,
              let point = framebufferPoint(for: recognizer.location(in: self)) else { return }
        focusForHardwareKeyboard()
        touchHandler.handleMove(x: point.x, y: point.y)
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed,
              let point = framebufferPoint(for: recognizer.location(in: self)) else { return }
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        guard translation.y != 0 else { return }
        touchHandler.handleScroll(x: point.x, y: point.y, deltaY: translation.y)
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
            for: location,
            viewSize: bounds.size,
            framebufferSize: framebufferSize) else { return nil }
        return (
            UInt16(min(CGFloat(UInt16.max), max(0, point.x))),
            UInt16(min(CGFloat(UInt16.max), max(0, point.y))))
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
