import XCTest
import Darwin
import Network
@testable import RFBTransport
@testable import RFBProtocol

/// The first dial to an on-demand VPN destination (Tailscale et al.) routinely
/// fails because the tunnel comes up in response to that dial. `connect()`
/// must retry briefly instead of surfacing the first failure to the user.
final class TCPConnectionRetryTests: XCTestCase {

    /// Bind an ephemeral port and release it, so the first dial is actively
    /// refused (nothing bound) instead of silently swallowed by a
    /// bound-but-not-listening socket — the latter lets TCP SYN retransmits
    /// succeed within a single dial attempt, bypassing the retry under test.
    private func reserveClosedPort() -> UInt16? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &length)
            }
        }
        guard nameResult == 0 else { return nil }
        return UInt16(bigEndian: bound.sin_port)
    }

    func testConnectSucceedsWhenListenerAppearsAfterFirstAttempt() async throws {
        guard let port = reserveClosedPort() else {
            XCTFail("failed to reserve a port")
            return
        }

        // Nothing listens yet: the first dial is refused immediately. Bring
        // the listener up mid-backoff — the shape of an on-demand tunnel
        // woken by the failed attempt.
        let listenerBox = ListenerBox()
        let listenTask = Task {
            try await Task.sleep(nanoseconds: 200_000_000)
            listenerBox.set(LoopbackListener(port: port))
        }
        defer {
            listenTask.cancel()
            listenerBox.take()?.close()
        }

        // Short per-attempt timeout: a refused loopback dial parks in
        // Network.framework's .waiting state (it only re-dials on a path
        // change, and none happens on loopback), so each attempt runs the
        // full connect timeout before the retry loop gets control.
        let connection = TCPConnection(
            host: "127.0.0.1", port: port,
            maxDialAttempts: 3,
            dialRetryBackoffNanos: 200_000_000,
            connectTimeoutSeconds: 1)
        try await withTimeout(seconds: 10) {
            try await connection.connect()
        }
        let connected = await connection.isConnected
        XCTAssertTrue(connected)
        let remoteHost = await connection.remoteEndpointHost()
        XCTAssertEqual(remoteHost, "127.0.0.1")
        await connection.close()
    }

    func testNumericHostPreservesScopedIPv6Interface() throws {
        let address = try XCTUnwrap(IPv6Address("fe80::1%lo0"))
        let endpoint = NWEndpoint.hostPort(
            host: .ipv6(address),
            port: NWEndpoint.Port(rawValue: 5900)!)

        XCTAssertEqual(
            TCPConnection.numericHost(from: endpoint),
            "fe80::1%lo0")
    }

    func testConnectFailsAfterExhaustingRetries() async throws {
        guard let port = reserveClosedPort() else {
            XCTFail("failed to reserve a port")
            return
        }

        // Never listens: every attempt is refused and connect() must
        // eventually surface the failure rather than retry forever.
        let connection = TCPConnection(
            host: "127.0.0.1", port: port,
            maxDialAttempts: 3,
            dialRetryBackoffNanos: 50_000_000,
            connectTimeoutSeconds: 1)
        do {
            try await withTimeout(seconds: 10) {
                try await connection.connect()
            }
            XCTFail("connect() should have thrown with no listener")
        } catch {
            // expected
        }
        let connected = await connection.isConnected
        XCTAssertFalse(connected)
    }
}

private final class LoopbackListener: @unchecked Sendable {
    let fd: Int32

    init?(port: UInt16) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var enable: Int32 = 1
        _ = setsockopt(
            sock, SOL_SOCKET, SO_REUSEADDR,
            &enable, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        addr.sin_port = port.bigEndian
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(sock, 4) == 0 else {
            Darwin.close(sock)
            return nil
        }
        fd = sock
    }

    func close() {
        Darwin.close(fd)
    }
}

/// Hands a listener created inside a background task back to the test for
/// cleanup without capturing mutable state across concurrency domains.
private final class ListenerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: LoopbackListener?

    func set(_ value: LoopbackListener?) {
        lock.withLock { listener = value }
    }

    func take() -> LoopbackListener? {
        lock.withLock {
            defer { listener = nil }
            return listener
        }
    }
}
