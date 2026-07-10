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

    // MARK: - Init

    /// Create a touch input handler that delegates pointer events to the given closure.
    ///
    /// - Parameter sendPointerEvent: A closure called with (buttonMask, x, y)
    ///   for each generated pointer event.
    public init(sendPointerEvent: @escaping PointerEventHandler) {
        self.sendPointerEvent = sendPointerEvent
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
    /// Negative deltaY scrolls up, positive deltaY scrolls down.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    ///   - deltaY: The vertical scroll amount. Negative = up, positive = down.
    public func handleScroll(x: UInt16, y: UInt16, deltaY: CGFloat) {
        // VNC uses button 4 (bit 3) for scroll up and button 5 (bit 4) for scroll down.
        // Each click of the wheel is a separate press+release pair.
        guard deltaY != 0 else { return }
        let steps = min(20, max(1, Int(abs(deltaY) / 10)))
        let button: UInt8 = deltaY < 0 ? Self.scrollUp : Self.scrollDown

        for _ in 0..<steps {
            sendPointerEvent(button, x, y)
            sendPointerEvent(0, x, y)
        }
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
