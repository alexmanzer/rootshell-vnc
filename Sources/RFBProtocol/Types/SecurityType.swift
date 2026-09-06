import Foundation

/// RFB security types used during the handshake phase.
public enum SecurityType: Sendable, Equatable, Hashable {
    case none
    case vncAuthentication
    case tight
    case vencrypt
    case apple30
    case macAuthentication
    case srp
    case kerberos
    case unknown(UInt8)

    // MARK: - Raw value mapping

    /// The byte value transmitted on the wire for this security type.
    public var rawValue: UInt8 {
        switch self {
        case .none:                return 1
        case .vncAuthentication:   return 2
        case .tight:               return 16
        case .vencrypt:            return 19
        case .apple30:             return 30
        case .macAuthentication:   return 33
        case .srp:                 return 35
        case .kerberos:            return 36
        case .unknown(let v):      return v
        }
    }

    /// Create a `SecurityType` from its wire byte value.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 1:  self = .none
        case 2:  self = .vncAuthentication
        case 16: self = .tight
        case 19: self = .vencrypt
        case 30: self = .apple30
        case 33: self = .macAuthentication
        case 35: self = .srp
        case 36: self = .kerberos
        default: self = .unknown(rawValue)
        }
    }

    /// Generic preference order for supported types (higher = more preferred).
    /// Returns `nil` for types this client cannot negotiate. The built-in
    /// automatic policy also considers server context and interoperability, so
    /// it does not select solely by this value.
    public var negotiationPriority: Int? {
        switch self {
        case .none:                return 0
        case .vncAuthentication:   return 1
        case .apple30:             return 2
        case .macAuthentication:   return 3
        case .vencrypt:            return 4
        // Not yet implemented:
        case .srp:                 return nil
        case .tight:               return nil
        case .kerberos:            return nil
        case .unknown:             return nil
        }
    }
}

/// User-facing policy for selecting the outer RFB security type.
///
/// `.automatic` is deliberately compatibility-first: Apple authentication is
/// considered only for Apple servers with a username, while conventional
/// servers use VNC Authentication when available and VeNCrypt when it is the
/// server's only supported authenticated option.
public enum VNCSecurityPolicy: String, Sendable, Equatable, Hashable, CaseIterable {
    case automatic
    /// Compatibility negotiation without unauthenticated access or diagnostic overrides.
    case authenticated
    case requireEncryption
    case none
    case vncAuthentication
    case apple30
    case macAuthentication
}
