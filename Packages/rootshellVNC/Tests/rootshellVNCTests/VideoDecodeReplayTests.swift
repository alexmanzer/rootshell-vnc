import XCTest
import Foundation
@testable import RFBTransport
@testable import RFBRendering

/// Replays real captured Apple media UDP packets through the full receive path
/// (SRTP unprotect -> VideoStreamManager -> HEVCDecoder) to exercise the
/// hardware decode path end-to-end without the GUI or a live server.
///
/// This is the exact path that crashed the SwiftUI app once real RTP started
/// flowing. It is gated on capture files so it only runs when you point it at a
/// capture produced with ROOTSHELL_VNC_DUMP_SRTP_KEYS / ROOTSHELL_VNC_DUMP_MEDIA_UDP:
///
///   ROOTSHELL_VNC_REPLAY_KEYS=/tmp/.../srtp_keys.bin \
///   ROOTSHELL_VNC_REPLAY_UDP=/tmp/.../media_udp.bin \
///   swift test --filter VideoDecodeReplayTests
final class VideoDecodeReplayTests: XCTestCase {

    func testReplayCapturedFramesDoesNotCrashAndDecodes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let keysPath = env["ROOTSHELL_VNC_REPLAY_KEYS"],
              let udpPath = env["ROOTSHELL_VNC_REPLAY_UDP"],
              let keysData = try? Data(contentsOf: URL(fileURLWithPath: keysPath)),
              let udpData = try? Data(contentsOf: URL(fileURLWithPath: udpPath)) else {
            throw XCTSkip("Set ROOTSHELL_VNC_REPLAY_KEYS and ROOTSHELL_VNC_REPLAY_UDP to a capture")
        }

        // keys.bin: repeated [len:UInt8][key bytes]. Order matches 0x1c slots:
        // audioSend, audioRecv, videoSend, videoRecv, video2Send, video2Recv.
        var keys: [Data] = []
        var i = keysData.startIndex
        while i < keysData.endIndex {
            let n = Int(keysData[i]); i += 1
            guard i + n <= keysData.endIndex else { break }
            keys.append(Data(keysData[i..<i + n])); i += n
        }
        let serverToViewerKeys = [keys.count > 3 ? keys[3] : Data(),
                                  keys.count > 1 ? keys[1] : Data()]
            .filter { $0.count >= 46 }
        let contexts = serverToViewerKeys.compactMap { try? AppleSRTPContext(mediaKey: $0) }
        XCTAssertFalse(contexts.isEmpty, "need at least one usable server-to-viewer key")

        // media_udp.bin: repeated [len:UInt16 BE][datagram].
        var datagrams: [Data] = []
        var j = udpData.startIndex
        while j + 2 <= udpData.endIndex {
            let n = Int(udpData[j]) << 8 | Int(udpData[j + 1]); j += 2
            guard j + n <= udpData.endIndex else { break }
            datagrams.append(Data(udpData[j..<j + n])); j += n
        }
        XCTAssertGreaterThan(datagrams.count, 0)

        // Decrypt everything, keeping arrival order. Apple round-robins one HEVC
        // video across several SSRCs, so all decrypted RTP is fed in order to one
        // manager. Tiled captures exercise the experimental decoder path.
        var rtpStream: [Data] = []
        var decrypted = 0
        for datagram in datagrams {
            guard !RTPDemuxer.isRTCPPacket(datagram), datagram.count >= 12 else { continue }
            for context in contexts {
                if let rtp = try? context.unprotect(datagram) {
                    decrypted += 1
                    rtpStream.append(rtp)
                    break
                }
            }
        }
        guard decrypted > 0 else {
            throw XCTSkip("no SRTP-decryptable streams in capture (is this an encrypted UDP dump?)")
        }

        let frameCount = FrameCounter()
        let manager = VideoStreamManager()
        manager.startStream(streamID: 1, width: 2560, height: 1440) { _, _ in
            frameCount.increment()
        }
        defer { manager.stopStream() }

        var nalTypeCounts: [UInt8: Int] = [:]
        var totalDecodeUnits = 0
        for rtp in rtpStream {
            let result = manager.feedRTPData(rtp)
            for t in result.nalUnitTypes { nalTypeCounts[t, default: 0] += 1 }
            totalDecodeUnits += result.decodedNALUnitCount
        }
        print("nal type counts: \(nalTypeCounts.sorted { $0.key < $1.key }) decodeUnits=\(totalDecodeUnits)")

        // Let asynchronous decodes flush.
        manager.stopStream()
        Thread.sleep(forTimeInterval: 0.5)

        print("replay: \(datagrams.count) datagrams, \(decrypted) decrypted, \(frameCount.value) frames decoded")
        XCTAssertGreaterThan(decrypted, 0, "SRTP should decrypt captured video")
        XCTAssertGreaterThan(frameCount.value, 0, "HEVC decoder should produce frames")
    }

    private final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
