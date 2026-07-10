import XCTest
import Foundation
import CoreVideo
@testable import RootShellVNC
import RFBProtocol

// MARK: - VNCCredentials Tests

final class VNCCredentialsTests: XCTestCase {

    func testInitWithDefaultPort() {
        let creds = VNCCredentials(host: "192.168.1.1", password: "secret")
        XCTAssertEqual(creds.host, "192.168.1.1")
        XCTAssertEqual(creds.port, 5900)
        XCTAssertEqual(creds.password, "secret")
        XCTAssertNil(creds.username)
    }

    func testInitWithCustomPort() {
        let creds = VNCCredentials(host: "myserver.local", port: 5901, password: "pass")
        XCTAssertEqual(creds.host, "myserver.local")
        XCTAssertEqual(creds.port, 5901)
        XCTAssertEqual(creds.password, "pass")
        XCTAssertNil(creds.username)
    }

    func testInitWithUsername() {
        let creds = VNCCredentials(host: "10.0.0.1", port: 5900, password: "pass123", username: "admin")
        XCTAssertEqual(creds.host, "10.0.0.1")
        XCTAssertEqual(creds.port, 5900)
        XCTAssertEqual(creds.password, "pass123")
        XCTAssertEqual(creds.username, "admin")
    }

    func testInitWithAllCustomValues() {
        let creds = VNCCredentials(host: "vnc.example.com", port: 9999, password: "p@ssw0rd!", username: "user1")
        XCTAssertEqual(creds.host, "vnc.example.com")
        XCTAssertEqual(creds.port, 9999)
        XCTAssertEqual(creds.password, "p@ssw0rd!")
        XCTAssertEqual(creds.username, "user1")
    }

    func testEmptyHostAndPassword() {
        let creds = VNCCredentials(host: "", password: "")
        XCTAssertEqual(creds.host, "")
        XCTAssertEqual(creds.password, "")
    }
}

// MARK: - VNCConfiguration Tests

final class VNCConfigurationTests: XCTestCase {

    func testDefaultValues() {
        let config = VNCConfiguration()
        XCTAssertNil(config.preferredPixelFormat)
        XCTAssertEqual(config.preferredEncodings, [.copyRect, .raw])
        XCTAssertTrue(config.enableHighPerformanceMode)
        XCTAssertEqual(config.videoQualityMode, .adaptive)
        XCTAssertEqual(config.displaySizingMode, .matchClient)
        XCTAssertEqual(config.targetFrameRate, 30)
        XCTAssertFalse(config.enableProtocolTrace)
    }

    func testCustomValues() {
        let config = VNCConfiguration(
            preferredPixelFormat: .bgra8888,
            preferredEncodings: [.raw, .zrle],
            enableHighPerformanceMode: false,
            displaySizingMode: .remoteDisplay,
            targetFrameRate: 60,
            enableProtocolTrace: true
        )
        XCTAssertEqual(config.preferredPixelFormat, .bgra8888)
        XCTAssertEqual(config.preferredEncodings, [.raw, .zrle])
        XCTAssertFalse(config.enableHighPerformanceMode)
        XCTAssertEqual(config.displaySizingMode, .remoteDisplay)
        XCTAssertEqual(config.targetFrameRate, 60)
        XCTAssertTrue(config.enableProtocolTrace)
    }

    func testTargetFrameRateClamping() {
        // Below minimum
        let low = VNCConfiguration(targetFrameRate: 0)
        XCTAssertEqual(low.targetFrameRate, 1)

        let negative = VNCConfiguration(targetFrameRate: -10)
        XCTAssertEqual(negative.targetFrameRate, 1)

        // Above maximum
        let high = VNCConfiguration(targetFrameRate: 200)
        XCTAssertEqual(high.targetFrameRate, 120)

        // Within range
        let normal = VNCConfiguration(targetFrameRate: 60)
        XCTAssertEqual(normal.targetFrameRate, 60)

        // At boundaries
        let atMin = VNCConfiguration(targetFrameRate: 1)
        XCTAssertEqual(atMin.targetFrameRate, 1)
        let atMax = VNCConfiguration(targetFrameRate: 120)
        XCTAssertEqual(atMax.targetFrameRate, 120)
    }

    func testEffectiveEncodingsIncludesHighPerformance() {
        let config = VNCConfiguration(
            preferredEncodings: [.zrle, .raw],
            enableHighPerformanceMode: true
        )
        let effective = config.effectiveEncodings
        XCTAssertTrue(effective.contains(.appleH264))
        XCTAssertTrue(effective.contains(.appleMultiVariantScreenshare))
        XCTAssertTrue(effective.contains(.appleSubZlibThousands))
        XCTAssertTrue(effective.contains(.mediaStreamOffer))
        XCTAssertTrue(effective.contains(.mediaStreamAnswer))
        XCTAssertTrue(effective.contains(.encryptionInfo))
        XCTAssertTrue(effective.contains(.serverDisplayInfo))
        XCTAssertTrue(effective.contains(.desktopSize))
        XCTAssertTrue(effective.contains(.extendedDesktopSize))
        XCTAssertTrue(effective.contains(.cursor))
        XCTAssertTrue(effective.contains(.raw))
    }

    func testEffectiveEncodingsWithoutHighPerformance() {
        let config = VNCConfiguration(
            preferredEncodings: [.zrle, .raw],
            enableHighPerformanceMode: false
        )
        let effective = config.effectiveEncodings
        XCTAssertFalse(effective.contains(.appleH264))
        XCTAssertFalse(effective.contains(.appleMultiVariantScreenshare))
        XCTAssertFalse(effective.contains(.appleSubZlibThousands))
        XCTAssertFalse(effective.contains(.mediaStreamOffer))
        XCTAssertFalse(effective.contains(.mediaStreamAnswer))
        XCTAssertTrue(effective.contains(.desktopSize))
        XCTAssertTrue(effective.contains(.extendedDesktopSize))
        XCTAssertTrue(effective.contains(.cursor))
        XCTAssertTrue(effective.contains(.raw))
    }

    func testFullQualityUsesNativeLosslessEncodingProfile() {
        let config = VNCConfiguration(videoQualityMode: .fullQuality)
        let effective = config.effectiveEncodings
        XCTAssertFalse(effective.contains(.appleH264))
        XCTAssertFalse(effective.contains(.appleMultiVariantScreenshare))
        XCTAssertFalse(effective.contains(.mediaStreamOffer))
        XCTAssertTrue(effective.contains(.zlib))
        XCTAssertTrue(effective.contains(.zrle))
    }

    func testQualityModesExposeGUILabels() {
        XCTAssertEqual(
            VNCConfiguration.VideoQualityMode.allCases,
            [.adaptive, .fullQuality])
        XCTAssertEqual(VNCConfiguration.VideoQualityMode.adaptive.title, "Adaptive")
        XCTAssertEqual(VNCConfiguration.VideoQualityMode.fullQuality.title, "Full Quality")
    }

    func testEffectiveEncodingsAlwaysIncludesRaw() {
        let config = VNCConfiguration(preferredEncodings: [.zrle, .tight])
        let effective = config.effectiveEncodings
        XCTAssertTrue(effective.contains(.raw))
    }

    func testEffectiveEncodingsDoesNotDuplicateRaw() {
        let config = VNCConfiguration(preferredEncodings: [.raw, .zrle])
        let effective = config.effectiveEncodings
        let rawCount = effective.filter { $0 == .raw }.count
        XCTAssertEqual(rawCount, 1)
    }

    func testEffectiveEncodingsDoesNotDuplicateDesktopSize() {
        let config = VNCConfiguration(
            preferredEncodings: [.desktopSize, .extendedDesktopSize, .raw])
        let effective = config.effectiveEncodings
        XCTAssertEqual(effective.filter { $0 == .desktopSize }.count, 1)
        XCTAssertEqual(effective.filter { $0 == .extendedDesktopSize }.count, 1)
    }

    func testDisplaySizingModesExposeGUIChoices() {
        XCTAssertEqual(
            VNCConfiguration.DisplaySizingMode.allCases,
            [.remoteDisplay, .matchClient])
        XCTAssertEqual(
            VNCConfiguration.DisplaySizingMode.matchClient.title,
            "Match Client")
    }
}

// MARK: - Remote Display Size Tests

final class RemoteDisplaySizeTests: XCTestCase {

    func testIPadViewportProducesTwoTimesHiDPIFramebuffer() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 1366, height: 1024),
                displayScale: 2),
            RemoteDisplaySize(
                pixelWidth: 2732,
                pixelHeight: 2048,
                pointWidth: 1366,
                pointHeight: 1024))
    }

    func testScaleIsCappedAtTwoTimes() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 1000, height: 700),
                displayScale: 3),
            RemoteDisplaySize(
                pixelWidth: 2000,
                pixelHeight: 1400,
                pointWidth: 1000,
                pointHeight: 700))
    }

    func testLandscapeViewportFitsExactFourKServerLimit() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 1920, height: 1080),
                displayScale: 2),
            RemoteDisplaySize(
                pixelWidth: 3840,
                pixelHeight: 2160,
                pointWidth: 1920,
                pointHeight: 1080))
    }

    func testPortraitViewportPreservesAspectInsideServerLimit() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 1024, height: 1366),
                displayScale: 2),
            RemoteDisplaySize(
                pixelWidth: 1618,
                pixelHeight: 2160,
                pointWidth: 809,
                pointHeight: 1080))
    }

    func testInvalidViewportIsIgnored() {
        XCTAssertNil(RemoteDisplaySize.matching(
            viewSize: CGSize(width: 0, height: 1024),
            displayScale: 2))
        XCTAssertNil(RemoteDisplaySize.matching(
            viewSize: CGSize(width: 1024, height: CGFloat.infinity),
            displayScale: 2))
    }
}

// MARK: - KeyboardInputHandler Tests

final class KeyboardInputHandlerTests: XCTestCase {

    // MARK: - Keysym constants

    func testKeysymConstants() {
        XCTAssertEqual(KeyboardInputHandler.keysymBackspace, 0xFF08)
        XCTAssertEqual(KeyboardInputHandler.keysymTab, 0xFF09)
        XCTAssertEqual(KeyboardInputHandler.keysymReturn, 0xFF0D)
        XCTAssertEqual(KeyboardInputHandler.keysymEscape, 0xFF1B)
        XCTAssertEqual(KeyboardInputHandler.keysymDelete, 0xFFFF)
        XCTAssertEqual(KeyboardInputHandler.keysymLeft, 0xFF51)
        XCTAssertEqual(KeyboardInputHandler.keysymUp, 0xFF52)
        XCTAssertEqual(KeyboardInputHandler.keysymRight, 0xFF53)
        XCTAssertEqual(KeyboardInputHandler.keysymDown, 0xFF54)
        XCTAssertEqual(KeyboardInputHandler.keysymHome, 0xFF50)
        XCTAssertEqual(KeyboardInputHandler.keysymEnd, 0xFF57)
        XCTAssertEqual(KeyboardInputHandler.keysymPageUp, 0xFF55)
        XCTAssertEqual(KeyboardInputHandler.keysymPageDown, 0xFF56)
        XCTAssertEqual(KeyboardInputHandler.keysymInsert, 0xFF63)
    }

    func testHardwareKeyboardHIDMapping() {
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x28, characters: "\r"),
            KeyboardInputHandler.keysymReturn)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x50, characters: ""),
            KeyboardInputHandler.keysymLeft)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x3A, characters: ""),
            KeyboardInputHandler.keysymF1)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0xE3, characters: ""),
            KeyboardInputHandler.keysymSuperL)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x04, characters: "A"),
            0x41)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x1E, characters: "!"),
            0x21)
    }

    func testFunctionKeyConstants() {
        XCTAssertEqual(KeyboardInputHandler.keysymF1, 0xFFBE)
        XCTAssertEqual(KeyboardInputHandler.keysymF2, 0xFFBF)
        XCTAssertEqual(KeyboardInputHandler.keysymF3, 0xFFC0)
        XCTAssertEqual(KeyboardInputHandler.keysymF4, 0xFFC1)
        XCTAssertEqual(KeyboardInputHandler.keysymF5, 0xFFC2)
        XCTAssertEqual(KeyboardInputHandler.keysymF6, 0xFFC3)
        XCTAssertEqual(KeyboardInputHandler.keysymF7, 0xFFC4)
        XCTAssertEqual(KeyboardInputHandler.keysymF8, 0xFFC5)
        XCTAssertEqual(KeyboardInputHandler.keysymF9, 0xFFC6)
        XCTAssertEqual(KeyboardInputHandler.keysymF10, 0xFFC7)
        XCTAssertEqual(KeyboardInputHandler.keysymF11, 0xFFC8)
        XCTAssertEqual(KeyboardInputHandler.keysymF12, 0xFFC9)
    }

    func testModifierKeyConstants() {
        XCTAssertEqual(KeyboardInputHandler.keysymShiftL, 0xFFE1)
        XCTAssertEqual(KeyboardInputHandler.keysymShiftR, 0xFFE2)
        XCTAssertEqual(KeyboardInputHandler.keysymControlL, 0xFFE3)
        XCTAssertEqual(KeyboardInputHandler.keysymControlR, 0xFFE4)
        XCTAssertEqual(KeyboardInputHandler.keysymCapsLock, 0xFFE5)
        XCTAssertEqual(KeyboardInputHandler.keysymMetaL, 0xFFE7)
        XCTAssertEqual(KeyboardInputHandler.keysymMetaR, 0xFFE8)
        XCTAssertEqual(KeyboardInputHandler.keysymAltL, 0xFFE9)
        XCTAssertEqual(KeyboardInputHandler.keysymAltR, 0xFFEA)
    }

    // MARK: - Character to keysym mapping

    func testKeysymForASCIICharacters() {
        // ASCII printable: keysym == code point
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("a"), 0x61)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("A"), 0x41)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("z"), 0x7A)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("Z"), 0x5A)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("0"), 0x30)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("9"), 0x39)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(" "), 0x20)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("!"), 0x21)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("~"), 0x7E)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("@"), 0x40)
    }

    func testKeysymForLatin1Supplement() {
        // Latin-1 supplement: keysym == code point
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{00A9}"), 0x00A9) // copyright
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{00E9}"), 0x00E9) // e-acute
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{00FF}"), 0x00FF) // y-diaeresis
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{00A0}"), 0x00A0) // non-breaking space
    }

    func testKeysymForUnicodeCharacters() {
        // Unicode characters above 0xFF use the 0x01000000 prefix
        let euro = Character("\u{20AC}") // Euro sign
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(euro), 0x01000000 | 0x20AC)

        let snowman = Character("\u{2603}") // snowman
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(snowman), 0x01000000 | 0x2603)

        let smiley = Character("\u{1F600}") // grinning face
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(smiley), 0x01000000 | 0x1F600)
    }

    func testKeysymForControlCharacters() {
        // Backspace (0x08) -> keysymBackspace
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{08}"), KeyboardInputHandler.keysymBackspace)
        // Tab (0x09) -> keysymTab
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{09}"), KeyboardInputHandler.keysymTab)
        // Carriage return (0x0D) -> keysymReturn
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\r"), KeyboardInputHandler.keysymReturn)
        // Newline (0x0A) -> keysymReturn
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\n"), KeyboardInputHandler.keysymReturn)
        // Escape (0x1B) -> keysymEscape
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{1B}"), KeyboardInputHandler.keysymEscape)
        // DEL (0x7F) -> keysymDelete
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{7F}"), KeyboardInputHandler.keysymDelete)
    }

    // MARK: - Function key helper

    func testKeysymForFunctionKey() {
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(1), KeyboardInputHandler.keysymF1)
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(12), KeyboardInputHandler.keysymF12)
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(6), KeyboardInputHandler.keysymF6)
    }

    func testKeysymForFunctionKeyOutOfRange() {
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(0), 0)
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(13), 0)
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(-1), 0)
    }

    func testFunctionKeysAreConsecutive() {
        // F1 through F12 should be consecutive keysym values
        for i in 1...12 {
            let expected = KeyboardInputHandler.keysymF1 + UInt32(i - 1)
            XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(i), expected)
        }
    }
}

// MARK: - ProtocolTrace Tests

final class ProtocolTraceTests: XCTestCase {

    func testRecordSentEntry() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "KeyEvent", data: Data([0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x61]))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].direction, .sent)
        XCTAssertEqual(entries[0].messageType, "KeyEvent")
        XCTAssertEqual(entries[0].byteCount, 8)
    }

    func testRecordReceivedEntry() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordReceived(type: "FramebufferUpdate", data: Data(repeating: 0, count: 1024))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].direction, .received)
        XCTAssertEqual(entries[0].messageType, "FramebufferUpdate")
        XCTAssertEqual(entries[0].byteCount, 1024)
    }

    func testRecordMultipleEntries() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "KeyEvent", data: Data([0x01]))
        trace.recordReceived(type: "Bell", data: Data([0x02]))
        trace.recordSent(type: "PointerEvent", data: Data([0x03]))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].messageType, "KeyEvent")
        XCTAssertEqual(entries[1].messageType, "Bell")
        XCTAssertEqual(entries[2].messageType, "PointerEvent")
    }

    func testRecordWithDetails() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "SetEncodings", data: Data(repeating: 0, count: 12), details: "3 encodings")

        let entries = trace.getEntries()
        XCTAssertEqual(entries[0].details, "3 encodings")
    }

    func testMaxEntriesEviction() {
        let trace = ProtocolTrace(maxEntries: 3)
        trace.recordSent(type: "Msg1", data: Data([0x01]))
        trace.recordSent(type: "Msg2", data: Data([0x02]))
        trace.recordSent(type: "Msg3", data: Data([0x03]))
        trace.recordSent(type: "Msg4", data: Data([0x04]))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 3)
        // Oldest entry (Msg1) should be evicted
        XCTAssertEqual(entries[0].messageType, "Msg2")
        XCTAssertEqual(entries[1].messageType, "Msg3")
        XCTAssertEqual(entries[2].messageType, "Msg4")
    }

    func testCount() {
        let trace = ProtocolTrace(maxEntries: 100)
        XCTAssertEqual(trace.count, 0)
        trace.recordSent(type: "A", data: Data([0]))
        XCTAssertEqual(trace.count, 1)
        trace.recordReceived(type: "B", data: Data([0]))
        XCTAssertEqual(trace.count, 2)
    }

    func testClear() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "A", data: Data([0]))
        trace.recordReceived(type: "B", data: Data([0]))
        XCTAssertEqual(trace.count, 2)

        trace.clear()
        XCTAssertEqual(trace.count, 0)
        XCTAssertTrue(trace.getEntries().isEmpty)
    }

    func testExportJSON() throws {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "KeyEvent", data: Data([0x04, 0x01]))
        trace.recordReceived(type: "Bell", data: Data([0x02]))

        let jsonData = try trace.exportJSON()
        XCTAssertFalse(jsonData.isEmpty)

        // Verify it's valid JSON
        let decoded = try JSONSerialization.jsonObject(with: jsonData)
        guard let array = decoded as? [[String: Any]] else {
            XCTFail("Expected JSON array")
            return
        }
        XCTAssertEqual(array.count, 2)

        // Verify fields exist
        let first = array[0]
        XCTAssertNotNil(first["timestamp"])
        XCTAssertNotNil(first["direction"])
        XCTAssertNotNil(first["messageType"])
        XCTAssertNotNil(first["byteCount"])
    }

    func testExportJSONEmpty() throws {
        let trace = ProtocolTrace(maxEntries: 100)
        let jsonData = try trace.exportJSON()
        let decoded = try JSONSerialization.jsonObject(with: jsonData)
        guard let array = decoded as? [Any] else {
            XCTFail("Expected JSON array")
            return
        }
        XCTAssertTrue(array.isEmpty)
    }

    func testTimestampsAreChronological() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "First", data: Data([0]))
        // Small delay to ensure different timestamps
        trace.recordSent(type: "Second", data: Data([0]))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertLessThanOrEqual(entries[0].timestamp, entries[1].timestamp)
    }

    func testDirectionEnum() {
        XCTAssertEqual(ProtocolTrace.TraceEntry.Direction.sent.rawValue, "sent")
        XCTAssertEqual(ProtocolTrace.TraceEntry.Direction.received.rawValue, "received")
    }
}

// MARK: - ConnectionDiagnostics Tests

final class ConnectionDiagnosticsTests: XCTestCase {

    func testInitialState() {
        let diag = ConnectionDiagnostics()
        XCTAssertNil(diag.serverVersion)
        XCTAssertNil(diag.clientVersion)
        XCTAssertTrue(diag.offeredSecurityTypes.isEmpty)
        XCTAssertNil(diag.selectedSecurityType)
        XCTAssertNil(diag.serverInit)
        XCTAssertNil(diag.encryptionMode)
        XCTAssertFalse(diag.isHighPerformanceMode)
        XCTAssertNil(diag.connectionStartTime)
        XCTAssertNil(diag.handshakeCompleteTime)
        XCTAssertNil(diag.lastError)
        XCTAssertNil(diag.handshakeDuration)
    }

    func testSetProperties() {
        let diag = ConnectionDiagnostics()

        diag.serverVersion = .v3_8
        XCTAssertEqual(diag.serverVersion, .v3_8)

        diag.clientVersion = .v3_8
        XCTAssertEqual(diag.clientVersion, .v3_8)

        diag.offeredSecurityTypes = [.none, .vncAuthentication]
        XCTAssertEqual(diag.offeredSecurityTypes.count, 2)

        diag.selectedSecurityType = .vncAuthentication
        XCTAssertEqual(diag.selectedSecurityType, .vncAuthentication)

        let si = ServerInit(framebufferWidth: 1920, framebufferHeight: 1080, pixelFormat: .bgra8888, name: "Test")
        diag.serverInit = si
        XCTAssertEqual(diag.serverInit, si)

        diag.encryptionMode = "AES-128-CBC"
        XCTAssertEqual(diag.encryptionMode, "AES-128-CBC")

        diag.isHighPerformanceMode = true
        XCTAssertTrue(diag.isHighPerformanceMode)

        diag.lastError = .connectionClosed
        XCTAssertEqual(diag.lastError, .connectionClosed)
    }

    func testHandshakeDuration() {
        let diag = ConnectionDiagnostics()
        XCTAssertNil(diag.handshakeDuration)

        let start = Date()
        diag.connectionStartTime = start
        XCTAssertNil(diag.handshakeDuration) // no end time yet

        let end = start.addingTimeInterval(1.5)
        diag.handshakeCompleteTime = end
        XCTAssertNotNil(diag.handshakeDuration)
        XCTAssertEqual(diag.handshakeDuration!, 1.5, accuracy: 0.001)
    }

    func testReset() {
        let diag = ConnectionDiagnostics()
        diag.serverVersion = .v3_8
        diag.clientVersion = .v3_8
        diag.offeredSecurityTypes = [.none]
        diag.selectedSecurityType = SecurityType.none
        diag.serverInit = ServerInit(framebufferWidth: 800, framebufferHeight: 600, pixelFormat: .bgra8888, name: "T")
        diag.encryptionMode = "AES"
        diag.isHighPerformanceMode = true
        diag.connectionStartTime = Date()
        diag.handshakeCompleteTime = Date()
        diag.lastError = .timeout

        diag.reset()

        XCTAssertNil(diag.serverVersion)
        XCTAssertNil(diag.clientVersion)
        XCTAssertTrue(diag.offeredSecurityTypes.isEmpty)
        XCTAssertNil(diag.selectedSecurityType)
        XCTAssertNil(diag.serverInit)
        XCTAssertNil(diag.encryptionMode)
        XCTAssertFalse(diag.isHighPerformanceMode)
        XCTAssertNil(diag.connectionStartTime)
        XCTAssertNil(diag.handshakeCompleteTime)
        XCTAssertNil(diag.lastError)
    }

    func testSummaryContainsBasicInfo() {
        let diag = ConnectionDiagnostics()
        diag.serverVersion = .v3_8
        diag.clientVersion = .v3_8
        diag.offeredSecurityTypes = [.none, .vncAuthentication]
        diag.selectedSecurityType = .vncAuthentication

        let si = ServerInit(framebufferWidth: 1920, framebufferHeight: 1080, pixelFormat: .bgra8888, name: "TestServer")
        diag.serverInit = si
        diag.encryptionMode = "ChaCha20-Poly1305"

        let summary = diag.summary()
        XCTAssertTrue(summary.contains("VNC Connection Diagnostics"))
        XCTAssertTrue(summary.contains("Server Version"))
        XCTAssertTrue(summary.contains("Client Version"))
        XCTAssertTrue(summary.contains("Offered Security Types"))
        XCTAssertTrue(summary.contains("Selected Security Type"))
        XCTAssertTrue(summary.contains("TestServer"))
        XCTAssertTrue(summary.contains("1920x1080"))
        XCTAssertTrue(summary.contains("ChaCha20-Poly1305"))
    }

    func testSummaryMinimalInfo() {
        let diag = ConnectionDiagnostics()
        let summary = diag.summary()
        XCTAssertTrue(summary.contains("VNC Connection Diagnostics"))
        XCTAssertTrue(summary.contains("High-Performance Mode: false"))
    }

    func testSummaryWithError() {
        let diag = ConnectionDiagnostics()
        diag.lastError = .authenticationFailed("bad password")
        let summary = diag.summary()
        XCTAssertTrue(summary.contains("Last Error"))
        XCTAssertTrue(summary.contains("bad password"))
    }

    func testSummaryWithHandshakeDuration() {
        let diag = ConnectionDiagnostics()
        let start = Date()
        diag.connectionStartTime = start
        diag.handshakeCompleteTime = start.addingTimeInterval(0.250)

        let summary = diag.summary()
        XCTAssertTrue(summary.contains("Handshake Duration"))
        XCTAssertTrue(summary.contains("0.250"))
    }

    func testSummaryShowsTraceEntryCount() {
        let diag = ConnectionDiagnostics()
        diag.protocolTrace.recordSent(type: "Test", data: Data([0]))
        diag.protocolTrace.recordSent(type: "Test2", data: Data([1]))

        let summary = diag.summary()
        XCTAssertTrue(summary.contains("Trace Entries: 2"))
    }
}

// MARK: - VNCConnectionState Tests

final class VNCConnectionStateTests: XCTestCase {

    func testCanConnect() {
        XCTAssertTrue(VNCConnectionState.idle.canConnect)
        XCTAssertTrue(VNCConnectionState.disconnected.canConnect)
        XCTAssertTrue(VNCConnectionState.failed("error").canConnect)

        XCTAssertFalse(VNCConnectionState.connecting.canConnect)
        XCTAssertFalse(VNCConnectionState.connected.canConnect)
        XCTAssertFalse(VNCConnectionState.disconnecting.canConnect)
    }

    func testIsConnected() {
        XCTAssertTrue(VNCConnectionState.connected.isConnected)
        XCTAssertFalse(VNCConnectionState.idle.isConnected)
        XCTAssertFalse(VNCConnectionState.connecting.isConnected)
        XCTAssertFalse(VNCConnectionState.disconnecting.isConnected)
        XCTAssertFalse(VNCConnectionState.disconnected.isConnected)
        XCTAssertFalse(VNCConnectionState.failed("err").isConnected)
    }

    func testIsConnecting() {
        XCTAssertTrue(VNCConnectionState.connecting.isConnecting)
        XCTAssertFalse(VNCConnectionState.idle.isConnecting)
        XCTAssertFalse(VNCConnectionState.connected.isConnecting)
    }

    func testEquatable() {
        XCTAssertEqual(VNCConnectionState.idle, VNCConnectionState.idle)
        XCTAssertEqual(VNCConnectionState.connected, VNCConnectionState.connected)
        XCTAssertEqual(VNCConnectionState.failed("a"), VNCConnectionState.failed("a"))
        XCTAssertNotEqual(VNCConnectionState.idle, VNCConnectionState.connecting)
        XCTAssertNotEqual(VNCConnectionState.failed("a"), VNCConnectionState.failed("b"))
    }

    func testInitFromProtocolState() {
        XCTAssertEqual(VNCConnectionState(from: .idle), .idle)
        XCTAssertEqual(VNCConnectionState(from: .connecting), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .waitingForProtocolVersion), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .waitingForSecurityTypes), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .authenticating(.vncAuthentication)), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .waitingForAuthResult), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .waitingForServerInit), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .operational), .connected)
        XCTAssertEqual(VNCConnectionState(from: .disconnecting), .disconnecting)
        XCTAssertEqual(VNCConnectionState(from: .disconnected), .disconnected)

        if case .failed = VNCConnectionState(from: .failed(.connectionClosed)) {
            // good
        } else {
            XCTFail("Expected .failed state")
        }
    }
}

// MARK: - Video Band Geometry Tests

final class VideoBandGeometryTests: XCTestCase {

    @MainActor
    func testLiveScreenResizeRecomputesAspectFitContainer() {
        let renderer = VideoBandLayerRenderer()
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        renderer.setScreenSize(width: 1920, height: 1080)

        XCTAssertEqual(renderer.containerLayer.frame.width, 1000, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.minY, 218.75, accuracy: 0.001)

        renderer.setScreenSize(width: 1000, height: 1000)

        XCTAssertEqual(renderer.containerLayer.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.width, 1000, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.height, 1000, accuracy: 0.001)
    }

    @MainActor
    func testNewMediaGenerationRetainsOldFrameUntilAtomicReplacement() throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 100, height: 100))
        renderer.setScreenSize(width: 100, height: 100)

        renderer.setBands([1: try makePixelBuffer(width: 100, height: 100)])
        XCTAssertEqual(renderer.containerLayer.sublayers?.count, 1)

        renderer.beginStreamGeneration()
        XCTAssertEqual(
            renderer.containerLayer.sublayers?.count,
            1,
            "The last complete frame should remain visible during negotiation")

        renderer.setBands([2: try makePixelBuffer(width: 100, height: 100)])
        XCTAssertEqual(
            renderer.containerLayer.sublayers?.count,
            1,
            "The first new frame must replace, not accumulate with, old SSRC layers")
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}

// MARK: - TouchInputHandler Tests

final class TouchInputHandlerTests: XCTestCase {

    // MARK: - Button mask constants

    func testButtonMaskConstants() {
        XCTAssertEqual(TouchInputHandler.leftButton, 0x01)
        XCTAssertEqual(TouchInputHandler.middleButton, 0x02)
        XCTAssertEqual(TouchInputHandler.rightButton, 0x04)
        XCTAssertEqual(TouchInputHandler.scrollUp, 0x08)
        XCTAssertEqual(TouchInputHandler.scrollDown, 0x10)
    }

    // MARK: - Tap generates move + press + release

    @MainActor
    func testHandleTap() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleTap(x: 100, y: 200)
        XCTAssertEqual(events.count, 3)
        // Move
        XCTAssertEqual(events[0].0, 0)
        XCTAssertEqual(events[0].1, 100)
        XCTAssertEqual(events[0].2, 200)
        // Press
        XCTAssertEqual(events[1].0, TouchInputHandler.leftButton)
        XCTAssertEqual(events[1].1, 100)
        XCTAssertEqual(events[1].2, 200)
        // Release
        XCTAssertEqual(events[2].0, 0)
        XCTAssertEqual(events[2].1, 100)
        XCTAssertEqual(events[2].2, 200)
    }

    @MainActor
    func testHandleRightClick() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleRightClick(x: 50, y: 75)
        XCTAssertEqual(events.count, 3)
        // Move
        XCTAssertEqual(events[0].0, 0)
        // Press right button
        XCTAssertEqual(events[1].0, TouchInputHandler.rightButton)
        // Release
        XCTAssertEqual(events[2].0, 0)
    }

    @MainActor
    func testHandleMove() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleMove(x: 300, y: 400)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, 0) // no buttons
        XCTAssertEqual(events[0].1, 300)
        XCTAssertEqual(events[0].2, 400)
    }

    @MainActor
    func testHandleDrag() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleDrag(x: 150, y: 250)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, TouchInputHandler.leftButton)
        XCTAssertEqual(events[0].1, 150)
        XCTAssertEqual(events[0].2, 250)
    }

    @MainActor
    func testHandleDragEnd() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleDragEnd(x: 200, y: 300)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, 0) // no buttons (released)
    }

    @MainActor
    func testHandleDoubleTap() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleDoubleTap(x: 100, y: 100)
        // Double tap = 2 taps, each tap = 3 events (move + press + release)
        XCTAssertEqual(events.count, 6)
    }

    @MainActor
    func testHandleScrollDown() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        // Negative CGEvent deltaY = scroll down
        handler.handleScroll(x: 100, y: 100, deltaY: -10)
        // At least one press+release pair
        XCTAssertGreaterThanOrEqual(events.count, 2)
        // Verify we get scrollDown button
        let pressEvents = events.filter { $0.0 == TouchInputHandler.scrollDown }
        XCTAssertFalse(pressEvents.isEmpty)
    }

    @MainActor
    func testHandleScrollUp() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        // Positive CGEvent deltaY = scroll up
        handler.handleScroll(x: 100, y: 100, deltaY: 10)
        let pressEvents = events.filter { $0.0 == TouchInputHandler.scrollUp }
        XCTAssertFalse(pressEvents.isEmpty)
    }

    @MainActor
    func testHandleScrollLargeDelta() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        // Large delta should produce multiple scroll steps
        handler.handleScroll(x: 100, y: 100, deltaY: 50)
        let pressEvents = events.filter { $0.0 == TouchInputHandler.scrollUp }
        XCTAssertGreaterThanOrEqual(pressEvents.count, 5) // 50/10 = 5 steps
    }

    @MainActor
    func testExactScrollSteps() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleScroll(x: 20, y: 30, steps: -3)

        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events.map(\.0), [
            TouchInputHandler.scrollDown, 0,
            TouchInputHandler.scrollDown, 0,
            TouchInputHandler.scrollDown, 0,
        ])
    }

    @MainActor
    func testPreciseScrollPreservesPointsPhaseAndDirection() {
        var scrollEvents: [AppleScrollEvent] = []
        let handler = TouchInputHandler(
            sendPointerEvent: { _, _, _ in
                XCTFail("Precise input should go through the scroll event path")
            },
            sendScrollEvent: { scrollEvents.append($0) })

        handler.handleScroll(
            x: 20,
            y: 30,
            pointDeltaX: 1,
            pointDeltaY: -4,
            scrollPhase: .changed)

        XCTAssertEqual(scrollEvents.count, 1)
        let event = scrollEvents[0]
        XCTAssertEqual(event.deltaX, 1)
        XCTAssertEqual(event.deltaY, -1)
        XCTAssertEqual(event.pointDeltaX, 1)
        XCTAssertEqual(event.pointDeltaY, -4)
        XCTAssertEqual(event.fixedDeltaX, 6_553)
        XCTAssertEqual(event.fixedDeltaY, -26_214)
        XCTAssertEqual(event.scrollPhase, .changed)
        XCTAssertEqual(event.flags, [.continuous])
        XCTAssertEqual(event.x, 20)
        XCTAssertEqual(event.y, 30)
    }

    @MainActor
    func testPreciseScrollGestureEnvelopeUsesTouchSource() {
        var gestureEvents: [AppleGestureEvent] = []
        let handler = TouchInputHandler(
            sendPointerEvent: { _, _, _ in },
            sendScrollEvent: { _ in },
            sendGestureEvent: { gestureEvents.append($0) })

        handler.handleGesture(kind: .began, x: 20, y: 30)
        handler.handleGesture(kind: .ended, x: 21, y: 31)

        XCTAssertEqual(gestureEvents, [
            AppleGestureEvent(kind: .began, x: 20, y: 30),
            AppleGestureEvent(kind: .ended, x: 21, y: 31),
        ])
    }

    @MainActor
    func testPreciseScrollDeltaRepresentationsSaturateSafely() {
        var scrollEvents: [AppleScrollEvent] = []
        let handler = TouchInputHandler(
            sendPointerEvent: { _, _, _ in },
            sendScrollEvent: { scrollEvents.append($0) })

        handler.handleScroll(
            x: 1,
            y: 2,
            pointDeltaX: .max,
            pointDeltaY: .min,
            scrollPhase: .changed)

        XCTAssertEqual(scrollEvents[0].deltaX, .max)
        XCTAssertEqual(scrollEvents[0].deltaY, .min)
        XCTAssertEqual(scrollEvents[0].fixedDeltaX, .max)
        XCTAssertEqual(scrollEvents[0].fixedDeltaY, .min)
    }

    func testScrollPointAccumulatorPreservesSubpointMovement() {
        var accumulator = ScrollPointAccumulator()

        XCTAssertEqual(accumulator.consume(deltaX: 0.4, deltaY: -0.6).x, 0)
        let second = accumulator.consume(deltaX: 0.7, deltaY: -0.6)
        XCTAssertEqual(second.x, 1)
        XCTAssertEqual(second.y, -1)
        XCTAssertEqual(accumulator.remainderX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(accumulator.remainderY, -0.2, accuracy: 0.0001)
    }

    func testInputQueueCoalescesStalePointerPositionsButKeepsRunStart() {
        var queue = SessionInputQueue()
        queue.enqueue(.pointer(buttonMask: 1, x: 10, y: 20))
        queue.enqueue(.pointer(buttonMask: 1, x: 11, y: 21))
        queue.enqueue(.pointer(buttonMask: 1, x: 12, y: 22))
        queue.enqueue(.pointer(buttonMask: 1, x: 13, y: 23))
        queue.enqueue(.pointer(buttonMask: 0, x: 13, y: 23))

        XCTAssertEqual(queue.pending, [
            .pointer(buttonMask: 1, x: 10, y: 20),
            .pointer(buttonMask: 1, x: 13, y: 23),
            .pointer(buttonMask: 0, x: 13, y: 23),
        ])
    }

    func testInputQueueMergesOnlyContinuousScrollSamples() {
        func scroll(
            _ y: Int32,
            phase: AppleScrollEvent.Phase,
            x: UInt16
        ) -> SessionInputEvent {
            .scroll(AppleScrollEvent(
                deltaY: y == 0 ? 0 : (y > 0 ? 1 : -1),
                pointDeltaY: y,
                scrollPhase: phase,
                scrollCount: 1,
                flags: [.continuous],
                x: x,
                y: 20))
        }

        var queue = SessionInputQueue()
        queue.enqueue(scroll(0, phase: .began, x: 10))
        queue.enqueue(scroll(3, phase: .changed, x: 11))
        queue.enqueue(scroll(4, phase: .changed, x: 12))
        queue.enqueue(scroll(0, phase: .ended, x: 12))

        XCTAssertEqual(queue.count, 3)
        guard case .scroll(let merged) = queue.pending[1] else {
            return XCTFail("Expected merged continuous scroll")
        }
        XCTAssertEqual(merged.deltaY, 2)
        XCTAssertEqual(merged.pointDeltaY, 7)
        XCTAssertEqual(merged.scrollCount, 2)
        XCTAssertEqual(merged.x, 12)
        XCTAssertEqual(merged.scrollPhase, .changed)
    }

    func testInputQueueKeepsGestureEnvelopeAsScrollOrderingBarrier() {
        let changed = AppleScrollEvent(
            pointDeltaY: 3,
            scrollPhase: .changed,
            flags: [.continuous],
            x: 10,
            y: 20)
        let end = AppleGestureEvent(kind: .ended, x: 10, y: 20)
        var queue = SessionInputQueue()

        queue.enqueue(.scroll(changed))
        queue.enqueue(.gesture(end))
        queue.enqueue(.scroll(changed))

        XCTAssertEqual(queue.pending, [
            .scroll(changed),
            .gesture(end),
            .scroll(changed),
        ])
    }

    @MainActor
    func testCoordinatePassthrough() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        // Test edge coordinates
        handler.handleMove(x: 0, y: 0)
        handler.handleMove(x: UInt16.max, y: UInt16.max)
        handler.handleMove(x: 1920, y: 1080)

        XCTAssertEqual(events[0].1, 0)
        XCTAssertEqual(events[0].2, 0)
        XCTAssertEqual(events[1].1, UInt16.max)
        XCTAssertEqual(events[1].2, UInt16.max)
        XCTAssertEqual(events[2].1, 1920)
        XCTAssertEqual(events[2].2, 1080)
    }
}

// MARK: - VNCError Tests

final class VNCErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(VNCError.notConnected.errorDescription)
        XCTAssertNotNil(VNCError.alreadyConnected.errorDescription)
        XCTAssertNotNil(VNCError.connectionFailed("test").errorDescription)
        XCTAssertNotNil(VNCError.authenticationFailed("test").errorDescription)
        XCTAssertNotNil(VNCError.protocolError(.connectionClosed).errorDescription)
        XCTAssertNotNil(VNCError.framebufferError("test").errorDescription)
        XCTAssertNotNil(VNCError.unsupportedFeature("test").errorDescription)
    }

    func testErrorDescriptionsContainDetails() {
        XCTAssertTrue(VNCError.connectionFailed("timeout").errorDescription!.contains("timeout"))
        XCTAssertTrue(VNCError.authenticationFailed("bad pw").errorDescription!.contains("bad pw"))
        XCTAssertTrue(VNCError.framebufferError("alloc").errorDescription!.contains("alloc"))
        XCTAssertTrue(VNCError.unsupportedFeature("H.265").errorDescription!.contains("H.265"))
    }
}
