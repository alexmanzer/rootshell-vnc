import XCTest
import RFBProtocol
import RFBTransport
@testable import rootshellVNC

/// Minimal transport stub: dialing succeeds at the provider level and the
/// connection itself fails on connect, so session tests can observe provider
/// invocation without any network.
private struct StubTransportConnection: RFBConnection {
    func connect() async throws {
        throw VNCProtocolError.ioError("stub transport dial")
    }
    func read(exactly count: Int) async throws -> Data {
        throw VNCProtocolError.connectionClosed
    }
    func read(upTo maxCount: Int) async throws -> Data {
        throw VNCProtocolError.connectionClosed
    }
    func send(_ data: Data) async throws {}
    func close() async {}
    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {}
}

/// Records provider invocations across concurrency domains.
private final class ProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(host: String, port: UInt16)] = []

    func record(host: String, port: UInt16) {
        lock.lock()
        calls.append((host, port))
        lock.unlock()
    }

    var recorded: [(host: String, port: UInt16)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

final class VNCConfigurationTransportTests: XCTestCase {

    private static let stubProvider: VNCTransportProvider = { _, _ in
        StubTransportConnection()
    }

    func testInstallingProviderClampsAdaptiveToStandard() {
        var configuration = VNCConfiguration()
        XCTAssertEqual(configuration.videoQualityMode, .adaptive)
        XCTAssertEqual(configuration.displaySizingMode, .matchClient)

        configuration.transportProvider = Self.stubProvider

        XCTAssertEqual(configuration.videoQualityMode, .standard)
        // The quality clamp must run the existing mode couplings too.
        XCTAssertEqual(configuration.displaySizingMode, .remoteDisplay)
    }

    func testSelectingAdaptiveRevertsWhileProviderInstalled() {
        var configuration = VNCConfiguration(videoQualityMode: .standard)
        configuration.transportProvider = Self.stubProvider

        configuration.videoQualityMode = .adaptive

        XCTAssertEqual(configuration.videoQualityMode, .standard)
    }

    func testInitClampsAdaptiveWhenProviderSupplied() {
        let configuration = VNCConfiguration(
            videoQualityMode: .adaptive,
            transportProvider: Self.stubProvider)

        XCTAssertEqual(configuration.videoQualityMode, .standard)
        XCTAssertEqual(configuration.displaySizingMode, .remoteDisplay)
    }

    func testAvailableVideoQualityModesExcludeAdaptiveOverCustomTransport() {
        var configuration = VNCConfiguration()
        XCTAssertEqual(
            configuration.availableVideoQualityModes,
            VNCConfiguration.VideoQualityMode.allCases)

        configuration.transportProvider = Self.stubProvider
        XCTAssertEqual(
            configuration.availableVideoQualityModes,
            [.standard, .fullQuality])

        // Removing the provider restores the direct-transport choices.
        configuration.transportProvider = nil
        XCTAssertEqual(
            configuration.availableVideoQualityModes,
            VNCConfiguration.VideoQualityMode.allCases)
    }

    @MainActor
    func testSessionInvokesProviderWithCredentialsHostAndPort() async {
        let recorder = ProviderRecorder()
        var configuration = VNCConfiguration()
        configuration.transportProvider = { host, port in
            recorder.record(host: host, port: port)
            return StubTransportConnection()
        }

        let session = VNCSession(configuration: configuration)
        do {
            try await session.connect(credentials: VNCCredentials(
                host: "vnc.internal",
                port: 5901,
                password: "secret"))
            XCTFail("Expected connect to surface the stub transport failure")
        } catch let error as VNCError {
            guard case .connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let calls = recorder.recorded
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.host, "vnc.internal")
        XCTAssertEqual(calls.first?.port, 5901)
    }
}
