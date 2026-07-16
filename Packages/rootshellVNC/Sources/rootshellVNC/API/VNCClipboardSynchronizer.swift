import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The direction of a completed clipboard transfer.
public enum VNCClipboardTransferDirection: Sendable {
    case deviceToRemote
    case remoteToDevice
}

@MainActor
protocol VNCClipboardProviding: AnyObject {
    var changeCount: Int { get }
    var hasTransferableContent: Bool { get }

    func readTransferableText() -> String?
    func writeText(_ text: String)
}

#if canImport(UIKit)
@MainActor
private final class VNCSystemClipboard: VNCClipboardProviding {
    private let pasteboard = UIPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    var hasTransferableContent: Bool {
        pasteboard.hasStrings || pasteboard.hasURLs
    }

    func readTransferableText() -> String? {
        if let urls = pasteboard.urls, !urls.isEmpty {
            return urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
                .joined(separator: " ")
        }
        return pasteboard.string
    }

    func writeText(_ text: String) {
        pasteboard.string = text
    }
}
#elseif canImport(AppKit)
@MainActor
private final class VNCSystemClipboard: VNCClipboardProviding {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    var hasTransferableContent: Bool {
        pasteboard.canReadObject(
            forClasses: [NSString.self, NSURL.self],
            options: nil)
    }

    func readTransferableText() -> String? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil) as? [URL],
           !urls.isEmpty {
            return urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
                .joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
    }

    func writeText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif

/// Coordinates manual and shared clipboard transfers for one VNC session.
///
/// Shared mode is deliberately session-scoped and starts disabled. Enabling it
/// establishes a baseline without immediately replacing either clipboard; the
/// next local or remote change chooses the initial shared value.
@MainActor
@Observable
public final class VNCClipboardSynchronizer {
    /// Whether subsequent clipboard changes automatically flow both ways.
    public var sharedClipboardEnabled = false {
        didSet {
            guard oldValue != sharedClipboardEnabled else { return }
            needsForegroundReconciliation = false
            establishBaseline()
            if sharedClipboardEnabled, automaticallyMonitors {
                startMonitoring()
                startClipboardObservation()
            } else {
                monitoringTask?.cancel()
                monitoringTask = nil
                stopClipboardObservation()
            }
            if canControlRemoteSharedClipboard() {
                setRemoteSharedClipboard(sharedClipboardEnabled)
            }
        }
    }

    /// Invoked after a transfer is applied locally or queued for the remote.
    /// Hosts can use this for clipboard history without observing clipboard
    /// contents that were merely cached while sharing was inactive.
    @ObservationIgnored
    public var onTransfer: ((VNCClipboardTransferDirection, String) -> Void)?

    public var hasRemoteClipboard: Bool { latestRemoteText != nil }

    /// Whether Get Clipboard can either request the current value from an
    /// Apple server or apply a value already published by a standard server.
    public var canGetClipboard: Bool {
        latestRemoteText != nil || (canSend() && canRequestRemoteClipboard())
    }

    public var canSendClipboard: Bool {
        canSend() && clipboard.hasTransferableContent
    }

    /// Internal visibility for deterministic observer lifecycle tests.
    var isObservingClipboardChanges: Bool {
        clipboardChangeObserver != nil
    }

    @ObservationIgnored
    private let clipboard: any VNCClipboardProviding
    @ObservationIgnored
    private let canSend: () -> Bool
    @ObservationIgnored
    private let send: (String) -> Void
    @ObservationIgnored
    private let canRequestRemoteClipboard: () -> Bool
    @ObservationIgnored
    private let requestRemoteClipboard: () -> Void
    @ObservationIgnored
    private let canControlRemoteSharedClipboard: () -> Bool
    @ObservationIgnored
    private let setRemoteSharedClipboard: (Bool) -> Void
    @ObservationIgnored
    private let notificationCenter: NotificationCenter
    @ObservationIgnored
    private let automaticallyMonitors: Bool
    @ObservationIgnored
    private let clipboardChangeNotification: Notification.Name?
    @ObservationIgnored
    private let clipboardChangeObject: Any?

    @ObservationIgnored
    private weak var session: VNCSession?
    @ObservationIgnored
    private var sessionObserverID: UUID?
    @ObservationIgnored
    private var connectionStateObserverID: UUID?
    @ObservationIgnored
    private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored
    private var clipboardChangeObserver: NSObjectProtocol?
    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?

    private var latestRemoteText: String?
    @ObservationIgnored
    private var pendingManualGet = false
    @ObservationIgnored
    private var remoteGeneration: UInt64 = 0
    @ObservationIgnored
    private var observedLocalChangeCount: Int
    @ObservationIgnored
    private var backgroundLocalChangeCount: Int
    @ObservationIgnored
    private var backgroundRemoteGeneration: UInt64 = 0
    @ObservationIgnored
    private var isApplyingRemoteText = false
    @ObservationIgnored
    private var hostIsFocused = true
    @ObservationIgnored
    private var hostWindowIsActive = true
    @ObservationIgnored
    private var applicationIsActive = true
    @ObservationIgnored
    private var needsForegroundReconciliation = false
    @ObservationIgnored
    private var invalidated = false

    /// Create clipboard synchronization for a VNC session using the platform's
    /// general pasteboard.
    public convenience init(session: VNCSession) {
        let clipboard = VNCSystemClipboard()
        #if canImport(UIKit)
        let clipboardChangeNotification: Notification.Name? =
            UIPasteboard.changedNotification
        let clipboardChangeObject: Any? = UIPasteboard.general
        #else
        let clipboardChangeNotification: Notification.Name? = nil
        let clipboardChangeObject: Any? = nil
        #endif
        self.init(
            clipboard: clipboard,
            canSend: { [weak session] in
                session?.connectionState.isConnected == true
            },
            send: { [weak session] text in
                session?.sendClipboardText(text)
            },
            canRequestRemoteClipboard: { [weak session] in
                session?.connectionState.isConnected == true
                    && session?.supportsRemoteClipboardRequest == true
            },
            requestRemoteClipboard: { [weak session] in
                session?.requestRemoteClipboard()
            },
            canControlRemoteSharedClipboard: { [weak session] in
                session?.connectionState.isConnected == true
                    && session?.supportsRemoteSharedClipboardControl == true
            },
            setRemoteSharedClipboard: { [weak session] enabled in
                session?.setRemoteSharedClipboardEnabled(enabled)
            },
            notificationCenter: .default,
            observesApplicationLifecycle: true,
            automaticallyMonitors: true,
            clipboardChangeNotification: clipboardChangeNotification,
            clipboardChangeObject: clipboardChangeObject
        )
        self.session = session
        self.sessionObserverID = session.addServerClipboardObserver { [weak self] text in
            self?.receiveRemoteClipboardText(text)
        }
        self.connectionStateObserverID = session.addConnectionStateObserver { [weak self] state in
            self?.connectionStateDidChange(state)
        }
        connectionStateDidChange(session.connectionState)
    }

    init(
        clipboard: any VNCClipboardProviding,
        canSend: @escaping () -> Bool,
        send: @escaping (String) -> Void,
        canRequestRemoteClipboard: @escaping () -> Bool = { false },
        requestRemoteClipboard: @escaping () -> Void = {},
        canControlRemoteSharedClipboard: @escaping () -> Bool = { false },
        setRemoteSharedClipboard: @escaping (Bool) -> Void = { _ in },
        notificationCenter: NotificationCenter = .default,
        observesApplicationLifecycle: Bool,
        automaticallyMonitors: Bool,
        clipboardChangeNotification: Notification.Name? = nil,
        clipboardChangeObject: Any? = nil
    ) {
        self.clipboard = clipboard
        self.canSend = canSend
        self.send = send
        self.canRequestRemoteClipboard = canRequestRemoteClipboard
        self.requestRemoteClipboard = requestRemoteClipboard
        self.canControlRemoteSharedClipboard = canControlRemoteSharedClipboard
        self.setRemoteSharedClipboard = setRemoteSharedClipboard
        self.notificationCenter = notificationCenter
        self.automaticallyMonitors = automaticallyMonitors
        self.clipboardChangeNotification = clipboardChangeNotification
        self.clipboardChangeObject = clipboardChangeObject
        self.observedLocalChangeCount = clipboard.changeCount
        self.backgroundLocalChangeCount = clipboard.changeCount

        if observesApplicationLifecycle {
            installLifecycleObservers()
        }
    }

    isolated deinit {
        monitoringTask?.cancel()
        if let clipboardChangeObserver {
            notificationCenter.removeObserver(clipboardChangeObserver)
        }
        for observer in lifecycleObservers {
            notificationCenter.removeObserver(observer)
        }

        if let sessionObserverID {
            session?.removeServerClipboardObserver(sessionObserverID)
        }
        if let connectionStateObserverID {
            session?.removeConnectionStateObserver(connectionStateObserverID)
        }
    }

    /// Send the device's current text or URL clipboard to the remote server.
    public func sendClipboard() {
        guard !invalidated, canSend(),
              let text = clipboard.readTransferableText() else { return }
        observedLocalChangeCount = clipboard.changeCount
        send(text)
        onTransfer?(.deviceToRemote, text)
    }

    /// Request the current clipboard from an Apple server, or put the most
    /// recently published value from a standard VNC server on the device.
    public func getClipboard() {
        guard !invalidated else { return }
        if canSend(), canRequestRemoteClipboard() {
            pendingManualGet = true
            requestRemoteClipboard()
        } else if let latestRemoteText {
            applyRemoteText(latestRemoteText)
        }
    }

    /// Focus participation is separate from application activity: switching
    /// panes must not replay a stale clipboard into a newly focused server.
    public func setHostFocused(_ focused: Bool) {
        guard hostIsFocused != focused else { return }
        hostIsFocused = focused
        if !focused {
            needsForegroundReconciliation = false
        }
        establishBaseline()
    }

    /// Window participation prevents two rootshell windows from sharing the
    /// same device clipboard with different VNC servers at once.
    public func setHostWindowActive(_ active: Bool) {
        guard hostWindowIsActive != active else { return }
        hostWindowIsActive = active

        if active, needsForegroundReconciliation {
            reconcileAfterForegroundIfPossible()
        } else if applicationIsActive {
            // This is an in-app window switch, not an app foreground. Start
            // fresh so the previously active server is never bridged here.
            needsForegroundReconciliation = false
            establishBaseline()
        }
    }

    /// Remove observers and stop polling. Safe to call more than once.
    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        monitoringTask?.cancel()
        monitoringTask = nil
        stopClipboardObservation()
        for observer in lifecycleObservers {
            notificationCenter.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        if let sessionObserverID {
            session?.removeServerClipboardObserver(sessionObserverID)
        }
        if let connectionStateObserverID {
            session?.removeConnectionStateObserver(connectionStateObserverID)
        }
        sessionObserverID = nil
        connectionStateObserverID = nil
        session = nil
    }

    func receiveRemoteClipboardText(_ text: String) {
        guard !invalidated else { return }
        latestRemoteText = text
        remoteGeneration &+= 1

        if pendingManualGet {
            pendingManualGet = false
            applyRemoteText(text)
            return
        }

        guard sharedClipboardEnabled, isEligible else { return }
        applyRemoteText(text)
    }

    func localClipboardDidChange() {
        guard !invalidated else { return }
        let currentChangeCount = clipboard.changeCount
        guard currentChangeCount != observedLocalChangeCount else { return }

        if isApplyingRemoteText || !sharedClipboardEnabled || !isEligible {
            // Changes made by us, while sharing is disabled, or while another
            // pane/window owns focus must never be replayed later.
            observedLocalChangeCount = currentChangeCount
            return
        }

        // Keep the change unacknowledged while reconnecting. The connection
        // observer retries it immediately after the session is operational,
        // and polling remains a fallback for custom transports.
        guard canSend() else { return }
        guard let text = clipboard.readTransferableText() else {
            // The shared clipboard intentionally supports text and URLs only.
            observedLocalChangeCount = currentChangeCount
            return
        }

        observedLocalChangeCount = currentChangeCount
        send(text)
        onTransfer?(.deviceToRemote, text)
    }

    func connectionStateDidChange(_ state: VNCConnectionState) {
        guard !invalidated else { return }

        switch state {
        case .connected:
            if sharedClipboardEnabled, canControlRemoteSharedClipboard() {
                setRemoteSharedClipboard(true)
            }
            // Flush a local change retained during automatic reconnect.
            localClipboardDidChange()
        case .reconnecting:
            clearRemoteCache()
            // Do not establish a local baseline: local changes must remain
            // pending until this same connection comes back.
        case .connecting:
            clearRemoteCache()
            // A fresh connect may target another server. Never bridge local
            // changes accumulated while the prior connection was closed.
            establishBaseline()
        case .idle, .disconnecting, .disconnected, .failed:
            clearRemoteCache()
        }
    }

    func applicationWillResignActive() {
        guard applicationIsActive else { return }
        applicationIsActive = false
        backgroundLocalChangeCount = clipboard.changeCount
        backgroundRemoteGeneration = remoteGeneration
        needsForegroundReconciliation = true
    }

    func applicationDidBecomeActive() {
        applicationIsActive = true
        reconcileAfterForegroundIfPossible()
    }

    private var isEligible: Bool {
        hostIsFocused && hostWindowIsActive && applicationIsActive
    }

    private func applyRemoteText(_ text: String) {
        isApplyingRemoteText = true
        clipboard.writeText(text)
        observedLocalChangeCount = clipboard.changeCount
        isApplyingRemoteText = false
        onTransfer?(.remoteToDevice, text)
    }

    private func establishBaseline() {
        observedLocalChangeCount = clipboard.changeCount
        backgroundLocalChangeCount = clipboard.changeCount
        backgroundRemoteGeneration = remoteGeneration
    }

    private func reconcileAfterForegroundIfPossible() {
        guard needsForegroundReconciliation,
              sharedClipboardEnabled,
              applicationIsActive,
              hostIsFocused,
              hostWindowIsActive else { return }
        needsForegroundReconciliation = false

        let localChanged = clipboard.changeCount != backgroundLocalChangeCount
        let remoteChanged = remoteGeneration != backgroundRemoteGeneration
        if localChanged {
            sendClipboard()
        } else if remoteChanged, let latestRemoteText {
            applyRemoteText(latestRemoteText)
        } else {
            establishBaseline()
        }
    }

    private func startMonitoring() {
        guard monitoringTask == nil, !invalidated else { return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard let self else { return }
                self.localClipboardDidChange()
            }
        }
    }

    /// Observe pasteboard changes only while automatic sharing is enabled.
    /// NotificationCenter delivers observers registered on a specific queue
    /// synchronously. Using the posting queue here is essential: Ghostty can
    /// mutate the pasteboard from its surface API queue while holding the
    /// surface mutex, so waiting for `.main` would deadlock with main-thread
    /// surface queries. The callback itself only enqueues MainActor work.
    private func startClipboardObservation() {
        guard clipboardChangeObserver == nil,
              !invalidated,
              let clipboardChangeNotification else { return }

        clipboardChangeObserver = notificationCenter.addObserver(
            forName: clipboardChangeNotification,
            object: clipboardChangeObject,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.localClipboardDidChange()
            }
        }
    }

    private func stopClipboardObservation() {
        guard let clipboardChangeObserver else { return }
        notificationCenter.removeObserver(clipboardChangeObserver)
        self.clipboardChangeObserver = nil
    }

    private func clearRemoteCache() {
        latestRemoteText = nil
        pendingManualGet = false
        // Treat the boundary as a generation change so pending foreground
        // reconciliation cannot apply clipboard data from the prior server.
        remoteGeneration &+= 1
    }

    private func installLifecycleObservers() {
        #if canImport(UIKit)
        applicationIsActive = UIApplication.shared.applicationState == .active
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationWillResignActive()
            }
        })
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationDidBecomeActive()
            }
        })
        #elseif canImport(AppKit)
        applicationIsActive = NSApplication.shared.isActive
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationWillResignActive()
            }
        })
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationDidBecomeActive()
            }
        })
        #endif
    }
}
