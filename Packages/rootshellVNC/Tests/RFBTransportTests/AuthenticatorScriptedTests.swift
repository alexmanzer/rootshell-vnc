import XCTest
import RFBProtocol
@testable import RFBTransport

/// VNC Authentication (Type 2) driven over a scripted connection: full
/// challenge/response message flow plus the DES output itself.
final class AuthenticatorScriptedTests: XCTestCase {

    private static let challenge = Data((0..<16).map(UInt8.init))

    /// Externally computed reference (OpenSSL DES-ECB): password "password"
    /// bit-reversed per byte gives key 0e86ceceeef64e26; encrypting the
    /// challenge 000102...0f in two independent 8-byte blocks yields this.
    private static let expectedResponse = Data([
        0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb,
        0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2,
    ])

    func testVNCAuthenticatorMatchesKnownDESVector() async throws {
        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(Self.challenge)

        let authenticator = VNCAuthenticator(password: "password")
        let result = try await authenticator.authenticate(connection: connection)

        // Exactly the 16-byte response and nothing else; no Apple key material.
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, Self.expectedResponse)
        XCTAssertNil(result.appleSessionKey)
    }

    func testVNCAuthenticatorUsesOnlyFirstEightPasswordBytes() async throws {
        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(Self.challenge)

        // VNC DES keys are truncated to 8 bytes, so the trailing characters
        // must not change the response.
        let authenticator = VNCAuthenticator(password: "passwordEXTRA")
        _ = try await authenticator.authenticate(connection: connection)

        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, Self.expectedResponse)
    }

    func testVNCAuthenticatorSurfacesEOFWhileReadingChallenge() async throws {
        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(Data([0x00, 0x01]))
        await connection.finishServerStream()

        let authenticator = VNCAuthenticator(password: "password")
        do {
            _ = try await authenticator.authenticate(connection: connection)
            XCTFail("Expected authenticate to fail on a truncated challenge")
        } catch let error as VNCProtocolError {
            XCTAssertEqual(error, .connectionClosed)
        }
    }
}
