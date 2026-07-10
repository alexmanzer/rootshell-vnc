import Compression
import Foundation
import XCTest
@testable import RFBTransport

final class AppleMediaNegotiationTests: XCTestCase {
    func testMediaMessageOneAnswerCyclesCreateDistinctGenerations() {
        var tracker = AppleMediaNegotiationGenerationTracker()

        XCTAssertEqual(
            tracker.beginMessageOne(),
            .init(generation: 1, isReconfiguration: false))
        XCTAssertNil(tracker.beginMessageOne())
        XCTAssertTrue(tracker.finishMessageTwo())
        XCTAssertFalse(tracker.finishMessageTwo())

        XCTAssertEqual(
            tracker.beginMessageOne(),
            .init(generation: 2, isReconfiguration: true))
        XCTAssertTrue(tracker.isAwaitingAnswer)
    }

    func testScreenBlobCarriesFreshSessionIdentityAndNamedCapabilities() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 2940,
            framebufferHeight: 1860,
            supportsHDR: false
        )
        let timestamp: UInt64 = 0x1122_3344_5566_7788
        let blob = profile.mediaBlob(
            kind: .screen,
            ssrc: 0xa1b2_c3d4,
            ntpTimestamp: timestamp
        )
        let root = try ProtoMessage(blob)

        XCTAssertEqual(root.varint(1), 1) // allowDynamicMaxBitrate
        XCTAssertEqual(root.varint(2), 1) // content-preserving resize
        XCTAssertEqual(root.string(6), "Viceroy 1.7.0")
        XCTAssertEqual(root.varint(13), timestamp)
        XCTAssertEqual(root.varint(14), 2)
        XCTAssertEqual(root.varint(16), 0)
        XCTAssertEqual(root.varint(18), 1)
        XCTAssertEqual(root.messages(9).count, 10)

        let screen = try XCTUnwrap(root.message(5))
        XCTAssertEqual(screen.varint(1), 0xa1b2_c3d4)
        XCTAssertEqual(screen.varint(2), 0)
        // Public VideoToolbox consumes the conventional one-image reference
        // timeline. Apple's tiled decoder contract is private and is not
        // advertised by default.
        XCTAssertEqual(screen.varint(6), 1)
        XCTAssertEqual(screen.varint(7), 1)
        XCTAssertEqual(screen.varint(8), 63)
        XCTAssertEqual(screen.varint(9), 1)
        XCTAssertEqual(screen.varint(12), 1)

        let payloads = screen.messages(3)
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].varint(1), 123)
        XCTAssertEqual(payloads[0].messages(2).count, 4)
        XCTAssertTrue(payloads[0].string(3)?.contains("AR:16/9,5/8;") == true)
        XCTAssertTrue(payloads[0].string(3)?.contains("XR:16/9,5/8;") == true)
        XCTAssertEqual(payloads[1].varint(1), 100)
        XCTAssertEqual(payloads[1].messages(2).count, 2)
    }

    func testHDRServerCapabilityChangesAdvertisedHDRBitmap() throws {
        let sdr = AppleMediaNegotiationProfile(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            supportsHDR: false
        )
        let hdr = AppleMediaNegotiationProfile(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            supportsHDR: true
        )
        let sdrScreen = try XCTUnwrap(ProtoMessage(sdr.mediaBlob(
            kind: .screen,
            ssrc: 1,
            ntpTimestamp: 2
        )).message(5))
        let hdrScreen = try XCTUnwrap(ProtoMessage(hdr.mediaBlob(
            kind: .screen,
            ssrc: 1,
            ntpTimestamp: 2
        )).message(5))

        XCTAssertEqual(sdrScreen.varint(9), 1)
        XCTAssertEqual(hdrScreen.varint(9), 9)
    }

    func testScreenNegotiationAlwaysAdvertisesLogicalLocalTransport() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 2556,
            framebufferHeight: 1179,
            supportsHDR: false)
        let root = try ProtoMessage(profile.mediaBlob(
            kind: .screen,
            ssrc: 1,
            ntpTimestamp: 2))

        XCTAssertEqual(root.varint(18), 1)
        let screen = try XCTUnwrap(root.message(5))
        for payload in screen.messages(3) {
            for rule in payload.messages(2) {
                XCTAssertEqual(rule.varint(1), 1)
            }
        }
    }

    func testPrivateAndOverlayHostDetection() {
        XCTAssertTrue(AppleMediaNetworkProfile.isPrivateOrOverlayHost("192.168.58.66"))
        XCTAssertTrue(AppleMediaNetworkProfile.isPrivateOrOverlayHost("100.100.20.30"))
        XCTAssertTrue(AppleMediaNetworkProfile.isPrivateOrOverlayHost("mac.tail123.ts.net"))
        XCTAssertFalse(AppleMediaNetworkProfile.isPrivateOrOverlayHost("203.0.113.8"))
    }

    func testCellularVPNUsesConservativeCapacityPriorWithoutChangingNegotiation() {
        let profile = AppleMediaNetworkProfile.detect(
            from: NetworkPathCharacteristics(
                interface: .cellular,
                usesOtherInterface: true,
                isExpensive: true,
                isConstrained: false),
            remoteHost: "mac.tail123.ts.net")

        XCTAssertEqual(profile.initialCapacityBps, 6_000_000)
        XCTAssertTrue(profile.name.hasSuffix("over private/VPN"))
    }

    func testAudioBlobCarriesAudioSettingsInsteadOfScreenSettings() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 2048,
            framebufferHeight: 1536,
            supportsHDR: false
        )
        let root = try ProtoMessage(profile.mediaBlob(
            kind: .audio,
            ssrc: 0x1234_5678,
            ntpTimestamp: 9
        ))
        let audio = try XCTUnwrap(root.message(3))

        XCTAssertNil(try root.message(5))
        XCTAssertEqual(audio.varint(1), 0x1234_5678)
        XCTAssertEqual(audio.varint(2), 0)
        XCTAssertEqual(audio.varint(3), 0)
        XCTAssertEqual(audio.varint(4), 24_191)
        XCTAssertEqual(audio.varint(5), 0)
        XCTAssertEqual(audio.varint(6), 0)
    }

    func testOfferIsBinaryPlistWithValidCompressedProtobufAndEndpoint() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 1920,
            framebufferHeight: 1200,
            supportsHDR: false
        )
        let endpoint = AppleMediaNegotiationProfile.Endpoint(
            productIdentifier: "iPad99,1",
            mediaSoftwareVersion: "42",
            operatingSystemBuild: "99A1"
        )
        let callID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let offer = try profile.makeOffer(
            kind: .screen,
            mode: 7,
            ssrc: 7,
            ntpTimestamp: 8,
            callID: callID,
            endpoint: endpoint
        )
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: offer, options: [], format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(plist["avcMediaStreamNegotiatorMode"] as? Int, 7)
        XCTAssertEqual(
            plist["avcMediaStreamOptionCallID"] as? String,
            callID.uuidString
        )
        let compressed = try XCTUnwrap(plist["avcMediaStreamNegotiatorMediaBlob"] as? Data)
        XCTAssertEqual(compressed.prefix(2), Data([0x78, 0xda]))
        XCTAssertGreaterThan(compressed.count, 6)
        let decoded = try ProtoMessage(zlibDecompress(compressed))
        XCTAssertEqual(decoded.varint(13), 8)
        XCTAssertEqual(try decoded.message(5)?.varint(1), 7)

        let endpointMessage = try ProtoMessage(XCTUnwrap(
            plist["avcMediaStreamOptionRemoteEndpointInfo"] as? Data
        ))
        XCTAssertEqual(endpointMessage.varint(1), 0)
        XCTAssertEqual(endpointMessage.varint(2), 1)
        XCTAssertEqual(endpointMessage.string(3), "iPad99,1")
        XCTAssertEqual(endpointMessage.string(4), "42")
        XCTAssertEqual(endpointMessage.string(5), "99A1")
    }

    func testNativeCodecAspectCapabilitiesDoNotTrackFramebufferShape() {
        let ipad = AppleMediaNegotiationProfile(
            framebufferWidth: 2732,
            framebufferHeight: 2048,
            supportsHDR: false)
        let wide = AppleMediaNegotiationProfile(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            supportsHDR: false)

        XCTAssertEqual(ipad.aspectRatio, .screenCodec)
        XCTAssertEqual(wide.aspectRatio, .screenCodec)
        XCTAssertEqual(ipad.aspectRatio.featureListValue, "16/9,5/8")
    }

    func testNTPConversion() {
        XCTAssertEqual(
            AppleMediaNegotiationProfile.ntpTimestamp(for: Date(timeIntervalSince1970: 0)),
            UInt64(2_208_988_800) << 32
        )
    }
}

private struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private var fields: [UInt64: [Value]] = [:]

    init(_ data: Data) throws {
        var index = data.startIndex
        while index < data.endIndex {
            let key = try Self.readVarint(data, index: &index)
            let field = key >> 3
            switch key & 0x07 {
            case 0:
                fields[field, default: []].append(.varint(
                    try Self.readVarint(data, index: &index)
                ))
            case 2:
                let length = try Self.readVarint(data, index: &index)
                guard length <= UInt64(data.distance(from: index, to: data.endIndex)),
                      let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) else {
                    throw ProtoError.truncated
                }
                fields[field, default: []].append(.bytes(Data(data[index..<end])))
                index = end
            default:
                throw ProtoError.unsupportedWireType
            }
        }
    }

    func varint(_ field: UInt64) -> UInt64? {
        guard case .varint(let value)? = fields[field]?.first else { return nil }
        return value
    }

    func string(_ field: UInt64) -> String? {
        guard case .bytes(let value)? = fields[field]?.first else { return nil }
        return String(data: value, encoding: .utf8)
    }

    func message(_ field: UInt64) throws -> ProtoMessage? {
        guard case .bytes(let value)? = fields[field]?.first else { return nil }
        return try ProtoMessage(value)
    }

    func messages(_ field: UInt64) -> [ProtoMessage] {
        (fields[field] ?? []).compactMap {
            guard case .bytes(let value) = $0 else { return nil }
            return try? ProtoMessage(value)
        }
    }

    private static func readVarint(_ data: Data, index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoError.truncated
    }
}

private enum ProtoError: Error {
    case truncated
    case unsupportedWireType
    case decompressionFailed
}

private func zlibDecompress(_ input: Data) throws -> Data {
    guard input.count > 6, input.prefix(2) == Data([0x78, 0xda]) else {
        throw ProtoError.decompressionFailed
    }
    // `Compression` consumes raw DEFLATE; strip the RFC 1950 header/checksum.
    let deflate = Data(input.dropFirst(2).dropLast(4))
    var capacity = 1024
    while capacity <= 1_048_576 {
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outputBytes in
            deflate.withUnsafeBytes { inputBytes in
                compression_decode_buffer(
                    outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    deflate.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        if written > 0 {
            output.count = written
            return output
        }
        capacity *= 2
    }
    throw ProtoError.decompressionFailed
}
