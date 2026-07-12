import SwiftUI
import RFBProtocol
import os

/// A form view for entering VNC server connection details and initiating a connection.
///
/// On successful connection, the view navigates to a ``RemoteDesktopView``
/// displaying the remote desktop.
///
/// Usage:
/// ```swift
/// ConnectionView(session: vncSession)
/// ```
public struct ConnectionView: View {

    // MARK: - Properties

    @Bindable var session: VNCSession
    @Environment(\.displayScale) private var displayScale

    @State private var host: String = ""
    @State private var port: String = "5900"
    @State private var password: String = ""
    @State private var username: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?
    @State private var showRemoteDesktop: Bool = false
    @State private var restoredSavedConnection: Bool = false

    private let logger = Logger(
        subsystem: "com.rootshell.vnc",
        category: "Credentials")

    // MARK: - Init

    /// Create a connection view bound to the given VNC session.
    ///
    /// - Parameter session: The VNC session to use for the connection.
    public init(session: VNCSession) {
        self.session = session
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Form {
                serverSection
                authenticationSection
                audioSection
                qualitySection
                displaySizingSection
                statusSection
                connectSection
            }
            .background {
                // Capture the window/phone viewport before Connect is tapped.
                // Match Client can then be negotiated before the first Apple
                // media stream instead of after navigation to the desktop.
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            prepareRemoteDisplaySize(geometry.size)
                        }
                        .onChange(of: geometry.size) { _, newSize in
                            prepareRemoteDisplaySize(newSize)
                        }
                        .onChange(of: displayScale) { _, _ in
                            prepareRemoteDisplaySize(geometry.size)
                        }
                        .onChange(of: session.configuration.displaySizingMode) { _, mode in
                            if mode == .matchClient {
                                prepareRemoteDisplaySize(geometry.size)
                            }
                        }
                        .onChange(of: session.configuration.videoQualityMode) { _, _ in
                            prepareRemoteDisplaySize(geometry.size)
                        }
                }
            }
            .navigationTitle("Connect to VNC Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .navigationDestination(isPresented: $showRemoteDesktop) {
                RemoteDesktopView(session: session)
                    #if os(iOS)
                    .navigationBarBackButtonHidden()
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Disconnect") {
                                session.disconnect()
                                showRemoteDesktop = false
                            }
                        }
                    }
            }
            .onChange(of: session.connectionState) { _, newValue in
                switch newValue {
                case .connected:
                    isConnecting = false
                    errorMessage = nil
                    showRemoteDesktop = true
                case .failed(let reason):
                    isConnecting = false
                    errorMessage = reason
                case .disconnected:
                    isConnecting = false
                    showRemoteDesktop = false
                default:
                    break
                }
            }
            .task {
                restoreLastConnectionIfNeeded()
            }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("Server") {
            HStack {
                Text("Host")
                    .frame(width: 80, alignment: .leading)
                TextField("hostname or IP address", text: $host)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)
                    .submitLabel(.next)
            }

            HStack {
                Text("Port")
                    .frame(width: 80, alignment: .leading)
                TextField("5900", text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .submitLabel(.next)
            }
        }
    }

    private var authenticationSection: some View {
        Section("Authentication") {
            HStack {
                Text("Username")
                    .frame(width: 80, alignment: .leading)
                TextField("optional", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)
                    .submitLabel(.next)
            }

            HStack {
                Text("Password")
                    .frame(width: 80, alignment: .leading)
                SecureField("required", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(initiateConnection)
            }
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Play Remote Audio", isOn: $session.configuration.enableRemoteAudio)
            Text("Play the remote Mac's system audio when the server offers it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var qualitySection: some View {
        Section("Display Quality") {
            Picker("Quality", selection: $session.configuration.videoQualityMode) {
                ForEach(VNCConfiguration.VideoQualityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            // Three descriptive modes do not fit reliably in an iPhone-width
            // segmented control; the menu preserves their complete labels.
            .pickerStyle(.menu)

            Text(session.configuration.videoQualityMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var displaySizingSection: some View {
        Section("Remote Display Size") {
            Picker("Sizing", selection: $session.configuration.displaySizingMode) {
                ForEach(VNCConfiguration.DisplaySizingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(session.configuration.displaySizingMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if session.configuration.displaySizingMode == .matchClient,
               session.configuration.videoQualityMode != .adaptive {
                Text(
                    "Apple servers support Match Client only in Adaptive mode. "
                        + "Standard VNC servers may still resize when they advertise "
                        + "ExtendedDesktopSize support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let errorMessage {
            Section {
                Label {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var connectSection: some View {
        Section {
            Button(action: initiateConnection) {
                HStack {
                    Spacer()
                    if isConnecting {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Connecting...")
                    } else {
                        Text("Connect")
                    }
                    Spacer()
                }
            }
            .disabled(!canConnect)
        }
    }

    // MARK: - Actions

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && UInt16(port).map { $0 > 0 } == true
            && !isConnecting
            && session.connectionState.canConnect
    }

    private func initiateConnection() {
        guard canConnect else { return }

        errorMessage = nil
        isConnecting = true

        guard let portNumber = UInt16(port), portNumber > 0 else {
            errorMessage = "Enter a valid port between 1 and 65535."
            isConnecting = false
            return
        }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = VNCCredentials(
            host: normalizedHost,
            port: portNumber,
            password: password,
            username: normalizedUsername.isEmpty ? nil : normalizedUsername
        )

        Task {
            do {
                try await session.connect(credentials: credentials)
                do {
                    try LastConnectionCredentialStore.save(credentials)
                } catch {
                    logger.error(
                        "Could not save last connection in Keychain: \(error.localizedDescription, privacy: .public)")
                }
            } catch is CancellationError {
                isConnecting = false
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }

    private func restoreLastConnectionIfNeeded() {
        guard !restoredSavedConnection else { return }
        restoredSavedConnection = true
        do {
            guard let credentials = try LastConnectionCredentialStore.load() else { return }
            host = credentials.host
            port = String(credentials.port)
            username = credentials.username ?? ""
            password = credentials.password
        } catch {
            logger.error(
                "Could not restore last connection from Keychain: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prepareRemoteDisplaySize(_ size: CGSize) {
        session.updateRemoteDisplaySize(
            viewSize: size,
            displayScale: displayScale)
    }
}
