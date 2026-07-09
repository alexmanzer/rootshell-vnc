import XCTest
import Foundation
import Network
@testable import RFBProtocol
@testable import RFBTransport

/// Integration tests that connect to a real macOS VNC server.
/// Set VNC_TEST_HOST, VNC_TEST_PORT, VNC_TEST_PASSWORD, VNC_TEST_USERNAME env vars.
final class SRPIntegrationTests: XCTestCase {

    var host: String!
    var port: UInt16!
    var password: String!
    var username: String!

    private final class PrintLimiter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func shouldPrint(limit: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    override func setUp() {
        super.setUp()
        host = ProcessInfo.processInfo.environment["VNC_TEST_HOST"]
        let portStr = ProcessInfo.processInfo.environment["VNC_TEST_PORT"] ?? "5900"
        port = UInt16(portStr) ?? 5900
        password = ProcessInfo.processInfo.environment["VNC_TEST_PASSWORD"] ?? ""
        username = ProcessInfo.processInfo.environment["VNC_TEST_USERNAME"] ?? ""
    }

    func testDumpSRPHandshake() async throws {
        guard let host, !host.isEmpty else {
            throw XCTSkip("VNC_TEST_HOST not set")
        }

        print("\n=== SRP WIRE DUMP ===")
        print("Connecting to \(host):\(port!)")

        // Connect raw TCP
        let conn = TCPConnection(host: host, port: port)
        try await conn.connect()
        print("TCP connected")

        // Read server version (12 bytes)
        let versionData = try await conn.read(exactly: 12)
        let versionStr = String(data: versionData, encoding: .ascii) ?? "???"
        print("Server version raw: \(hexDump(versionData))")
        print("Server version str: \(versionStr.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Send our version back (echo for Apple)
        try await conn.send(versionData)
        print("Sent our version (echo)")

        // Read security type count + types
        let countData = try await conn.read(exactly: 1)
        let count = Int(countData[0])
        print("Security type count: \(count)")

        if count == 0 {
            // Read error reason
            let reasonLen = try await conn.read(exactly: 4)
            let len = Int(reasonLen[0]) << 24 | Int(reasonLen[1]) << 16 | Int(reasonLen[2]) << 8 | Int(reasonLen[3])
            let reason = try await conn.read(exactly: len)
            print("Server rejected: \(String(data: reason, encoding: .utf8) ?? "???")")
            return
        }

        let typesData = try await conn.read(exactly: count)
        let types = typesData.map { SecurityType(rawValue: $0) }
        print("Security types: \(types)")
        print("Types raw bytes: \(hexDump(typesData))")

        // Find SRP (35) or DH (30)
        let hasSRP = typesData.contains(35)
        let hasDH = typesData.contains(30)
        print("Has SRP(35): \(hasSRP), Has DH(30): \(hasDH)")

        // Select SRP if available, else DH
        let selectedType: UInt8 = hasSRP ? 35 : (hasDH ? 30 : typesData[0])
        try await conn.send(Data([selectedType]))
        print("Sent security type: \(selectedType)")

        // Now read raw bytes to understand the server's response format
        // Read in small chunks and dump them
        print("\n--- Server response after security type selection ---")

        // Try reading the first few bytes to detect the framing format
        var allBytes = Data()
        for attempt in 0..<10 {
            do {
                let chunk = try await conn.read(upTo: 4096)
                allBytes.append(chunk)
                print("Chunk \(attempt): \(chunk.count) bytes")
                print("  hex: \(hexDump(chunk.prefix(128)))")
                if chunk.count > 128 {
                    print("  ... (\(chunk.count) total bytes)")
                }

                // If we got a large chunk, that's probably the whole SRP message
                if allBytes.count > 100 {
                    break
                }
            } catch {
                print("Read error on attempt \(attempt): \(error)")
                break
            }
        }

        print("\n--- Total received: \(allBytes.count) bytes ---")
        print("First 16 bytes: \(hexDump(allBytes.prefix(16)))")

        // Try interpreting as TLV with UInt16 length
        print("\n--- Trying UInt16-length TLV parse ---")
        tryParseTLV16(allBytes)

        // Try interpreting as TLV with UInt32 length
        print("\n--- Trying UInt32-length TLV parse ---")
        tryParseTLV32(allBytes)

        // Try interpreting as DH-style (2-byte lengths)
        if selectedType == 30 {
            print("\n--- Trying DH format ---")
            tryParseDH(allBytes)
        }

        conn.close()
        print("\n=== END WIRE DUMP ===\n")
    }

    func testFullSRPAuth() async throws {
        guard let host, !host.isEmpty else {
            throw XCTSkip("VNC_TEST_HOST not set")
        }
        guard !password.isEmpty else {
            throw XCTSkip("VNC_TEST_PASSWORD not set")
        }

        print("\n=== FULL SRP AUTH TEST ===")
        let preferredEncodings: [Encoding]? = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_HIGH_PERFORMANCE"] == "1"
            ? [.appleH264, .appleMultiVariantScreenshare, .appleSubZlibThousands, .zlib, .zrle,
               .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer]
            : nil
        let session = TransportSession(
            host: host,
            port: port,
            password: password,
            username: username,
            preferredEncodings: preferredEncodings
        )
        let tcpRTPPrintLimiter = PrintLimiter()

        // Listen for events
        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .stateChanged(let state):
                    print("State: \(state)")
                case .serverInit(let si):
                    print("ServerInit: \(si.framebufferWidth)x\(si.framebufferHeight) '\(si.name)'")
                case .error(let err):
                    print("ERROR: \(err)")
                case .framebufferUpdate(let rects):
                    print("FB update: \(rects.count) rects")
                    for (rect, data) in rects.prefix(8) {
                        print("  rect: \(rect.width)x\(rect.height) encoding=\(rect.encoding.rawValue) payload=\(data.count)")
                    }
                    if rects.count > 8 {
                        print("  ... \(rects.count - 8) more rects")
                    }
                case .appleMediaUDPStarted(let localPort):
                    print("Apple media UDP started: localPort=\(localPort)")
                case .mediaStreamOffer(let offer):
                    print(
                        "mediaStreamOffer(streamID: \(offer.streamID), type: \(offer.messageType ?? 0), "
                            + "audioPort: \(offer.audioStreamUDPPort ?? 0), "
                            + "video1Port: \(offer.videoStream1UDPPort ?? 0), "
                            + "video2Port: \(offer.videoStream2UDPPort ?? 0), "
                            + "displays: \(offer.videoStreamDisplayCount ?? 0), "
                            + "rawPayload: \(offer.rawPayload.count) bytes)"
                    )
                case .udpDatagram(let datagram):
                    let prefix = datagram.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("Apple media UDP: length=\(datagram.count)")
                    print("  prefix: \(prefix)")
                case .appleMediaRTPPacket(let packet):
                    if tcpRTPPrintLimiter.shouldPrint(limit: 12) {
                        let prefix = packet.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                        print("Apple media TCP RTP: length=\(packet.count)")
                        print("  prefix: \(prefix)")
                    }
                case .appleMediaControlRecord(let encryptedLength, let encryptedPrefix, let plaintextPrefix, let decryptError):
                    print("Apple media TCP: encryptedLength=\(encryptedLength)")
                    print("  encrypted prefix: \(encryptedPrefix.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    if let plaintextPrefix {
                        print("  plaintext prefix: \(plaintextPrefix.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    }
                    if let decryptError {
                        print("  decrypt error: \(decryptError)")
                    }
                default:
                    print("Event: \(event)")
                }
            }
        }

        do {
            try await session.connect()
            print("Connected successfully!")

            // Wait a bit for framebuffer updates
            let waitSeconds = ProcessInfo.processInfo.environment["VNC_TEST_WAIT_SECONDS"]
                .flatMap(Double.init) ?? 3
            try await Task.sleep(for: .seconds(waitSeconds))
        } catch {
            print("Connection failed: \(error)")
        }

        eventTask.cancel()
        await session.disconnect()
        print("=== END FULL SRP AUTH TEST ===\n")
    }

    // MARK: - Helpers

    private func hexDump(_ data: some Collection<UInt8>) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func tryParseTLV16(_ data: Data) {
        var offset = data.startIndex
        var entryNum = 0
        while offset + 3 <= data.endIndex {
            let type = data[offset]
            let length = Int(data[offset + 1]) << 8 | Int(data[offset + 2])
            offset += 3
            if offset + length > data.endIndex {
                print("  Entry \(entryNum): type=0x\(String(format: "%02x", type)) len=\(length) TRUNCATED (only \(data.endIndex - offset) bytes left)")
                break
            }
            let value = data[offset..<offset+length]
            print("  Entry \(entryNum): type=0x\(String(format: "%02x", type)) len=\(length) value=\(hexDump(value.prefix(32)))\(length > 32 ? "..." : "")")
            offset += length
            entryNum += 1
        }
    }

    private func tryParseTLV32(_ data: Data) {
        var offset = data.startIndex
        var entryNum = 0
        while offset + 5 <= data.endIndex {
            let type = data[offset]
            let length = Int(data[offset + 1]) << 24 | Int(data[offset + 2]) << 16
                       | Int(data[offset + 3]) << 8 | Int(data[offset + 4])
            offset += 5
            if length > 100_000 || length < 0 {
                print("  Entry \(entryNum): type=0x\(String(format: "%02x", type)) len=\(length) SUSPICIOUS")
                break
            }
            if offset + length > data.endIndex {
                print("  Entry \(entryNum): type=0x\(String(format: "%02x", type)) len=\(length) TRUNCATED (only \(data.endIndex - offset) bytes left)")
                break
            }
            let value = data[offset..<offset+length]
            print("  Entry \(entryNum): type=0x\(String(format: "%02x", type)) len=\(length) value=\(hexDump(value.prefix(32)))\(length > 32 ? "..." : "")")
            offset += length
            entryNum += 1
        }
    }

    private func tryParseDH(_ data: Data) {
        guard data.count >= 4 else { print("  Too short for DH"); return }
        let genLen = Int(data[0]) << 8 | Int(data[1])
        let keyLen = Int(data[2]) << 8 | Int(data[3])
        print("  generator length: \(genLen)")
        print("  key length: \(keyLen)")
        print("  expected total: \(4 + genLen + keyLen * 2) bytes")
        print("  actual total: \(data.count) bytes")
    }
}
