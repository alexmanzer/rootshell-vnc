import SwiftUI
import RFBProtocol

/// Translates iOS/macOS touch and mouse gestures into VNC pointer events.
///
/// This handler converts high-level gesture callbacks (tap, drag, scroll)
/// into the low-level RFB pointer events expected by a VNC server.
///
/// VNC pointer events use a button mask bitmask:
/// - Bit 0 (0x01): Left button
/// - Bit 1 (0x02): Middle button
/// - Bit 2 (0x04): Right button
/// - Bit 3 (0x08): Scroll up (wheel up)
/// - Bit 4 (0x10): Scroll down (wheel down)
@MainActor
public struct TouchInputHandler {

    // MARK: - Types

    /// A closure that sends a pointer event to the VNC server.
    ///
    /// - Parameters:
    ///   - buttonMask: Bitmask of pressed buttons.
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public typealias PointerEventHandler = @MainActor (UInt8, UInt16, UInt16) -> Void
    /// A closure that sends one continuous scroll sample. The session chooses
    /// precise Apple input or ordinary RFB wheel buttons from server capability
    /// negotiation.
    public typealias ScrollEventHandler = @MainActor (AppleScrollEvent) -> Void
    /// A closure that sends the native begin/end envelope around precise
    /// scrolling. Conventional RFB transports ignore these events.
    public typealias GestureEventHandler = @MainActor (AppleGestureEvent) -> Void

    // MARK: - Button mask constants

    /// Left mouse button.
    public nonisolated static let leftButton: UInt8 = 0x01
    /// Middle mouse button.
    public nonisolated static let middleButton: UInt8 = 0x02
    /// Right mouse button.
    public nonisolated static let rightButton: UInt8 = 0x04
    /// Scroll wheel up.
    public nonisolated static let scrollUp: UInt8 = 0x08
    /// Scroll wheel down.
    public nonisolated static let scrollDown: UInt8 = 0x10

    // MARK: - Properties

    private let sendPointerEvent: PointerEventHandler
    private let sendScrollEvent: ScrollEventHandler?
    private let sendGestureEvent: GestureEventHandler?

    // MARK: - Init

    /// Create a touch input handler that delegates pointer events to the given closure.
    ///
    /// - Parameter sendPointerEvent: A closure called with (buttonMask, x, y)
    ///   for each generated pointer event.
    public init(sendPointerEvent: @escaping PointerEventHandler) {
        self.sendPointerEvent = sendPointerEvent
        self.sendScrollEvent = nil
        self.sendGestureEvent = nil
    }

    public init(
        sendPointerEvent: @escaping PointerEventHandler,
        sendScrollEvent: @escaping ScrollEventHandler,
        sendGestureEvent: GestureEventHandler? = nil
    ) {
        self.sendPointerEvent = sendPointerEvent
        self.sendScrollEvent = sendScrollEvent
        self.sendGestureEvent = sendGestureEvent
    }

    // MARK: - Gesture Handlers

    /// Handle a single tap at the given framebuffer coordinates.
    ///
    /// Generates a left-button press followed by a release to simulate a click.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleTap(x: UInt16, y: UInt16) {
        // Move to position
        sendPointerEvent(0, x, y)
        // Press left button
        sendPointerEvent(Self.leftButton, x, y)
        // Release left button
        sendPointerEvent(0, x, y)
    }

    /// Handle a right-click (context menu) at the given framebuffer coordinates.
    ///
    /// Typically triggered by a two-finger tap on iOS or right-click on macOS.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleRightClick(x: UInt16, y: UInt16) {
        // Move to position
        sendPointerEvent(0, x, y)
        // Press right button
        sendPointerEvent(Self.rightButton, x, y)
        // Release right button
        sendPointerEvent(0, x, y)
    }

    /// Handle pointer movement (e.g., during a drag gesture).
    ///
    /// Sends a pointer event with no buttons pressed, indicating cursor movement.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleMove(x: UInt16, y: UInt16) {
        sendPointerEvent(0, x, y)
    }

    /// Handle a drag with the left button held down.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleDrag(x: UInt16, y: UInt16) {
        sendPointerEvent(Self.leftButton, x, y)
    }

    /// Handle a drag end (release the left button).
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleDragEnd(x: UInt16, y: UInt16) {
        sendPointerEvent(0, x, y)
    }

    /// Handle a scroll event at the given framebuffer coordinates.
    ///
    /// Translates vertical scroll deltas into VNC scroll-wheel button events.
    /// Positive deltaY scrolls up and negative deltaY scrolls down, matching
    /// the CGEvent convention used by Apple's native RFB fallback.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    ///   - deltaY: The vertical scroll amount. Positive = up, negative = down.
    public func handleScroll(x: UInt16, y: UInt16, deltaY: CGFloat) {
        // VNC uses button 4 (bit 3) for scroll up and button 5 (bit 4) for scroll down.
        // Each click of the wheel is a separate press+release pair.
        guard deltaY != 0 else { return }
        let magnitude = min(20, max(1, Int(abs(deltaY) / 10)))
        handleScroll(
            x: x,
            y: y,
            steps: deltaY > 0 ? magnitude : -magnitude)
    }

    /// Send an exact signed number of VNC wheel clicks. Positive values scroll
    /// up and negative values scroll down.
    public func handleScroll(x: UInt16, y: UInt16, steps: Int) {
        guard steps != 0 else { return }
        let magnitude = Int(min(UInt(20), steps.magnitude))
        let button: UInt8 = steps > 0 ? Self.scrollUp : Self.scrollDown

        for _ in 0..<magnitude {
            sendPointerEvent(button, x, y)
            sendPointerEvent(0, x, y)
        }
    }

    /// Forward a point-accurate continuous scroll sample. CoreGraphics carries
    /// point pixels alongside accelerated whole-wheel and signed 16.16 wheel
    /// units; the conversion below matches values measured from trackpad events.
    public func handleScroll(
        x: UInt16,
        y: UInt16,
        pointDeltaX: Int32,
        pointDeltaY: Int32,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        let event = AppleScrollEvent(
            deltaX: Self.coarseDelta(for: pointDeltaX),
            deltaY: Self.coarseDelta(for: pointDeltaY),
            fixedDeltaX: Self.fixed16_16(for: pointDeltaX),
            fixedDeltaY: Self.fixed16_16(for: pointDeltaY),
            pointDeltaX: pointDeltaX,
            pointDeltaY: pointDeltaY,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
            flags: [.continuous, .directionInvertedFromDevice],
            x: x,
            y: y)

        if let sendScrollEvent {
            sendScrollEvent(event)
        } else if event.deltaY != 0 {
            handleScroll(x: x, y: y, steps: Int(event.deltaY))
        }
    }

    private nonisolated static func fixed16_16(for pointDelta: Int32) -> Int32 {
        // Measured public CGEvents use approximately ten pixels per one fixed
        // wheel unit. Integer division preserves the sign and total direction.
        Int32(clamping: Int64(pointDelta) * 65_536 / 10)
    }

    private nonisolated static func coarseDelta(for pointDelta: Int32) -> Int16 {
        guard pointDelta != 0 else { return 0 }
        let wholeWheelUnits = pointDelta / 10
        if wholeWheelUnits != 0 {
            return Int16(clamping: wholeWheelUnits)
        }
        return pointDelta > 0 ? 1 : -1
    }

    /// Forward the gesture envelope that native Screen Sharing places around
    /// precise scroll-wheel records.
    public func handleGesture(
        kind: AppleGestureEvent.Kind,
        x: UInt16,
        y: UInt16
    ) {
        sendGestureEvent?(AppleGestureEvent(kind: kind, x: x, y: y))
    }


    /// Handle a double-tap at the given framebuffer coordinates.
    ///
    /// Generates two consecutive left-button click sequences.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleDoubleTap(x: UInt16, y: UInt16) {
        handleTap(x: x, y: y)
        handleTap(x: x, y: y)
    }
}

/// Converts fractional UIKit point movement to the integer point fields on the
/// wire without losing sub-point motion between callbacks.
struct ScrollPointAccumulator: Equatable, Sendable {
    private(set) var remainderX: CGFloat = 0
    private(set) var remainderY: CGFloat = 0

    mutating func consume(deltaX: CGFloat, deltaY: CGFloat) -> (x: Int32, y: Int32) {
        guard deltaX.isFinite, deltaY.isFinite else { return (0, 0) }
        remainderX += deltaX
        remainderY += deltaY
        let x = Self.consumeAxis(&remainderX)
        let y = Self.consumeAxis(&remainderY)
        return (x, y)
    }

    mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    private static func consumeAxis(_ remainder: inout CGFloat) -> Int32 {
        if remainder >= CGFloat(Int32.max) {
            remainder = 0
            return Int32.max
        }
        if remainder <= CGFloat(Int32.min) {
            remainder = 0
            return Int32.min
        }
        let whole = Int32(remainder.rounded(.towardZero))
        remainder -= CGFloat(whole)
        return whole
    }
}
