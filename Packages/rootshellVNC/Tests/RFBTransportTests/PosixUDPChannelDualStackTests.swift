import XCTest
import Darwin
@testable import RFBTransport
@testable import RFBProtocol

/// Round-trip tests for the dual-stack media socket: the channel must pick its
/// address family from the resolved remote (IPv4 preferred, IPv6 when that is
/// the only family) so Apple HP media works against IPv6-only destinations.
final class PosixUDPChannelDualStackTests: XCTestCase {

    /// Minimal BSD UDP peer bound to a loopback ephemeral port, standing in
    /// for the server end of the symmetric RTP socket.
    private final class UDPTestPeer: @unchecked Sendable {
        let fd: Int32
        let port: UInt16

        init?(family: Int32) {
            let sock = socket(family, SOCK_DGRAM, 0)
            guard sock >= 0 else { return nil }

            var bindResult: Int32 = -1
            if family == AF_INET6 {
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_addr = in6addr_loopback
                addr.sin6_port = 0
                bindResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            } else {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
                addr.sin_port = 0
                bindResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard bindResult == 0 else {
                Darwin.close(sock)
                return nil
            }

            var bound = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(sock, sa, &length)
                }
            }
            guard nameResult == 0 else {
                Darwin.close(sock)
                return nil
            }
            let boundPort: UInt16
            if family == AF_INET6 {
                boundPort = withUnsafeMutablePointer(to: &bound) { ptr in
                    ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        UInt16(bigEndian: $0.pointee.sin6_port)
                    }
                }
            } else {
                boundPort = withUnsafeMutablePointer(to: &bound) { ptr in
                    ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        UInt16(bigEndian: $0.pointee.sin_port)
                    }
                }
            }

            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(
                sock, SOL_SOCKET, SO_RCVTIMEO,
                &timeout, socklen_t(MemoryLayout<timeval>.size))

            fd = sock
            port = boundPort
        }

        /// Block until a datagram arrives, then return it with the sender.
        func receive() -> (data: Data, sender: sockaddr_storage)? {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var sender = sockaddr_storage()
            var senderLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &sender) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &senderLen)
                }
            }
            guard received > 0 else { return nil }
            return (Data(buffer[0..<received]), sender)
        }

        func send(_ data: Data, to destination: sockaddr_storage) {
            var dest = destination
            let length = socklen_t(dest.ss_len)
            _ = data.withUnsafeBytes { raw in
                withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, raw.count, 0, sa, length)
                    }
                }
            }
        }

        func close() {
            Darwin.close(fd)
        }
    }

    private func assertRoundTrip(
        peerFamily: Int32,
        remoteHost: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        guard let peer = UDPTestPeer(family: peerFamily) else {
            XCTFail("failed to create test peer", file: file, line: line)
            return
        }
        defer { peer.close() }

        let channel = PosixUDPChannel(
            localPort: nil,
            remoteHost: remoteHost,
            remotePort: peer.port,
            enableReusePort: false)
        try await channel.start()
        defer { Task { await channel.close() } }

        try await channel.send(Data("ping".utf8))
        guard let (request, sender) = peer.receive() else {
            XCTFail("peer never received the ping", file: file, line: line)
            return
        }
        XCTAssertEqual(request, Data("ping".utf8), file: file, line: line)
        XCTAssertEqual(
            Int32(sender.ss_family), peerFamily,
            "channel dialed the wrong address family", file: file, line: line)

        peer.send(Data("pong".utf8), to: sender)
        let reply = try await withTimeout(seconds: 5) {
            try await channel.receive()
        }
        XCTAssertEqual(reply, Data("pong".utf8), file: file, line: line)
    }

    func testIPv4LiteralRoundTrip() async throws {
        try await assertRoundTrip(peerFamily: AF_INET, remoteHost: "127.0.0.1")
    }

    func testIPv6LiteralRoundTrip() async throws {
        try await assertRoundTrip(peerFamily: AF_INET6, remoteHost: "::1")
    }

    func testBracketedIPv6LiteralRoundTrip() async throws {
        try await assertRoundTrip(peerFamily: AF_INET6, remoteHost: "[::1]")
    }

    /// `localhost` resolves to both families; the channel must keep preferring
    /// IPv4 so the loopback pin in `TransportSession` stays consistent.
    func testDualStackHostnamePrefersIPv4() async throws {
        try await assertRoundTrip(peerFamily: AF_INET, remoteHost: "localhost")
    }

    func testDualStackHostnameCanBeConstrainedToIPv6() async throws {
        guard let peer = UDPTestPeer(family: AF_INET6) else {
            XCTFail("failed to create IPv6 test peer")
            return
        }
        defer { peer.close() }

        let channel = PosixUDPChannel(
            localPort: nil,
            remoteHost: "localhost",
            remotePort: peer.port,
            remoteAddressFamily: .ipv6,
            enableReusePort: false)
        try await channel.start()
        defer { Task { await channel.close() } }

        try await channel.send(Data("ping".utf8))
        guard let (request, sender) = peer.receive() else {
            XCTFail("peer never received the ping")
            return
        }
        XCTAssertEqual(request, Data("ping".utf8))
        XCTAssertEqual(Int32(sender.ss_family), AF_INET6)
    }

    func testUnresolvableHostThrows() async throws {
        let channel = PosixUDPChannel(
            localPort: nil,
            remoteHost: "definitely-not-a-real-host.invalid",
            remotePort: 5900,
            enableReusePort: false)
        do {
            try await channel.start()
            XCTFail("start() should have thrown for an unresolvable host")
        } catch {
            // expected
        }
    }
}

/// Race the operation against a deadline so a broken receive path fails the
/// test instead of hanging the suite.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw VNCProtocolError.ioError("test timeout after \(seconds)s")
        }
        guard let first = try await group.next() else {
            throw VNCProtocolError.ioError("task group returned no result")
        }
        group.cancelAll()
        return first
    }
}
