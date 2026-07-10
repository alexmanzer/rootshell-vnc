import Foundation

/// The complete scroll-wheel state carried by Apple's precise RFB scroll
/// command. Its fields mirror the coarse, fixed-point, point, and phase data
/// forwarded by the native Screen Sharing client.
public struct AppleScrollEvent: Sendable, Equatable {
    public static let messageType: UInt8 = 0x17
    public static let payloadByteCount: UInt16 = 54
    public static let wireByteCount = 58
    public static let inputEventVersion: UInt16 = 1
    public static let scrollWheelEventSubtype: UInt16 = 11

    public struct Phase: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let none: Phase = []
        public static let began = Phase(rawValue: 1)
        public static let changed = Phase(rawValue: 2)
        public static let ended = Phase(rawValue: 4)
        public static let cancelled = Phase(rawValue: 8)
        public static let mayBegin = Phase(rawValue: 128)
    }

    /// Raw momentum values carried by CGEvent field 123. Unlike the direct
    /// scroll phase field, the terminal value is `3`, not a bit flag.
    public enum MomentumPhase: UInt32, Sendable {
        case none = 0
        case began = 1
        case changed = 2
        case ended = 3
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let instantMouser = Flags(rawValue: 1 << 0)
        public static let continuous = Flags(rawValue: 1 << 1)
    }

    public let deltaX: Int16
    public let deltaY: Int16
    public let deltaZ: Int16
    public let fixedDeltaX: Int32
    public let fixedDeltaY: Int32
    public let fixedDeltaZ: Int32
    public let pointDeltaX: Int32
    public let pointDeltaY: Int32
    public let pointDeltaZ: Int32
    public let scrollPhase: Phase
    public let momentumPhase: MomentumPhase
    public let scrollCount: UInt32
    public let flags: Flags
    public let x: UInt16
    public let y: UInt16

    public init(
        deltaX: Int16 = 0,
        deltaY: Int16 = 0,
        deltaZ: Int16 = 0,
        fixedDeltaX: Int32 = 0,
        fixedDeltaY: Int32 = 0,
        fixedDeltaZ: Int32 = 0,
        pointDeltaX: Int32 = 0,
        pointDeltaY: Int32 = 0,
        pointDeltaZ: Int32 = 0,
        scrollPhase: Phase = .none,
        momentumPhase: MomentumPhase = .none,
        scrollCount: UInt32 = 1,
        flags: Flags = [],
        x: UInt16,
        y: UInt16
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.deltaZ = deltaZ
        self.fixedDeltaX = fixedDeltaX
        self.fixedDeltaY = fixedDeltaY
        self.fixedDeltaZ = fixedDeltaZ
        self.pointDeltaX = pointDeltaX
        self.pointDeltaY = pointDeltaY
        self.pointDeltaZ = pointDeltaZ
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.scrollCount = scrollCount
        self.flags = flags
        self.x = x
        self.y = y
    }
}
