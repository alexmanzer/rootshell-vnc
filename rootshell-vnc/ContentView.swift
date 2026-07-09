//
//  ContentView.swift
//  rootshell-vnc
//
//  Created by Kit Knox on 3/17/26.
//

import SwiftUI
import RootShellVNC

struct ContentView: View {
    @State private var session = VNCSession()

    var body: some View {
        NavigationStack {
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
                RemoteDesktopView(session: session)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Text(session.serverName)
                                .font(.headline)
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
        .task { await autoConnectIfRequested() }
    }

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
