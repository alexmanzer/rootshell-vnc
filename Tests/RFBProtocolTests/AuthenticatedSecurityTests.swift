import Foundation
import XCTest
@testable import RFBProtocol

final class AuthenticatedSecurityTests: XCTestCase {
    private func machine(_ version: ProtocolVersion, username: Bool = false) -> ConnectionStateMachine {
        var machine = ConnectionStateMachine(securityPolicy: .authenticated, hasUsername: username)
        _ = machine.handle(event: .connected)
        _ = machine.handle(event: .receivedProtocolVersion(version))
        return machine
    }

    func testNoneOnlyIsRejectedBeforeClientInitForEveryVersion() {
        for version in [ProtocolVersion.v3_7, .v3_8, .apple] {
            var machine = machine(version)
            let actions = machine.handle(event: .receivedSecurityTypes([.none]))
            XCTAssertEqual(machine.state, .failed(.securityPolicyViolation))
            assertRejected(actions)
            XCTAssertNil(machine.selectedSecurityType)
        }
        var legacy = machine(.v3_3)
        assertRejected(legacy.handle(event: .receivedServerSelectedSecurityType(.none)))
    }

    func testMixedOfferChoosesAuthenticationAndIgnoresEnvironment() {
        let old = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_SECURITY_TYPE"]
        setenv("ROOTSHELL_VNC_SECURITY_TYPE", "none", 1)
        defer {
            if let old { setenv("ROOTSHELL_VNC_SECURITY_TYPE", old, 1) }
            else { unsetenv("ROOTSHELL_VNC_SECURITY_TYPE") }
        }
        var machine = machine(.v3_8)
        let actions = machine.handle(event: .receivedSecurityTypes([.none, .vncAuthentication]))
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(machine.selectedSecurityType, .vncAuthentication)
    }

    func testAppleCredentialsPreferType33AndLegacyCanAuthenticate() {
        var apple = machine(.apple, username: true)
        _ = apple.handle(event: .receivedSecurityTypes([.none, .apple30, .macAuthentication]))
        XCTAssertEqual(apple.selectedSecurityType, .macAuthentication)
        var legacy = machine(.v3_3)
        XCTAssertTrue(legacy.handle(event: .receivedServerSelectedSecurityType(.vncAuthentication)).isEmpty)
        XCTAssertEqual(legacy.selectedSecurityType, .vncAuthentication)
    }

    private func assertRejected(_ actions: [ConnectionAction], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actions.count, 1, file: file, line: line)
        guard case .reportError(.securityPolicyViolation) = actions.first else {
            return XCTFail("Only a policy error may be emitted; no ClientInit or auth payload", file: file, line: line)
        }
    }
}
