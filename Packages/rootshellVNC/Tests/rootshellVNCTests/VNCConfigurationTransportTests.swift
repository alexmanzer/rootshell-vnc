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

/// Successful in-memory RFB 3.8 connection used to exercise session-level
/// reconnects without exposing or persisting credentials in the test.
private actor SuccessfulRFBConnection: RFBConnection {
    private var serverBytes: Data
    private var readOffset = 0
    private var closed = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(name: String) {
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(width: 1024, height: 768, name: name))
        self.serverBytes = script
    }

    func connect() async throws {
        if closed { throw VNCProtocolError.connectionClosed }
    }

    func read(exactly count: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            if serverBytes.count - readOffset >= count {
                return consume(count)
            }
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    func read(upTo maxCount: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            let available = serverBytes.count - readOffset
            if available > 0 { return consume(min(available, maxCount)) }
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    func send(_ data: Data) async throws {
        if closed { throw VNCProtocolError.connectionClosed }
    }

    func close() {
        closed = true
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {}

    func enqueueServerBytes(_ data: Data) {
        serverBytes.append(data)
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func consume(_ count: Int) -> Data {
        let start = serverBytes.startIndex + readOffset
        let result = serverBytes.subdata(in: start..<(start + count))
        readOffset += count
        return result
    }

    private nonisolated static func serverInitMessage(
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
}

private final class SuccessfulProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(host: String, port: UInt16)] = []

    func makeConnection(host: String, port: UInt16) -> any RFBConnection {
        lock.lock()
        calls.append((host, port))
        let attempt = calls.count
        lock.unlock()
        return SuccessfulRFBConnection(name: "attempt-\(attempt)")
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

    @MainActor
    func testSessionPublishesAndClearsNegotiatedContentEncryption() async throws {
        let connection = SuccessfulRFBConnection(name: "encryption-state")
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)
        var encryptionAtConnected: VNCContentEncryption?
        let observerID = session.addConnectionStateObserver { state in
            if state.isConnected {
                encryptionAtConnected = session.negotiatedContentEncryption
            }
        }

        XCTAssertNil(session.negotiatedContentEncryption)
        try await session.connect(credentials: VNCCredentials(
            host: "plain.test",
            port: 5900,
            password: ""))

        let published = await waitUntil {
            session.negotiatedContentEncryption == VNCContentEncryption.none
        }
        XCTAssertTrue(published)
        XCTAssertEqual(encryptionAtConnected, VNCContentEncryption.none)

        session.removeConnectionStateObserver(observerID)
        session.disconnect()
        XCTAssertNil(session.negotiatedContentEncryption)
    }

    @MainActor
    func testSessionPublishesAppleLoginPromptFromDisplayInfo2() async throws {
        let connection = SuccessfulRFBConnection(name: "apple-login")
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            promptForLoginPasswordAtLoginWindow: true,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)

        try await session.connect(credentials: VNCCredentials(
            host: "apple.test",
            port: 5900,
            password: "secret"))
        let connected = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(connected)

        await connection.enqueueServerBytes(
            Self.appleLoginFramebufferUpdate(screenFlags: 0x10))
        let prompted = await waitUntil {
            session.loginPasswordPromptPending
        }
        XCTAssertTrue(prompted)
        XCTAssertTrue(session.consumeLoginPasswordPromptRequest())
        XCTAssertFalse(session.consumeLoginPasswordPromptRequest())
        session.disconnect()
    }

    @MainActor
    func testReconnectAppliesConfigurationAndRetainsActiveCredentials() async throws {
        let recorder = SuccessfulProviderRecorder()
        var configuration = VNCConfiguration(
            videoQualityMode: .fullQuality,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { host, port in
            recorder.makeConnection(host: host, port: port)
        }

        let session = VNCSession(configuration: configuration)
        try await session.connect(credentials: VNCCredentials(
            host: "vnc.internal",
            port: 5901,
            password: "secret"))
        let initiallyConnected = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(initiallyConnected)

        // Model the negotiated state left by the High Performance transport
        // that the HUD is replacing with Standard mode.
        session.isHighPerformanceMode = true

        var replacement = session.configuration
        replacement.videoQualityMode = .standard
        XCTAssertTrue(session.reconnect(with: replacement))
        XCTAssertFalse(session.reconnect(with: replacement))

        let reconnected = await waitUntil {
            recorder.recorded.count == 2 && session.connectionState.isConnected
        }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(session.configuration.videoQualityMode, .standard)
        XCTAssertFalse(session.isHighPerformanceMode)
        XCTAssertEqual(recorder.recorded.map(\.host), ["vnc.internal", "vnc.internal"])
        XCTAssertEqual(recorder.recorded.map(\.port), [5901, 5901])

        session.disconnect()
    }

    private static func appleLoginFramebufferUpdate(
        screenFlags: UInt32
    ) -> Data {
        var payload = Data(repeating: 0, count: 20)
        payload[0] = 0
        payload[1] = 18
        payload[2] = 0
        payload[3] = 5
        payload[16] = UInt8((screenFlags >> 24) & 0xff)
        payload[17] = UInt8((screenFlags >> 16) & 0xff)
        payload[18] = UInt8((screenFlags >> 8) & 0xff)
        payload[19] = UInt8(screenFlags & 0xff)

        var update = Data([0, 0, 0, 1])
        update.append(contentsOf: [
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 4, 81,
        ])
        update.append(payload)
        return update
    }

    @MainActor
    func testReconnectRejectsIdleSessionWithoutChangingConfiguration() {
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .standard))
        var replacement = session.configuration
        replacement.videoQualityMode = .fullQuality

        XCTAssertFalse(session.reconnect(with: replacement))
        XCTAssertEqual(session.configuration.videoQualityMode, .standard)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
