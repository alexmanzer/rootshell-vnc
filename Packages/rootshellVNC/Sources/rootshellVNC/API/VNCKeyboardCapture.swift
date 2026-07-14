import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Coordinates ownership of hardware-keyboard input for a remote desktop.
///
/// Standalone clients can use the controller created by `RemoteDesktopView`.
/// Container applications can retain one controller per VNC tab and use it to
/// implement an escape shortcut without duplicating keyboard state.
@MainActor
@Observable
public final class VNCKeyboardCapture {
    public private(set) var isCaptured: Bool

    #if canImport(UIKit)
    /// Supplies the `inputAccessoryView` for the remote input responder.
    ///
    /// Container applications set this to attach their own keyboard toolbar
    /// above the software keyboard. Return `nil` for no accessory (the
    /// default when unset). Reassigning the provider bumps
    /// ``inputViewsGeneration`` so a focused responder reloads immediately.
    public var inputAccessoryViewProvider: (@MainActor () -> UIView?)? {
        didSet { inputViewsGeneration &+= 1 }
    }

    /// Supplies a replacement `inputView` for the remote input responder,
    /// enabling a toolbar-only mode that shows the accessory without the
    /// system keyboard.
    ///
    /// When `nil` (the default), the remote input view keeps its built-in
    /// behavior: the software keyboard is suppressed unless explicitly
    /// requested. Reassigning the provider bumps ``inputViewsGeneration`` so
    /// a focused responder reloads immediately.
    public var inputViewProvider: (@MainActor () -> UIView?)? {
        didSet { inputViewsGeneration &+= 1 }
    }

    /// Monotonic counter observed by the remote input view. When it changes
    /// while that view is first responder, the view calls
    /// `reloadInputViews()` so provider changes take effect immediately.
    public private(set) var inputViewsGeneration: UInt64 = 0

    /// Requests an input-views reload without swapping providers, for when a
    /// provider's returned view changed its contents or height.
    public func setNeedsInputViewsReload() {
        inputViewsGeneration &+= 1
    }
    #endif

    /// Whether the software keyboard should be shown for the remote desktop.
    ///
    /// Two-way synced with `RemoteDesktopView`'s internal keyboard state:
    /// container applications can set it to show or hide the software
    /// keyboard, and observe it to mirror HUD- or user-driven changes.
    public var softwareKeyboardRequested: Bool = false

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
