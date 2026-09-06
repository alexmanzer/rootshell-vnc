import XCTest
@testable import rootshellVNC

final class RemoteMenuShortcutTests: XCTestCase {
    func testEveryTouchShortcutIsInExactlyOneMenu() {
        let visible = RemoteMenuShortcut.editing + RemoteMenuShortcut.applications
            + RemoteMenuShortcut.documents + RemoteMenuShortcut.keys
        XCTAssertEqual(Set(visible), Set(RemoteMenuShortcut.allCases))
        XCTAssertEqual(visible.count, Set(visible).count)
    }

    func testAppSwitchingAndClipboardChords() {
        XCTAssertEqual(RemoteMenuShortcut.switchApp.character, "\t")
        XCTAssertEqual(RemoteMenuShortcut.switchApp.modifiers, [.command])
        XCTAssertEqual(RemoteMenuShortcut.switchAppBackward.character, "\t")
        XCTAssertEqual(RemoteMenuShortcut.switchAppBackward.modifiers, [.command, .shift])
        XCTAssertEqual(RemoteMenuShortcut.copy.character, "c")
        XCTAssertEqual(RemoteMenuShortcut.paste.character, "v")
        XCTAssertEqual(RemoteMenuShortcut.paste.modifiers, [.command])
        XCTAssertEqual(RemoteMenuShortcut.pasteAndMatchStyle.modifiers, [.command, .shift, .option])
        XCTAssertEqual(RemoteMenuShortcut.fullScreen.modifiers, [.control, .command])
    }

    func testSpecialKeysHaveNoCommandModifier() {
        for shortcut in RemoteMenuShortcut.keys {
            XCTAssertFalse(shortcut.modifiers.contains(.command))
            XCTAssertNotEqual(KeyboardInputHandler.keysymForCharacter(shortcut.character), 0)
        }
        XCTAssertEqual(RemoteMenuShortcut.backTab.modifiers, [.shift])
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(RemoteMenuShortcut.escape.character), 0xFF1B)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(RemoteMenuShortcut.forwardDelete.character), 0xFFFF)
    }
}
