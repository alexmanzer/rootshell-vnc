import Darwin
import Foundation

/// Minimal loopback byte-stream server for tests that must exercise the
/// production `TCPConnection` path (not an injected/custom transport).
final class LoopbackRFBFixture: @unchecked Sendable {
    let port: UInt16

    private let lock = NSLock()
    private var listenerFD: Int32
    private var clientFD: Int32 = -1
    private var received = Data()
    private var serverTask: Task<Void, Never>?

    init(serverBytes: Data) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Self.posixError("socket") }

        var reuse: Int32 = 1
        _ = setsockopt(
            listener, SOL_SOCKET, SO_REUSEADDR,
            &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listener, $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw Self.posixError("bind/listen")
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(listener)
            throw Self.posixError("getsockname")
        }

        listenerFD = listener
        port = UInt16(bigEndian: bound.sin_port)
        serverTask = Task.detached { [weak self] in
            self?.serve(serverBytes: serverBytes)
        }
    }

    deinit {
        close()
    }

    func waitForClientBytes(
        atLeast count: Int,
        timeout: Duration = .seconds(3)
    ) async -> Data? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = lock.withLock { received }
            if snapshot.count >= count { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = lock.withLock { received }
        return snapshot.count >= count ? snapshot : nil
    }

    func sendServerBytes(_ data: Data) throws {
        let descriptor = lock.withLock { clientFD }
        guard descriptor >= 0 else {
            throw Self.posixError("send without connected client")
        }
        guard Self.sendAll(data, to: descriptor) else {
            throw Self.posixError("send")
        }
    }

    func close() {
        let descriptors = lock.withLock { () -> (Int32, Int32) in
            let result = (listenerFD, clientFD)
            listenerFD = -1
            clientFD = -1
            return result
        }
        if descriptors.1 >= 0 {
            _ = shutdown(descriptors.1, SHUT_RDWR)
            Darwin.close(descriptors.1)
        }
        if descriptors.0 >= 0 {
            _ = shutdown(descriptors.0, SHUT_RDWR)
            Darwin.close(descriptors.0)
        }
        serverTask?.cancel()
        serverTask = nil
    }

    private func serve(serverBytes: Data) {
        let listener = lock.withLock { listenerFD }
        guard listener >= 0 else { return }
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else { return }

        let shouldContinue = lock.withLock { () -> Bool in
            guard listenerFD >= 0 else { return false }
            clientFD = accepted
            return true
        }
        guard shouldContinue else {
            Darwin.close(accepted)
            return
        }

        guard Self.sendAll(serverBytes, to: accepted) else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while !Task.isCancelled {
            let count = Darwin.recv(accepted, &buffer, buffer.count, 0)
            if count > 0 {
                lock.withLock {
                    received.append(contentsOf: buffer.prefix(count))
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let sent = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset,
                    0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
}
