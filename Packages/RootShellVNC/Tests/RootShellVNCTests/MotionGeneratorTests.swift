import XCTest
import Foundation
import RFBProtocol
@testable import RFBTransport

/// Not a test: a motion generator. Connects and continuously sweeps the remote
/// pointer along the Dock so the screen animates (magnification), while a GUI
/// client under test observes the same server. Opt-in:
///
///   VNC_MOTION_SECONDS=60 VNC_TEST_HOST=... VNC_TEST_USERNAME=... \
///   VNC_TEST_PASSWORD='...' swift test --filter MotionGeneratorTests
final class MotionGeneratorTests: XCTestCase {

    func testGenerateRemoteMotion() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let secondsStr = env["VNC_MOTION_SECONDS"], let seconds = Int(secondsStr) else {
            throw XCTSkip("Set VNC_MOTION_SECONDS to run the motion generator")
        }
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900

        // Plain RFB connection; do NOT request the media stream so this session
        // stays a lightweight input-only client next to the GUI under test.
        let basic: [Encoding] = [.zlib, .zrle]
        let session = TransportSession(host: host, port: port, password: pass, username: user, preferredEncodings: basic)
        let eventTask = Task { for await _ in session.events {} }

        try? await session.connect()
        print("MOTION: connected; sweeping pointer for \(seconds)s")

        let start = Date()
        var i = 0
        while Date().timeIntervalSince(start) < Double(seconds) {
            // Sweep along the Dock (y near bottom of the 2976x1860 screen) so
            // magnification animates; occasionally lift to mid-screen.
            let x = UInt16(300 + (i % 48) * 50)
            let y: UInt16 = (i % 96) < 48 ? 1800 : 1000
            try? await session.sendPointerEvent(buttonMask: 0, x: x, y: y)
            i += 1
            try? await Task.sleep(for: .milliseconds(50))
        }

        print("MOTION: done")
        eventTask.cancel()
        await session.disconnect()
    }
}
