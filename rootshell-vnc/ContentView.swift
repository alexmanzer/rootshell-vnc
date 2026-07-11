//
//  ContentView.swift
//  rootshell-vnc
//
//  Created by Kit Knox on 3/17/26.
//

import SwiftUI
import RootShellVNC

#if targetEnvironment(macCatalyst)
import UIKit
#endif

struct ContentView: View {
    @State private var session = VNCSession()
    @State private var isFullScreen = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
        .onChange(of: session.connectionState) { _, newState in
            if !newState.isConnected, isFullScreen {
                exitFullScreen()
            }
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
        case .connected:
            remoteDesktop
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text(session.serverName)
                            .font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: enterFullScreen) {
                            Label(
                                "Enter Full Screen",
                                systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .keyboardShortcut("f", modifiers: [.command, .control])
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
                    session.connectionState = .idle
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var remoteDesktop: some View {
        RemoteDesktopView(session: session)
            .ignoresSafeArea(isFullScreen ? .all : [])
            .persistentSystemOverlays(isFullScreen ? .hidden : .automatic)
            .overlay(alignment: .topTrailing) {
                if isFullScreen {
                    exitFullScreenButton
                        .safeAreaPadding(.top, 10)
                        .safeAreaPadding(.trailing, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isFullScreen)
    }

    private var exitFullScreenButton: some View {
        Button(action: exitFullScreen) {
            if horizontalSizeClass == .compact {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 42, height: 42)
            } else {
                Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                    .padding(.horizontal, 14)
                    .frame(minHeight: 42)
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command, .control])
        .accessibilityLabel("Exit Full Screen")
        .help("Exit Full Screen (⌃⌘F)")
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

#Preview {
    ContentView()
}
