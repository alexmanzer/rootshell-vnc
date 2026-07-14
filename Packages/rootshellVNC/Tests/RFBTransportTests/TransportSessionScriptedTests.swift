import XCTest
import RFBProtocol
@testable import RFBTransport

/// Offline end-to-end coverage of `TransportSession` over a scripted
/// ``RFBConnection`` — the first tests that drive the real handshake and
/// read loop without a live VNC server.
final class TransportSessionScriptedTests: XCTestCase {

    func testPlainRFB38HandshakeAndRawUpdateOverScriptedConnection() async throws {
        let connection = ScriptedRFBConnection()

        // Server script: version, one security type (None), SecurityResult OK,
        // then ServerInit. TransportSession reads these strictly in order.
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 1024, height: 768, name: "scripted"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            connection: connection)
        try await session.connect()

        // The complete client half of the handshake, byte for byte: version
        // echo, security selection, ClientInit, then the post-init burst.
        var expectedClientBytes = ProtocolVersion.v3_8.wireBytes()
        expectedClientBytes.append(SecurityType.none.rawValue)
        expectedClientBytes.append(0x01) // ClientInit: shared session
        expectedClientBytes.append(
            ClientMessage.setPixelFormat(.bgra8888).serialize())
        expectedClientBytes.append(
            ClientMessage.setEncodings([.copyRect, .raw]).serialize())
        expectedClientBytes.append(ClientMessage.framebufferUpdateRequest(
            incremental: false, x: 0, y: 0, width: 1024, height: 768
        ).serialize())
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, expectedClientBytes)

        // Raw-encoded FramebufferUpdate round trip through the read loop.
        let pixels = Data((1...8).map(UInt8.init)) // 2x1 at 4 bytes/pixel
        var update = Data([0, 0, 0, 1]) // type, padding, one rectangle
        update.append(Self.rectangleHeader(
            x: 0, y: 0, width: 2, height: 1, encoding: Encoding.raw.rawValue))
        update.append(pixels)
        await connection.enqueueServerBytes(update)

        let observed = await Self.withTimeout(seconds: 10) {
            () -> (ServerInit?, [(FramebufferRect, Data)]?) in
            var serverInit: ServerInit?
            for await event in session.events {
                switch event {
                case .serverInit(let received):
                    serverInit = received
                case .framebufferUpdate(let rects):
                    return (serverInit, rects)
                default:
                    break
                }
            }
            return (serverInit, nil)
        }

        let receivedServerInit = observed?.0
        let receivedUpdate = observed?.1
        XCTAssertNotNil(receivedUpdate)
        XCTAssertEqual(receivedServerInit?.framebufferWidth, 1024)
        XCTAssertEqual(receivedServerInit?.framebufferHeight, 768)
        XCTAssertEqual(receivedServerInit?.name, "scripted")
        XCTAssertEqual(receivedUpdate?.count, 1)
        XCTAssertEqual(
            receivedUpdate?.first?.0,
            FramebufferRect(x: 0, y: 0, width: 2, height: 1, encoding: .raw))
        XCTAssertEqual(receivedUpdate?.first?.1, pixels)

        await session.disconnect()
    }

    func testConnectRefusesAppleMediaModeOverCustomTransport() async throws {
        let connection = ScriptedRFBConnection()
        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: [.appleH264, .zlib, .raw],
            connection: connection)

        do {
            try await session.connect()
            XCTFail("Expected connect() to refuse UDP media over a custom transport")
        } catch let error as VNCProtocolError {
            guard case .protocolViolation = error else {
                XCTFail("Expected protocolViolation, got \(error)")
                return
            }
        }
        // Refused before any handshake traffic.
        let sent = await connection.sentBytes()
        XCTAssertTrue(sent.isEmpty)
    }

    func testConnectSurfacesConnectionClosedOnTruncatedHandshake() async throws {
        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(Data("RFB 0".utf8))
        await connection.finishServerStream()

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            connection: connection)
        do {
            try await session.connect()
            XCTFail("Expected connect() to fail on server EOF")
        } catch let error as VNCProtocolError {
            XCTAssertEqual(error, .connectionClosed)
        }
    }

    // MARK: - Wire-format helpers

    private static func serverInitMessage(
        width: UInt16,
        height: UInt16,
        name: String
    ) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xff)])
        data.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xff)])
        data.append(PixelFormat.bgra8888.wireBytes())
        let nameBytes = Data(name.utf8)
        let length = UInt32(nameBytes.count)
        data.append(contentsOf: [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        data.append(nameBytes)
        return data
    }

    private static func rectangleHeader(
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        encoding: Int32
    ) -> Data {
        var data = Data()
        for value in [x, y, width, height] {
            data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
        }
        let raw = UInt32(bitPattern: encoding)
        data.append(contentsOf: [
            UInt8((raw >> 24) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8(raw & 0xff),
        ])
        return data
    }

    /// Bound an event-stream wait so a protocol bug fails the test instead of
    /// hanging the suite. Returns nil on timeout.
    private static func withTimeout<Result: Sendable>(
        seconds: Int,
        _ operation: @escaping @Sendable () async -> Result
    ) async -> Result? {
        await withTaskGroup(of: Result?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
