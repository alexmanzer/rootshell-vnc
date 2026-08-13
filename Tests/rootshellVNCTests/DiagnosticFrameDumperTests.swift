import XCTest
@testable import rootshellVNC

final class DiagnosticFrameDumperTests: XCTestCase {
    func testDecodedFrameCaptureIsDisabledWithoutExplicitDirectory() {
        XCTAssertNil(DiagnosticFrameDumper.configuredRoot(environment: [:]))
        XCTAssertNil(DiagnosticFrameDumper.configuredRoot(environment: [
            "ROOTSHELL_VNC_FRAME_OUT_DIR": "",
        ]))
    }

    func testDecodedFrameCaptureUsesExplicitDirectory() {
        #if DEBUG
        XCTAssertEqual(
            DiagnosticFrameDumper.configuredRoot(environment: [
                "ROOTSHELL_VNC_FRAME_OUT_DIR": "/tmp/rootshell-frame-capture",
            ])?.path,
            "/tmp/rootshell-frame-capture")
        #else
        XCTAssertNil(DiagnosticFrameDumper.configuredRoot(environment: [
            "ROOTSHELL_VNC_FRAME_OUT_DIR": "/tmp/rootshell-frame-capture",
        ]))
        #endif
    }
}
