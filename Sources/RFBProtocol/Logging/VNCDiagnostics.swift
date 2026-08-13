import Foundation

/// Central policy for diagnostics that may expose remote-screen contents,
/// credentials, input, endpoints, or raw protocol/media bytes.
package enum VNCDiagnostics {
    /// Sensitive diagnostics exist only in developer builds and remain off
    /// until their individual environment switch is explicitly configured.
    package static var allowsSensitiveDiagnostics: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    package static func value(
        for key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard allowsSensitiveDiagnostics,
              let value = environment[key],
              !value.isEmpty else { return nil }
        return value
    }

    package static func isEnabled(
        _ key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        value(for: key, environment: environment) == "1"
    }
}
