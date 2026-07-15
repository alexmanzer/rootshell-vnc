import SwiftUI

/// Floating glass status card shown while a connection is being established
/// or re-established. Reads the session's connection state and live phase
/// text, and always offers a way out of a stuck attempt.
public struct ConnectionStatusOverlay: View {
    @Bindable var session: VNCSession

    public init(session: VNCSession) {
        self.session = session
    }

    public var body: some View {
        switch session.connectionState {
        case .connecting:
            ConnectionStatusCard(
                title: connectingTitle,
                detail: session.connectionPhaseDescription,
                actionLabel: String(localized: "Cancel", bundle: .module),
                actionRole: .cancel
            ) { session.disconnect() }

        case .reconnecting(let attempt, let delay):
            ConnectionStatusCard(
                title: String(localized: "Connection interrupted", bundle: .module),
                detail: delay > 0
                    ? String(localized: "Retry \(attempt) starts in about \(Int(ceil(delay))) seconds.", bundle: .module)
                    : (session.connectionPhaseDescription
                        ?? String(localized: "Reconnecting now…", bundle: .module)),
                actionLabel: String(localized: "Stop Reconnecting", bundle: .module),
                actionRole: .destructive
            ) { session.disconnect() }

        default:
            EmptyView()
        }
    }

    private var connectingTitle: String {
        if let host = session.connectingHostLabel, !host.isEmpty {
            return String(localized: "Connecting to \(host)", bundle: .module)
        }
        return String(localized: "Connecting", bundle: .module)
    }
}

/// The shared glass card. Also used directly for states the overlay's
/// connection-state switch cannot see, like connected-but-no-frame-yet.
struct ConnectionStatusCard: View {
    let title: String
    var detail: String?
    var actionLabel: String?
    var actionRole: ButtonRole?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionLabel, let action {
                Button(actionLabel, role: actionRole, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .frame(minWidth: 220, maxWidth: 320)
        .glassStatusCard()
        .padding()
        .accessibilityElement(children: .combine)
    }
}

private struct GlassStatusCardModifier: ViewModifier {
    @Environment(\.vncChromeGlassTint) private var glassTint

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *) {
            // A host tint switches to clear glass: the tint restores the
            // contrast floor that regular's frost otherwise provides, and
            // the card takes on the host's theme instead of neutral gray.
            content.glassEffect(
                glassTint.map { Glass.clear.tint($0) } ?? .regular,
                in: RoundedRectangle(cornerRadius: 28))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        }
    }
}

extension View {
    func glassStatusCard() -> some View {
        modifier(GlassStatusCardModifier())
    }
}

/// Optional glass tint a host app injects so the chrome the package still
/// owns (status cards, the HUD menu button) matches the host's theme.
/// `nil` keeps the package's standalone appearance.
private struct VNCChromeGlassTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

public extension EnvironmentValues {
    var vncChromeGlassTint: Color? {
        get { self[VNCChromeGlassTintKey.self] }
        set { self[VNCChromeGlassTintKey.self] = newValue }
    }
}
