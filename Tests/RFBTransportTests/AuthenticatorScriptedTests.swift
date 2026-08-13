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

    func testVeNCryptX509PlainNegotiationAndCredentials() async throws {
        let connection = ScriptedRFBConnection()
        var serverBytes = Data([0, 2, 0, 3])
        for subtype: UInt32 in [260, 261, 262] {
            serverBytes.append(contentsOf: [
                UInt8((subtype >> 24) & 0xff),
                UInt8((subtype >> 16) & 0xff),
                UInt8((subtype >> 8) & 0xff),
                UInt8(subtype & 0xff),
            ])
        }
        await connection.enqueueServerBytes(serverBytes)

        let authenticator = VeNCryptAuthenticator(
            host: "linux.example",
            port: 5901,
            username: "alice",
            password: "secret")
        _ = try await authenticator.authenticate(connection: connection)

        var expected = Data([0, 2, 0, 0, 1, 6]) // version + X509Plain(262)
        expected.append(contentsOf: [0, 0, 0, 5, 0, 0, 0, 6])
        expected.append(Data("alice".utf8))
        expected.append(Data("secret".utf8))
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, expected)
        let endpoint = await connection.upgradedTLSEndpoint()
        XCTAssertEqual(endpoint?.0, "linux.example")
        XCTAssertEqual(endpoint?.1, 5901)
    }

    func testVeNCryptRejectsAnonymousTLSOnlyServer() async throws {
        let connection = ScriptedRFBConnection()
        // TLSNone/TLSVnc/TLSPlain require obsolete anonymous cipher suites.
        var serverBytes = Data([0, 2, 0, 3])
        for subtype: UInt32 in [257, 258, 259] {
            serverBytes.append(contentsOf: [
                UInt8((subtype >> 24) & 0xff),
                UInt8((subtype >> 16) & 0xff),
                UInt8((subtype >> 8) & 0xff),
                UInt8(subtype & 0xff),
            ])
        }
        await connection.enqueueServerBytes(serverBytes)

        do {
            _ = try await VeNCryptAuthenticator(
                host: "linux.example",
                port: 5900,
                username: nil,
                password: "secret"
            ).authenticate(connection: connection)
            XCTFail("Expected anonymous-only VeNCrypt negotiation to fail")
        } catch let error as VNCProtocolError {
            guard case .authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got \(error)")
                return
            }
        }
        let endpoint = await connection.upgradedTLSEndpoint()
        XCTAssertNil(endpoint)
    }
}
