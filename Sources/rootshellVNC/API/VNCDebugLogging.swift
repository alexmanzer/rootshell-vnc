import Foundation
import RFBProtocol

/// Host-facing entry point for capturing the package's log stream.
///
/// Every VNC component logs through one facade (`VNCLogger`) into os.log with
/// `.private` privacy, which cannot be read back off a device. A host that
/// wants a retrievable log installs a sink here and receives the same records.
///
/// The API deliberately trades in `String` only, so a host that links just the
/// `rootshellVNC` product does not also have to link `RFBProtocol` to name a
/// level or category type.
public enum VNCDebugLogging {
    /// Install a sink for every package log record at or above `minimumLevel`.
    ///
    /// - Parameters:
    ///   - minimumLevel: One of `trace`, `debug`, `info`, `warning`, `error`.
    ///     Unrecognized names fall back to `info`. Keep the default unless a
    ///     specific investigation needs the per-frame `debug` traffic: the
    ///     media paths log at `debug` on hot code paths.
    ///   - sink: Receives `(level, category, message)` on whichever thread
    ///     produced the record. Must be cheap and thread-safe. Pass `nil` to
    ///     uninstall.
    ///
    /// Installing is idempotent; a second call replaces the previous sink.
    public static func install(
        minimumLevel: String = "info",
        sink: (@Sendable (_ level: String, _ category: String, _ message: String) -> Void)?
    ) {
        guard let sink else {
            VNCLogRelay.install(sink: nil)
            return
        }
        VNCLogRelay.install(minimumLevel: VNCLogLevel.named(minimumLevel)) { level, category, message in
            sink(level.name, category, message)
        }
    }

    /// Whether a sink is currently installed.
    public static var isInstalled: Bool { VNCLogRelay.isInstalled }
}
