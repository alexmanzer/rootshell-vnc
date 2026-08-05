import XCTest
@testable import RFBProtocol
@testable import RFBTransport

/// A desynchronized or hostile RFB stream can hand the parser a garbage
/// 32-bit length. Honoring it grows the receive buffer until Data's
/// reallocation dies with a fatal assertion (seen in the field as a 1.47 GB
/// append), so `read(exactly:)` must refuse absurd counts up front with a
/// throwable protocol violation instead.
final class TCPConnectionReadLimitTests: XCTestCase {

    func testAbsurdExactReadIsRefusedBeforeTouchingTheConnection() async {
        let connection = TCPConnection(host: "127.0.0.1", port: 5900)
        do {
            // The exact count from the field crash report.
            _ = try await connection.read(exactly: 0x57ff_f9c3)
            XCTFail("Expected a giant read to be refused")
        } catch let error as VNCProtocolError {
            guard case .protocolViolation = error else {
                return XCTFail("Expected protocolViolation, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInRangeExactReadOnUnconnectedSocketReportsConnectionClosed() async {
        // The cap must be checked before the connection state, and a sane
        // count on a dead connection must keep its established error.
        let connection = TCPConnection(host: "127.0.0.1", port: 5900)
        do {
            _ = try await connection.read(exactly: 8)
            XCTFail("Expected a read on an unconnected socket to throw")
        } catch let error as VNCProtocolError {
            guard case .connectionClosed = error else {
                return XCTFail("Expected connectionClosed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
