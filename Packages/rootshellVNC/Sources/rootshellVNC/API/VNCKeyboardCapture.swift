import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Modifiers supplied by a container-provided keyboard UI.
///
/// These are additive to modifiers reported by a physical keyboard. The
/// remote input responder applies them to the next software- or
/// hardware-keyboard input and then calls the capture object's consumption
/// callback so hosts can clear one-shot state while retaining locked state.
public struct VNCKeyboardModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
}

#if canImport(UIKit)
/// The primary input view used by the remote responder.
@MainActor
public enum VNCKeyboardPrimaryInputView {
    /// Retain the package default: show the system keyboard only when it has
    /// been explicitly requested, otherwise use the package's suppressed
    /// zero-sized input view so hardware keyboard capture remains active.
    case packageDefault

    /// Always ask UIKit for the system software keyboard.
    case systemKeyboard

    /// Use a host-provided primary input view. A zero-height view allows an
    /// accessory-only toolbar while keeping the software keyboard hidden.
    case custom(UIView)

    /// Use the system keyboard when it is explicitly requested and otherwise
    /// use the host view. This is the normal accessory-only integration mode:
    /// the package HUD can still summon the software keyboard without waiting
    /// for a host-side state round trip.
    case systemKeyboardWhenRequested(otherwise: UIView)
}

/// One coherent snapshot of the input views supplied by a container app.
/// Updating the snapshot causes a focused responder to reload both views
/// together, preventing primary/accessory state from getting out of sync.
@MainActor
public struct VNCKeyboardInputViews {
    public var primary: VNCKeyboardPrimaryInputView
    public var accessory: UIView?

    public init(
        primary: VNCKeyboardPrimaryInputView = .packageDefault,
        accessory: UIView? = nil
    ) {
        self.primary = primary
        self.accessory = accessory
    }

    public static var packageDefault: Self { Self() }
}
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
    /// Atomic host input-view configuration. Standalone clients can leave
    /// this at ``VNCKeyboardInputViews/packageDefault``.
    public var inputViews: VNCKeyboardInputViews = .packageDefault {
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

    /// Modifiers contributed by a host toolbar. The remote responder merges
    /// these with physical modifiers without turning Control chords into C0
    /// text bytes.
    public var supplementalModifiers: VNCKeyboardModifiers = []

    /// Called after a non-modifier key is successfully dispatched with
    /// nonempty supplemental modifiers. Hosts use this to consume one-shot
    /// state; locked state can remain in ``supplementalModifiers``.
    public var onSupplementalModifiersConsumed: (@MainActor () -> Void)?

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
