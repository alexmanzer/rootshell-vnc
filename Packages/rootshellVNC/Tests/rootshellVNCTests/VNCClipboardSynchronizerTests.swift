import XCTest
@testable import rootshellVNC

@MainActor
final class VNCClipboardSynchronizerTests: XCTestCase {
    private final class FakeClipboard: VNCClipboardProviding {
        var changeCount = 0
        var text: String?

        var hasTransferableContent: Bool { text != nil }

        func readTransferableText() -> String? { text }

        func writeText(_ text: String) {
            self.text = text
            changeCount += 1
        }

        func copyOnDevice(_ text: String?) {
            self.text = text
            changeCount += 1
        }
    }

    private func makeSynchronizer(
        clipboard: FakeClipboard,
        connected: @escaping () -> Bool = { true },
        automaticallyMonitors: Bool = false,
        send: @escaping (String) -> Void
    ) -> VNCClipboardSynchronizer {
        VNCClipboardSynchronizer(
            clipboard: clipboard,
            canSend: connected,
            send: send,
            notificationCenter: NotificationCenter(),
            observesApplicationLifecycle: false,
            automaticallyMonitors: automaticallyMonitors)
    }

    func testManualGetUsesLatestRemoteClipboardWhileSharingIsOff() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }

        synchronizer.receiveRemoteClipboardText("remote value")

        XCTAssertTrue(synchronizer.hasRemoteClipboard)
        XCTAssertNil(clipboard.text)

        synchronizer.getClipboard()

        XCTAssertEqual(clipboard.text, "remote value")
        XCTAssertTrue(sent.isEmpty)
    }

    func testManualGetCanClearTheDeviceClipboard() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("old value")
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }

        synchronizer.receiveRemoteClipboardText("")
        synchronizer.getClipboard()

        XCTAssertEqual(clipboard.text, "")
    }

    func testManualSendRequiresConnectionAndClipboardContent() {
        let clipboard = FakeClipboard()
        var connected = false
        var sent: [String] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            connected: { connected }
        ) { sent.append($0) }

        synchronizer.sendClipboard()
        clipboard.copyOnDevice("device value")
        synchronizer.sendClipboard()
        XCTAssertTrue(sent.isEmpty)

        connected = true
        synchronizer.sendClipboard()
        XCTAssertEqual(sent, ["device value"])
    }

    func testEnablingSharedClipboardWaitsForNextChange() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("existing local")
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.receiveRemoteClipboardText("existing remote")

        synchronizer.sharedClipboardEnabled = true

        XCTAssertEqual(clipboard.text, "existing local")
        XCTAssertTrue(sent.isEmpty)
    }

    func testSharedClipboardTransfersBothDirectionsWithoutEcho() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.receiveRemoteClipboardText("from remote")
        synchronizer.localClipboardDidChange()

        XCTAssertEqual(clipboard.text, "from remote")
        XCTAssertTrue(sent.isEmpty, "A remote pasteboard write must not echo back")

        clipboard.copyOnDevice("from device")
        synchronizer.localClipboardDidChange()

        XCTAssertEqual(sent, ["from device"])
    }

    func testLocalChangeDuringReconnectIsRetriedWhenConnected() {
        let clipboard = FakeClipboard()
        var connected = false
        var sent: [String] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            connected: { connected }
        ) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.connectionStateDidChange(.reconnecting(attempt: 1, delay: 0))
        clipboard.copyOnDevice("copied while reconnecting")
        synchronizer.localClipboardDidChange()
        XCTAssertTrue(sent.isEmpty)

        connected = true
        synchronizer.connectionStateDidChange(.connected)

        XCTAssertEqual(sent, ["copied while reconnecting"])
    }

    func testConnectionBoundaryClearsCachedRemoteClipboard() {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        synchronizer.receiveRemoteClipboardText("clipboard from first server")
        XCTAssertTrue(synchronizer.hasRemoteClipboard)

        synchronizer.connectionStateDidChange(.connecting)

        XCTAssertFalse(synchronizer.hasRemoteClipboard)
        synchronizer.getClipboard()
        XCTAssertNil(clipboard.text)
    }

    func testUnfocusedPaneCachesWithoutReplayingOrBridging() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true
        synchronizer.setHostFocused(false)

        synchronizer.receiveRemoteClipboardText("inactive remote")
        clipboard.copyOnDevice("active pane value")
        synchronizer.localClipboardDidChange()

        synchronizer.setHostFocused(true)

        XCTAssertEqual(clipboard.text, "active pane value")
        XCTAssertTrue(sent.isEmpty)

        synchronizer.receiveRemoteClipboardText("new focused remote")
        XCTAssertEqual(clipboard.text, "new focused remote")
    }

    func testForegroundLocalChangeWinsOverRemoteChange() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        synchronizer.receiveRemoteClipboardText("background remote")
        clipboard.copyOnDevice("external local")
        synchronizer.applicationDidBecomeActive()

        XCTAssertEqual(sent, ["external local"])
        XCTAssertEqual(clipboard.text, "external local")
    }

    func testForegroundAppliesRemoteWhenLocalClipboardDidNotChange() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("unchanged local")
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        synchronizer.receiveRemoteClipboardText("background remote")
        synchronizer.applicationDidBecomeActive()

        XCTAssertEqual(clipboard.text, "background remote")
        XCTAssertTrue(sent.isEmpty)
    }

    func testInactiveWindowDefersForegroundReconciliation() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        synchronizer.setHostWindowActive(false)
        clipboard.copyOnDevice("external local")
        synchronizer.applicationDidBecomeActive()

        XCTAssertTrue(sent.isEmpty)

        synchronizer.setHostWindowActive(true)
        XCTAssertEqual(sent, ["external local"])
    }

    func testWindowActivationBeforeApplicationActivationDoesNotReconcileEarly() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        synchronizer.setHostWindowActive(false)
        clipboard.copyOnDevice("first background value")
        synchronizer.setHostWindowActive(true)

        XCTAssertTrue(sent.isEmpty)

        clipboard.copyOnDevice("latest background value")
        synchronizer.applicationDidBecomeActive()

        XCTAssertEqual(sent, ["latest background value"])
    }

    func testMonitoringDoesNotRetainSynchronizer() async {
        let clipboard = FakeClipboard()
        weak var weakSynchronizer: VNCClipboardSynchronizer?

        do {
            let synchronizer = makeSynchronizer(
                clipboard: clipboard,
                automaticallyMonitors: true
            ) { _ in }
            synchronizer.sharedClipboardEnabled = true
            weakSynchronizer = synchronizer
        }

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(weakSynchronizer)
    }

    func testTransferCallbackOnlyReportsAppliedTransfers() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("device")
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        var transfers: [(VNCClipboardTransferDirection, String)] = []
        synchronizer.onTransfer = { transfers.append(($0, $1)) }

        synchronizer.receiveRemoteClipboardText("cached")
        XCTAssertTrue(transfers.isEmpty)

        synchronizer.getClipboard()
        clipboard.copyOnDevice("sent")
        synchronizer.sendClipboard()

        XCTAssertEqual(transfers.count, 2)
        XCTAssertEqual(transfers[0].1, "cached")
        XCTAssertEqual(transfers[1].1, "sent")
    }
}
