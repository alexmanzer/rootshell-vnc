/// How one-finger touch drives the remote pointer.
///
/// Absolute positioning is unreachable on a small screen once the desktop is
/// scaled down, because the finger hides the target it is trying to hit. The
/// relative mode trades the direct mapping for a visible cursor the finger
/// nudges, the way a physical trackpad does. Hover, indirect pointer, pencil,
/// and Catalyst input ignore this setting: they already carry their own
/// position.
public enum RemotePointerMode: String, CaseIterable, Hashable, Sendable {
    /// The pointer jumps to wherever the finger touches. Today's behaviour.
    case direct
    /// The finger moves a virtual cursor by a relative, accelerated delta.
    case trackpad
}
