import Foundation

#if os(iOS)
import CoreTelephony

/// Keep CoreTelephony's XPC client alive for the process lifetime. Constructing
/// a short-lived instance can invalidate its selector-update connection just
/// after the synchronous RAT lookup completes.
private final class AppleMediaRadioInfo: @unchecked Sendable {
    let networkInfo = CTTelephonyNetworkInfo()
}
#endif

/// Public-API-derived capacity prior for Apple media rate control.
/// Interface/radio type selects a safe starting point; it never changes the
/// logical Screen Sharing transport negotiation and never becomes a permanent
/// ceiling because measured delivery conditions remain authoritative.
struct AppleMediaNetworkProfile: Sendable, Equatable {
    #if os(iOS)
    private static let radioInfo = AppleMediaRadioInfo()
    #endif

    enum RadioClass: String, Sendable {
        case none
        case legacy
        case lte
        case fiveG
        case unknownCellular
    }

    let name: String
    let radioClass: RadioClass
    let initialCapacityBps: Double

    static let wifi = AppleMediaNetworkProfile(
        name: "Wi-Fi",
        radioClass: .none,
        initialCapacityBps: 20_000_000)

    static let unknown = AppleMediaNetworkProfile(
        name: "unknown",
        radioClass: .none,
        initialCapacityBps: 12_000_000)

    static func detect(
        from path: NetworkPathCharacteristics?,
        remoteHost: String
    ) -> AppleMediaNetworkProfile {
        guard let path else { return .unknown }

        if path.interface == .cellular
            || (path.interface == .other && path.isExpensive) {
            let radio = currentRadioClass()
            let ordinaryInitial: Double
            switch radio {
            case .fiveG:
                ordinaryInitial = 12_000_000
            case .lte:
                ordinaryInitial = 8_000_000
            case .legacy:
                ordinaryInitial = 4_000_000
            case .unknownCellular, .none:
                ordinaryInitial = 8_000_000
            }
            // A VPN/private-overlay route still uses cellular capacity, but the
            // RFB screen peer is a logical local-network endpoint. Native
            // The screen rule collection explicitly negotiates
            // the local/Wi-Fi transport in this mode; cellular-only rules yield
            // a successful control answer with no compatible video source.
            let privateOverlay = path.usesOtherInterface
                || isPrivateOrOverlayHost(remoteHost)
            let label = radio == .none ? "cellular" : radio.rawValue
            return AppleMediaNetworkProfile(
                name: privateOverlay ? "\(label) over private/VPN" : label,
                radioClass: radio == .none ? .unknownCellular : radio,
                // A tunnel's achievable UDP rate is independent of the radio
                // label and can be far below or above it. Start conservatively
                // enough to deliver the first reference picture, then let the
                // fast utilization-gated probe discover excellent 5G paths.
                initialCapacityBps: path.isConstrained
                    ? 4_000_000
                    : (privateOverlay ? 6_000_000 : ordinaryInitial))
        }

        switch path.interface {
        case .wiredEthernet, .loopback:
            return AppleMediaNetworkProfile(
                name: path.interface == .loopback ? "loopback" : "wired Ethernet",
                radioClass: .none,
                // Native Screen Sharing starts an unconstrained local receiver
                // at the negotiated 60 Mbps ceiling. Beginning at 40 Mbps made
                // the server quantize a Retina desktop before our estimator had
                // enough sustained motion to ramp.
                initialCapacityBps: path.isConstrained ? 10_000_000 : 60_000_000)
        case .wifi:
            return AppleMediaNetworkProfile(
                name: "Wi-Fi",
                radioClass: .none,
                initialCapacityBps: path.isConstrained ? 6_000_000 : 20_000_000)
        case .other:
            return AppleMediaNetworkProfile(
                name: path.isConstrained ? "constrained other" : "other/VPN",
                radioClass: .none,
                initialCapacityBps: path.isConstrained ? 4_000_000 : 12_000_000)
        case .cellular:
            // Handled above, including expensive VPN paths.
            return .unknown
        }
    }

    static func isPrivateOrOverlayHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local")
            || isTailscaleDNSHost(lower) || lower.hasPrefix("fc")
            || lower.hasPrefix("fd") {
            return true
        }
        let octets = lower.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (169, 254), (192, 168):
            return true
        case (172, 16...31), (100, 64...127):
            return true
        default:
            return false
        }
    }

    static func isTailscaleDNSHost(_ host: String) -> Bool {
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized.hasSuffix(".ts.net")
    }

    private static func currentRadioClass() -> RadioClass {
        #if os(iOS)
        let technologies = radioInfo.networkInfo
            .serviceCurrentRadioAccessTechnology
            .map { Array($0.values) } ?? []
        if technologies.contains(CTRadioAccessTechnologyNR)
            || technologies.contains(CTRadioAccessTechnologyNRNSA) {
            return .fiveG
        }
        if technologies.contains(CTRadioAccessTechnologyLTE) {
            return .lte
        }
        if !technologies.isEmpty {
            return .legacy
        }
        return .unknownCellular
        #else
        return .unknownCellular
        #endif
    }
}
