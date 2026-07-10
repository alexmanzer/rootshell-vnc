import Foundation

/// One screen requested by the standard RFB `SetDesktopSize` extension.
public struct SetDesktopSizeScreen: Sendable, Equatable {
    public let id: UInt32
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16
    public let flags: UInt32

    public init(
        id: UInt32,
        x: UInt16 = 0,
        y: UInt16 = 0,
        width: UInt16,
        height: UInt16,
        flags: UInt32 = 0
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.flags = flags
    }
}

/// Standard RFB client message 251. It may only be sent after the server has
/// announced the `ExtendedDesktopSize` pseudo-encoding.
public struct SetDesktopSizeRequest: Sendable, Equatable {
    public static let messageType: UInt8 = 251
    public static let headerWireSize = 8

    public let width: UInt16
    public let height: UInt16
    public let screens: [SetDesktopSizeScreen]

    public init(width: UInt16, height: UInt16, screens: [SetDesktopSizeScreen]) {
        precondition(!screens.isEmpty && screens.count <= Int(UInt8.max))
        self.width = width
        self.height = height
        self.screens = screens
    }
}
