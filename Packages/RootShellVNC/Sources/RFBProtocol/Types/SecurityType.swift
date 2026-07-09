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

    /// Preference order for automatic selection (higher = more preferred).
    /// Returns `nil` for types we cannot negotiate — these are skipped during
    /// selection so the client never chooses a type it cannot actually perform.
    public var negotiationPriority: Int? {
        switch self {
        case .none:                return 0
        case .vncAuthentication:   return 1
        case .apple30:             return 2
        case .macAuthentication:   return 3
        // Not yet implemented:
        case .srp:                 return nil
        case .tight:               return nil
        case .vencrypt:            return nil
        case .kerberos:            return nil
        case .unknown:             return nil
        }
    }
}
