import Foundation

/// Apple's parallel gesture-scroll record. Native Screen Sharing emits this
/// alongside each precise wheel record so AppKit locks the gesture to the view
/// under the cursor when the began phase arrives.
public struct AppleGestureScrollEvent: Sendable, Equatable {
    public static let messageType: UInt8 = 0x17
    public static let payloadByteCount: UInt16 = 32
    public static let wireByteCount = 36
    public static let inputEventVersion: UInt16 = 1
    public static let gestureScrollSubtype: UInt16 = 8

    public let deltaX: Float
    public let deltaY: Float
    public let deltaZ: Float
    public let naturalScrolling: Bool
    public let gesturePhase: AppleScrollEvent.Phase
    public let gestureMask: UInt32
    public let x: UInt16
    public let y: UInt16

    public init(
        deltaX: Float = 0,
        deltaY: Float = 0,
        deltaZ: Float = 0,
        naturalScrolling: Bool = true,
        gesturePhase: AppleScrollEvent.Phase,
        gestureMask: UInt32 = 0xe01c_0000,
        x: UInt16,
        y: UInt16
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.deltaZ = deltaZ
        self.naturalScrolling = naturalScrolling
        self.gesturePhase = gesturePhase
        self.gestureMask = gestureMask
        self.x = x
        self.y = y
    }
}
