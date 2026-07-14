import Foundation

/// RFB encoding types used in SetEncodings and FramebufferUpdate messages.
///
/// Standard encodings have non-negative values. Pseudo-encodings (used to
/// signal capabilities rather than pixel data) have negative values.
public enum Encoding: Sendable, Equatable, Hashable {

    // MARK: - Standard encodings

    case raw
    case copyRect
    case rre
    case hextile
    case zlib
    case tight
    case zlibhex
    case zrle

    // MARK: - Standard pseudo-encodings

    case cursor
    case lastRect
    case desktopSize
    case extendedDesktopSize

    // MARK: - Apple encodings

    case appleJPEG
    case apple1
    case appleMultiVariantScreenshare
    case appleSubZlibThousands
    case appleH264

    // MARK: - Apple pseudo-encodings

    case encryptionInfo
    case serverDisplayInfo
    case mediaStreamOffer
    case mediaStreamAnswer

    // MARK: - Fallback

    case unknown(Int32)

    // MARK: - Raw value mapping

    /// The 32-bit signed integer transmitted on the wire for this encoding.
    public var rawValue: Int32 {
        switch self {
        case .raw:                  return 0
        case .copyRect:             return 1
        case .rre:                  return 2
        case .hextile:              return 5
        case .zlib:                 return 6
        case .tight:                return 7
        case .zlibhex:              return 8
        case .zrle:                 return 16
        case .cursor:               return -239
        case .lastRect:             return -224
        case .desktopSize:          return -223
        case .extendedDesktopSize:  return -308
        case .appleJPEG:            return -1000
        case .apple1:               return -261
        case .appleMultiVariantScreenshare: return 1011
        case .appleSubZlibThousands: return 1002
        case .appleH264:            return 1010
        case .encryptionInfo:       return -267
        case .serverDisplayInfo:    return -300
        case .mediaStreamOffer:     return 1103
        case .mediaStreamAnswer:    return -302
        case .unknown(let v):       return v
        }
    }

    /// Create an `Encoding` from its wire value.
    public init(rawValue: Int32) {
        switch rawValue {
        case 0:     self = .raw
        case 1:     self = .copyRect
        case 2:     self = .rre
        case 5:     self = .hextile
        case 6:     self = .zlib
        case 7:     self = .tight
        case 8:     self = .zlibhex
        case 16:    self = .zrle
        case -239:  self = .cursor
        case -224:  self = .lastRect
        case -223:  self = .desktopSize
        case -308:  self = .extendedDesktopSize
        case -1000: self = .appleJPEG
        case -261:  self = .apple1
        case 1002:  self = .appleSubZlibThousands
        case 1010:  self = .appleH264
        case 1011:  self = .appleMultiVariantScreenshare
        case 1103:  self = .mediaStreamOffer
        case -267:  self = .encryptionInfo
        case -300:  self = .serverDisplayInfo
        case -301:  self = .mediaStreamOffer
        case -302:  self = .mediaStreamAnswer
        default:    self = .unknown(rawValue)
        }
    }

    /// Whether this encoding is a pseudo-encoding (negative value).
    public var isPseudo: Bool {
        rawValue < 0 || self == .mediaStreamOffer
    }
}
