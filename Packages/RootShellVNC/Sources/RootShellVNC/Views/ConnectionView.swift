import SwiftUI
import RFBProtocol

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

    @State private var host: String = ""
    @State private var port: String = "5900"
    @State private var password: String = ""
    @State private var username: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?
    @State private var showRemoteDesktop: Bool = false

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
                statusSection
                connectSection
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
            }

            HStack {
                Text("Port")
                    .frame(width: 80, alignment: .leading)
                TextField("5900", text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
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
            }

            HStack {
                Text("Password")
                    .frame(width: 80, alignment: .leading)
                SecureField("required", text: $password)
                    .textContentType(.password)
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
        !host.isEmpty && !isConnecting && session.connectionState.canConnect
    }

    private func initiateConnection() {
        guard canConnect else { return }

        errorMessage = nil
        isConnecting = true

        let portNumber = UInt16(port) ?? 5900
        let credentials = VNCCredentials(
            host: host,
            port: portNumber,
            password: password,
            username: username.isEmpty ? nil : username
        )

        Task {
            do {
                try await session.connect(credentials: credentials)
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }
}
