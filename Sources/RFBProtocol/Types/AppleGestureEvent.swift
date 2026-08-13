import Foundation

/// Gesture envelope defined around precise
/// scroll-wheel records.
///
/// `RFBPostGestureEventStart` and `RFBPostGestureEventEnd` serialize these as
/// type-23 input events with subtypes 1 and 2. The source subtype is the public
/// `NSEventSubtypeTouch` value used for trackpad/touch gestures.
public struct AppleGestureEvent: Sendable, Equatable {
    public static let messageType: UInt8 = 0x17
    public static let payloadByteCount: UInt16 = 12
    public static let wireByteCount = 16
    public static let inputEventVersion: UInt16 = 1

    public enum Kind: UInt16, Sendable {
        case began = 1
        case ended = 2
    }

    public enum SourceSubtype: UInt32, Sendable {
        case touch = 3
    }

    public let kind: Kind
    public let sourceSubtype: SourceSubtype
    public let x: UInt16
    public let y: UInt16

    public init(
        kind: Kind,
        sourceSubtype: SourceSubtype = .touch,
        x: UInt16,
        y: UInt16
    ) {
        self.kind = kind
        self.sourceSubtype = sourceSubtype
        self.x = x
        self.y = y
    }
}
