//
//  ContentView.swift
//  rootshell-vnc
//
//  Created by Kit Knox on 3/17/26.
//

import SwiftUI
import rootshellVNC

#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = VNCSession()
    @State private var isFullScreen = false
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var backgroundTimeExtension = BackgroundTimeExtension()
    #endif

    var body: some View {
        Group {
            if session.connectionState.isConnected, isFullScreen {
                // A hidden navigation bar still reserves its container's safe
                // area on iPad. Remove the NavigationStack from the hierarchy
                // entirely so the framebuffer owns the physical screen.
                remoteDesktop
            } else {
                NavigationStack {
                    standardContent
                }
            }
        }
        #if os(iOS)
        // `persistentSystemOverlays` does not consistently own the iPad status
        // bar when the content lives inside a NavigationStack. Apply the
        // explicit preference at the stack/scene boundary so the clock, Wi-Fi,
        // and battery indicators cannot remain over the remote desktop.
        .statusBarHidden(isFullScreen)
        #endif
        .task { await autoConnectIfRequested() }
        .onChange(of: scenePhase) { _, newPhase in
            #if os(iOS) && !targetEnvironment(macCatalyst)
            updateBackgroundTimeExtension(for: newPhase)
            #endif
        }
        .onChange(of: session.connectionState) { _, newState in
            #if os(iOS) && !targetEnvironment(macCatalyst)
            updateBackgroundTimeExtension(for: scenePhase)

            // Arm full screen while the connection is still negotiating. That
            // way the first connected RemoteDesktopView is created directly
            // in the full-screen hierarchy and can never publish the smaller
            // NavigationStack geometry as the active client display size.
            if newState.isConnecting || newState.isConnected {
                enterFullScreen()
            } else if isFullScreen {
                exitFullScreen()
            }
            #else
            if !newState.isConnected, !newState.isConnecting, isFullScreen {
                exitFullScreen()
            }
            #endif
        }
        #if targetEnvironment(macCatalyst)
        // Catalyst posts the AppKit window notifications through the default
        // notification center. Observing both keeps the viewer in sync when
        // full screen is changed with the green button, the View menu, or Esc.
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("NSWindowWillEnterFullScreenNotification")
        )) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("NSWindowDidExitFullScreenNotification")
        )) { _ in
            isFullScreen = false
        }
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private func updateBackgroundTimeExtension(for phase: ScenePhase) {
        let needsConnectionTime = session.connectionState.isConnecting
            || session.connectionState.isConnected

        // Acquire the assertion as soon as the scene becomes inactive. Waiting
        // for `.background` leaves a small unprotected window in which active
        // sockets can already fail and change the session to a disconnected
        // state, preventing the request from ever being made.
        if phase != .active, needsConnectionTime {
            backgroundTimeExtension.begin()
        } else if phase == .active {
            // Once acquired, keep the assertion through transient connection
            // state changes so reconnect work remains eligible to run.
            backgroundTimeExtension.end()
        }
    }
    #endif

    @ViewBuilder
    private var standardContent: some View {
        switch session.connectionState {
        case .idle, .disconnected:
            ConnectionView(session: session)
        case .connecting:
            VStack(spacing: 16) {
                ProgressView()
                Text("Connecting...")
                    .foregroundStyle(.secondary)
            }
        case .connected, .reconnecting:
            remoteDesktop
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(session.serverName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") {
                            session.disconnect()
                        }
                    }
                }
        case .disconnecting:
            VStack(spacing: 16) {
                ProgressView()
                Text("Disconnecting...")
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Connection Failed")
                    .font(.headline)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    session.retryConnection()
                    // Initial connection failures intentionally discard their
                    // credentials, so return to the form when there is no
                    // established session available to retry.
                    if case .failed = session.connectionState {
                        session.connectionState = .idle
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var remoteDesktop: some View {
        RemoteDesktopView(
            session: session,
            isFullScreen: isFullScreen,
            toggleFullScreen: toggleFullScreen)
            // RemoteDesktopView applies its own dock-aware keyboard inset.
            // Ignore the system regions here so SwiftUI does not reserve a
            // full keyboard-sized area for a detached iPad keyboard.
            .ignoresSafeArea(isFullScreen ? .all : .keyboard)
            .persistentSystemOverlays(isFullScreen ? .hidden : .automatic)
            .animation(.easeInOut(duration: 0.2), value: isFullScreen)
    }

    private func toggleFullScreen() {
        isFullScreen ? exitFullScreen() : enterFullScreen()
    }

    private func enterFullScreen() {
        guard !isFullScreen else { return }
        #if targetEnvironment(macCatalyst)
        isFullScreen = true
        if !toggleCatalystFullScreen() {
            isFullScreen = false
        }
        #else
        isFullScreen = true
        #endif
    }

    private func exitFullScreen() {
        guard isFullScreen else { return }
        #if targetEnvironment(macCatalyst)
        toggleCatalystFullScreen()
        #else
        isFullScreen = false
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// `toggleFullScreen:` is the public macOS responder-chain action used by
    /// the standard View > Enter Full Screen command. Sending it through
    /// UIApplication lets Catalyst hand the request to its hosting NSWindow.
    @discardableResult
    private func toggleCatalystFullScreen() -> Bool {
        UIApplication.shared.sendAction(
            Selector(("toggleFullScreen:")),
            to: nil,
            from: nil,
            for: nil)
    }
    #endif

    /// Debug/testing hook: auto-connect from environment variables so the app
    /// can be launched headlessly in the simulator against a test server.
    private func autoConnectIfRequested() async {
        guard case .idle = session.connectionState else { return }
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_AUTOCONNECT_HOST"], !host.isEmpty else { return }
        let credentials = VNCCredentials(
            host: host,
            port: UInt16(env["VNC_AUTOCONNECT_PORT"] ?? "5900") ?? 5900,
            password: env["VNC_AUTOCONNECT_PASSWORD"] ?? "",
            username: env["VNC_AUTOCONNECT_USER"].flatMap { $0.isEmpty ? nil : $0 }
        )
        try? await session.connect(credentials: credentials)
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// Owns the finite amount of execution time iOS may grant after the app moves
/// to the background, giving an active connection a chance to remain alive.
@MainActor
private final class BackgroundTimeExtension {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard identifier == .invalid else { return }

        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Keep VNC connection alive"
        ) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }

        let taskToEnd = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(taskToEnd)
    }

    deinit {
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}
#endif

#Preview {
    ContentView()
}
