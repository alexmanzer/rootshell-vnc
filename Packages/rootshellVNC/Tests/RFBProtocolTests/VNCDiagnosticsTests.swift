import XCTest
@testable import RFBProtocol

final class VNCDiagnosticsTests: XCTestCase {
    func testSensitiveDiagnosticsFollowBuildConfiguration() {
        let environment = [
            "ROOTSHELL_VNC_TRACE_PROTOCOL_BYTES": "1",
            "ROOTSHELL_VNC_DUMP_MEDIA_TCP": "/tmp/media.dump",
        ]

        #if DEBUG
        XCTAssertTrue(VNCDiagnostics.allowsSensitiveDiagnostics)
        XCTAssertTrue(VNCDiagnostics.isEnabled(
            "ROOTSHELL_VNC_TRACE_PROTOCOL_BYTES",
            environment: environment))
        XCTAssertEqual(
            VNCDiagnostics.value(
                for: "ROOTSHELL_VNC_DUMP_MEDIA_TCP",
                environment: environment),
            "/tmp/media.dump")
        #else
        XCTAssertFalse(VNCDiagnostics.allowsSensitiveDiagnostics)
        XCTAssertFalse(VNCDiagnostics.isEnabled(
            "ROOTSHELL_VNC_TRACE_PROTOCOL_BYTES",
            environment: environment))
        XCTAssertNil(VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_MEDIA_TCP",
            environment: environment))
        #endif
    }

    func testMissingAndEmptySettingsStayDisabled() {
        XCTAssertFalse(VNCDiagnostics.isEnabled("MISSING", environment: [:]))
        XCTAssertNil(VNCDiagnostics.value(for: "EMPTY", environment: ["EMPTY": ""]))
    }
}
