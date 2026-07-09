import SwiftUI
import RFBProtocol

/// Translates keyboard events into VNC key events using X11 keysym values.
///
/// The VNC protocol uses X11 keysym values to represent keys. This handler
/// maps SwiftUI `KeyEquivalent` values and Unicode characters to the
/// corresponding keysym codes.
///
/// Common keysym ranges:
/// - 0x0020...0x007E: ASCII printable characters (keysym == Unicode code point)
/// - 0x00A0...0x00FF: Latin-1 supplement (keysym == Unicode code point)
/// - 0xFF00...0xFFFF: Special keys (function keys, modifiers, navigation)
@MainActor
public struct KeyboardInputHandler {

    // MARK: - Types

    /// A closure that sends a key event to the VNC server.
    ///
    /// - Parameters:
    ///   - downFlag: `true` for key press, `false` for key release.
    ///   - keysym: The X11 keysym value for the key.
    public typealias KeyEventHandler = @MainActor (Bool, UInt32) -> Void

    // MARK: - X11 Keysym Constants

    // Special keys
    public nonisolated static let keysymBackspace:  UInt32 = 0xFF08
    public nonisolated static let keysymTab:        UInt32 = 0xFF09
    public nonisolated static let keysymReturn:     UInt32 = 0xFF0D
    public nonisolated static let keysymEscape:     UInt32 = 0xFF1B
    public nonisolated static let keysymDelete:     UInt32 = 0xFFFF

    // Navigation keys
    public nonisolated static let keysymHome:       UInt32 = 0xFF50
    public nonisolated static let keysymLeft:       UInt32 = 0xFF51
    public nonisolated static let keysymUp:         UInt32 = 0xFF52
    public nonisolated static let keysymRight:      UInt32 = 0xFF53
    public nonisolated static let keysymDown:       UInt32 = 0xFF54
    public nonisolated static let keysymPageUp:     UInt32 = 0xFF55
    public nonisolated static let keysymPageDown:   UInt32 = 0xFF56
    public nonisolated static let keysymEnd:        UInt32 = 0xFF57
    public nonisolated static let keysymInsert:     UInt32 = 0xFF63

    // Function keys
    public nonisolated static let keysymF1:         UInt32 = 0xFFBE
    public nonisolated static let keysymF2:         UInt32 = 0xFFBF
    public nonisolated static let keysymF3:         UInt32 = 0xFFC0
    public nonisolated static let keysymF4:         UInt32 = 0xFFC1
    public nonisolated static let keysymF5:         UInt32 = 0xFFC2
    public nonisolated static let keysymF6:         UInt32 = 0xFFC3
    public nonisolated static let keysymF7:         UInt32 = 0xFFC4
    public nonisolated static let keysymF8:         UInt32 = 0xFFC5
    public nonisolated static let keysymF9:         UInt32 = 0xFFC6
    public nonisolated static let keysymF10:        UInt32 = 0xFFC7
    public nonisolated static let keysymF11:        UInt32 = 0xFFC8
    public nonisolated static let keysymF12:        UInt32 = 0xFFC9

    // Modifier keys
    public nonisolated static let keysymShiftL:     UInt32 = 0xFFE1
    public nonisolated static let keysymShiftR:     UInt32 = 0xFFE2
    public nonisolated static let keysymControlL:   UInt32 = 0xFFE3
    public nonisolated static let keysymControlR:   UInt32 = 0xFFE4
    public nonisolated static let keysymCapsLock:   UInt32 = 0xFFE5
    public nonisolated static let keysymMetaL:      UInt32 = 0xFFE7   // Command/Super
    public nonisolated static let keysymMetaR:      UInt32 = 0xFFE8
    public nonisolated static let keysymAltL:       UInt32 = 0xFFE9   // Option/Alt
    public nonisolated static let keysymAltR:       UInt32 = 0xFFEA

    // MARK: - Properties

    private let sendKeyEvent: KeyEventHandler

    // MARK: - Init

    /// Create a keyboard input handler that delegates key events to the given closure.
    ///
    /// - Parameter sendKeyEvent: A closure called with (downFlag, keysym)
    ///   for each generated key event.
    public init(sendKeyEvent: @escaping KeyEventHandler) {
        self.sendKeyEvent = sendKeyEvent
    }

    // MARK: - Key Event Handlers

    /// Handle a key press event.
    ///
    /// Converts the SwiftUI key equivalent to an X11 keysym and sends
    /// a key-down event to the server.
    ///
    /// - Parameter key: The SwiftUI key equivalent that was pressed.
    public func handleKeyPress(_ key: KeyEquivalent) {
        let keysym = Self.keysymForKeyEquivalent(key)
        sendKeyEvent(true, keysym)
    }

    /// Handle a key release event.
    ///
    /// Converts the SwiftUI key equivalent to an X11 keysym and sends
    /// a key-up event to the server.
    ///
    /// - Parameter key: The SwiftUI key equivalent that was released.
    public func handleKeyRelease(_ key: KeyEquivalent) {
        let keysym = Self.keysymForKeyEquivalent(key)
        sendKeyEvent(false, keysym)
    }

    /// Handle a complete key tap (press + release) for a character.
    ///
    /// - Parameter character: The character that was typed.
    public func handleKeyTap(_ character: Character) {
        let keysym = Self.keysymForCharacter(character)
        sendKeyEvent(true, keysym)
        sendKeyEvent(false, keysym)
    }

    // MARK: - Keysym Conversion

    /// Convert a SwiftUI `KeyEquivalent` to an X11 keysym value.
    ///
    /// - Parameter key: The key equivalent to convert.
    /// - Returns: The corresponding X11 keysym value.
    public nonisolated static func keysymForKeyEquivalent(_ key: KeyEquivalent) -> UInt32 {
        switch key {
        case .return:               return keysymReturn
        case .tab:                  return keysymTab
        case .delete:               return keysymBackspace
        case .deleteForward:        return keysymDelete
        case .escape:               return keysymEscape
        case .upArrow:              return keysymUp
        case .downArrow:            return keysymDown
        case .leftArrow:            return keysymLeft
        case .rightArrow:           return keysymRight
        case .home:                 return keysymHome
        case .end:                  return keysymEnd
        case .pageUp:               return keysymPageUp
        case .pageDown:             return keysymPageDown
        default:
            return keysymForCharacter(key.character)
        }
    }

    /// Convert a `Character` to an X11 keysym value.
    ///
    /// For ASCII printable characters (0x20...0x7E), the keysym equals
    /// the Unicode code point. For Latin-1 supplement characters
    /// (0x00A0...0x00FF), the keysym also equals the code point.
    /// For other characters, the keysym is derived from the Unicode
    /// code point with the 0x01000000 offset per the X11 specification.
    ///
    /// - Parameter char: The character to convert.
    /// - Returns: The corresponding X11 keysym value.
    public nonisolated static func keysymForCharacter(_ char: Character) -> UInt32 {
        guard let scalar = char.unicodeScalars.first else {
            return 0
        }

        let codePoint = scalar.value

        // ASCII printable range: keysym == code point
        if codePoint >= 0x0020 && codePoint <= 0x007E {
            return codePoint
        }

        // Latin-1 supplement: keysym == code point
        if codePoint >= 0x00A0 && codePoint <= 0x00FF {
            return codePoint
        }

        // Special cases for control characters
        switch codePoint {
        case 0x08: return keysymBackspace
        case 0x09: return keysymTab
        case 0x0D, 0x0A: return keysymReturn
        case 0x1B: return keysymEscape
        case 0x7F: return keysymDelete
        default: break
        }

        // Unicode keysym: add 0x01000000 to the code point
        // This is the standard X11 convention for Unicode keysyms
        if codePoint > 0x00FF {
            return 0x01000000 | codePoint
        }

        return codePoint
    }

    /// Convert a function key number (1-12) to its X11 keysym.
    ///
    /// - Parameter number: The function key number (1-12).
    /// - Returns: The corresponding keysym, or 0 if the number is out of range.
    public nonisolated static func keysymForFunctionKey(_ number: Int) -> UInt32 {
        guard number >= 1 && number <= 12 else { return 0 }
        return keysymF1 + UInt32(number - 1)
    }
}
