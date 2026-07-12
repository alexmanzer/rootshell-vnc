import Observation

/// Coordinates ownership of hardware-keyboard input for a remote desktop.
///
/// Standalone clients can use the controller created by `RemoteDesktopView`.
/// Container applications can retain one controller per VNC tab and use it to
/// implement an escape shortcut without duplicating keyboard state.
@MainActor
@Observable
public final class VNCKeyboardCapture {
    public private(set) var isCaptured: Bool

    public init(isCaptured: Bool = true) {
        self.isCaptured = isCaptured
    }

    public func capture() {
        isCaptured = true
    }

    public func release() {
        isCaptured = false
    }

    public func toggle() {
        isCaptured.toggle()
    }
}
