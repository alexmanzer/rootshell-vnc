import Foundation
import RFBProtocol

/// VeNCrypt 0.2 using its X.509-protected subtypes. Anonymous TLS subtypes are
/// deliberately not selected because modern TLS stacks no longer support the
/// anonymous cipher suites they require.
public struct VeNCryptAuthenticator: Authenticator, Sendable {
    private enum Subtype: UInt32, Sendable {
        case x509None = 260
        case x509VNC = 261
        case x509Plain = 262
    }

    private let host: String
    private let port: UInt16
    private let username: String?
    private let password: String
    private let requiresUserAuthentication: Bool
    private let certificateValidationHandler: VNCCertificateValidationHandler?
    private let log = VNCLogger(category: "VeNCrypt")

    public init(
        host: String,
        port: UInt16,
        username: String?,
        password: String,
        certificateValidationHandler: VNCCertificateValidationHandler? = nil,
        requiresUserAuthentication: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.requiresUserAuthentication = requiresUserAuthentication
        self.certificateValidationHandler = certificateValidationHandler
    }

    public func authenticate(connection: any RFBConnection) async throws -> AuthenticationResult {
        guard await connection.supportsTLSUpgrade() else {
            throw VNCProtocolError.protocolViolation(
                "VeNCrypt is unavailable over the selected tunnel transport")
        }

        let serverVersion = try await connection.read(exactly: 2)
        guard serverVersion.count == 2,
              serverVersion[serverVersion.startIndex] == 0,
              serverVersion[serverVersion.startIndex + 1] >= 2 else {
            throw VNCProtocolError.protocolViolation(
                "Unsupported VeNCrypt version \(serverVersion.map(String.init).joined(separator: "."))")
        }
        // VeNCrypt 0.2 is the interoperable version implemented by TigerVNC,
        // x11vnc, and wayvnc.
        try await connection.send(Data([0, 2]))
        let versionStatus = try await connection.read(exactly: 1)
        guard versionStatus.first == 0 else {
            throw VNCProtocolError.authenticationFailed(
                "The server rejected VeNCrypt 0.2")
        }

        let subtypeCountData = try await connection.read(exactly: 1)
        guard let countByte = subtypeCountData.first, countByte > 0 else {
            throw VNCProtocolError.authenticationFailed(
                "The server offered no VeNCrypt security subtypes")
        }
        let subtypeData = try await connection.read(exactly: Int(countByte) * 4)
        var offered: [UInt32] = []
        for offset in stride(from: 0, to: subtypeData.count, by: 4) {
            let byte0 = UInt32(subtypeData[offset]) << 24
            let byte1 = UInt32(subtypeData[offset + 1]) << 16
            let byte2 = UInt32(subtypeData[offset + 2]) << 8
            let byte3 = UInt32(subtypeData[offset + 3])
            offered.append(byte0 | byte1 | byte2 | byte3)
        }
        guard let selected = selectSubtype(from: offered) else {
            if requiresUserAuthentication { throw VNCProtocolError.securityPolicyViolation }
            let list = offered.map(String.init).joined(separator: ", ")
            throw VNCProtocolError.authenticationFailed(
                "No supported encrypted VeNCrypt subtype was offered (\(list))")
        }

        try await connection.send(Self.bigEndianData(selected.rawValue))
        log.info("Selected VeNCrypt subtype \(selected.rawValue)")
        try await connection.startTLS(configuration: RFBTLSConfiguration(
            serverHostname: host,
            serverPort: port,
            certificateValidationHandler: certificateValidationHandler))

        switch selected {
        case .x509None:
            break
        case .x509VNC:
            _ = try await VNCAuthenticator(password: password)
                .authenticate(connection: connection)
        case .x509Plain:
            try await sendPlainCredentials(connection: connection)
        }
        return AuthenticationResult()
    }

    private func selectSubtype(from offered: [UInt32]) -> Subtype? {
        if let username, !username.isEmpty,
           offered.contains(Subtype.x509Plain.rawValue) {
            return .x509Plain
        }
        if offered.contains(Subtype.x509VNC.rawValue) {
            return .x509VNC
        }
        if !requiresUserAuthentication, offered.contains(Subtype.x509None.rawValue) {
            return .x509None
        }
        return nil
    }

    private func sendPlainCredentials(connection: any RFBConnection) async throws {
        let usernameData = Data((username ?? "").utf8)
        let passwordData = Data(password.utf8)
        guard usernameData.count <= Int(UInt32.max),
              passwordData.count <= Int(UInt32.max) else {
            throw VNCProtocolError.authenticationFailed(
                "VeNCrypt credentials are too long")
        }
        var payload = Data()
        payload.append(Self.bigEndianData(UInt32(usernameData.count)))
        payload.append(Self.bigEndianData(UInt32(passwordData.count)))
        payload.append(usernameData)
        payload.append(passwordData)
        try await connection.send(payload)
    }

    private static func bigEndianData(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }
}
