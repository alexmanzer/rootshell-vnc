import Foundation

/// Host-installed presentation gate, checked at the frame-delivery sites.
///
/// The host arms it while the device may be locked: presenting into the
/// system's secure-mode lock snapshot gets the process killed by FrontBoard
/// (0x2BAD45EC "insecure drawing while in secure mode"). Checking at delivery
/// covers renderers created while locked and any pause sweep the host misses.
public enum VNCPresentationPolicy {
    /// Returning true suppresses frame presentation. Read on the main thread.
    @MainActor public static var isPresentationProhibited: () -> Bool = { false }
}
