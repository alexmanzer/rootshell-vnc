/// Who draws the remote pointer.
///
/// A VNC server withholds the pointer from the picture as soon as the client
/// advertises any cursor pseudo-encoding, and ships the shape separately for
/// the client to composite. That keeps the pointer crisp and instant, but it
/// is also a local approximation: it cannot show what the remote window server
/// actually drew, and it stays one screen pixel wide however far the desktop
/// is scaled down.
///
/// Letting the server keep the pointer in the picture costs a round trip of
/// latency and scales the cursor with the zoom, but what arrives is exactly
/// what the remote screen shows.
public enum VNCCursorRendering: String, CaseIterable, Sendable {
    /// Advertise the cursor pseudo-encodings and draw the pointer locally.
    case client
    /// Advertise none of them, so the pointer arrives drawn into the frame.
    case server
}
