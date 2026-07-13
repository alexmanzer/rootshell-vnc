import Foundation

/// A local, conflict-resistant shortcut that expands to a familiar command on
/// the remote computer. These defaults mirror Screens 5 so hardware keyboard
/// and touch users share one command vocabulary.
enum RemoteCommand: String, CaseIterable, Identifiable, Sendable {
    case missionControl
    case applicationWindows
    case moveLeftASpace
    case moveRightASpace
    case forceQuit
    case lockScreen
    case logOutUser
    case controlAltDelete
    case backslash
    case insert

    var id: Self { self }

    static let macSpecific: [Self] = [
        .missionControl,
        .applicationWindows,
        .moveLeftASpace,
        .moveRightASpace,
    ]

    static let otherCommands: [Self] = [
        .forceQuit,
        .lockScreen,
        .logOutUser,
        .controlAltDelete,
        .backslash,
        .insert,
    ]

    var title: String {
        switch self {
        case .missionControl: "Mission Control"
        case .applicationWindows: "Application Windows"
        case .moveLeftASpace: "Move Left a Space"
        case .moveRightASpace: "Move Right a Space"
        case .forceQuit: "Force Quit…"
        case .lockScreen: "Lock Screen"
        case .logOutUser: "Log Out User…"
        case .controlAltDelete: "Ctrl-Alt-Delete"
        case .backslash: "Backslash"
        case .insert: "Insert"
        }
    }

    var shortcut: RemoteCommandShortcut {
        switch self {
        case .missionControl:
            RemoteCommandShortcut(input: .upArrow, modifiers: [.control, .option])
        case .applicationWindows:
            RemoteCommandShortcut(input: .downArrow, modifiers: [.control, .option])
        case .moveLeftASpace:
            RemoteCommandShortcut(input: .leftArrow, modifiers: [.control, .option])
        case .moveRightASpace:
            RemoteCommandShortcut(input: .rightArrow, modifiers: [.control, .option])
        case .forceQuit:
            RemoteCommandShortcut(input: .escape, modifiers: [.control, .option])
        case .lockScreen:
            RemoteCommandShortcut(input: .character("q"), modifiers: [.control, .option])
        case .logOutUser:
            RemoteCommandShortcut(input: .character("q"), modifiers: [.option, .shift])
        case .controlAltDelete:
            RemoteCommandShortcut(input: .delete, modifiers: [.control, .option])
        case .backslash:
            RemoteCommandShortcut(input: .character("7"), modifiers: [.control, .shift])
        case .insert:
            RemoteCommandShortcut(input: .character("8"), modifiers: [.control, .shift])
        }
    }

    var remoteChord: RemoteKeyChord {
        switch self {
        case .missionControl:
            RemoteKeyChord(modifiers: [KeyboardInputHandler.keysymControlL], key: KeyboardInputHandler.keysymUp)
        case .applicationWindows:
            RemoteKeyChord(modifiers: [KeyboardInputHandler.keysymControlL], key: KeyboardInputHandler.keysymDown)
        case .moveLeftASpace:
            RemoteKeyChord(modifiers: [KeyboardInputHandler.keysymControlL], key: KeyboardInputHandler.keysymLeft)
        case .moveRightASpace:
            RemoteKeyChord(modifiers: [KeyboardInputHandler.keysymControlL], key: KeyboardInputHandler.keysymRight)
        case .forceQuit:
            RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymSuperL, KeyboardInputHandler.keysymAltL],
                key: KeyboardInputHandler.keysymEscape)
        case .lockScreen:
            RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymControlL, KeyboardInputHandler.keysymSuperL],
                key: KeyboardInputHandler.keysymForCharacter("q"))
        case .logOutUser:
            RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymShiftL, KeyboardInputHandler.keysymSuperL],
                key: KeyboardInputHandler.keysymForCharacter("q"))
        case .controlAltDelete:
            RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymControlL, KeyboardInputHandler.keysymAltL],
                key: KeyboardInputHandler.keysymDelete)
        case .backslash:
            RemoteKeyChord(modifiers: [], key: KeyboardInputHandler.keysymForCharacter("\\"))
        case .insert:
            RemoteKeyChord(modifiers: [], key: KeyboardInputHandler.keysymInsert)
        }
    }
}

struct RemoteCommandModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
}

enum RemoteCommandInput: Equatable, Sendable {
    case character(Character)
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case escape
    case delete
}

struct RemoteCommandShortcut: Equatable, Sendable {
    let input: RemoteCommandInput
    let modifiers: RemoteCommandModifiers
}

struct RemoteKeyChord: Equatable, Sendable {
    let modifiers: [UInt32]
    let key: UInt32
}
