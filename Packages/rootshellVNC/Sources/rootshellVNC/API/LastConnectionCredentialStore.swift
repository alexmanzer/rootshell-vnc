import Foundation
import Security

/// Codable payload kept inside one generic-password Keychain item. Keeping the
/// host and port alongside the username/password makes restoring the last
/// successful connection atomic: a failed connection never overwrites it.
struct LastConnectionRecord: Codable, Sendable, Equatable {
    let host: String
    let port: UInt16
    let username: String?
    let password: String

    init(credentials: VNCCredentials) {
        host = credentials.host
        port = credentials.port
        username = credentials.username
        password = credentials.password
    }

    var credentials: VNCCredentials {
        VNCCredentials(
            host: host,
            port: port,
            password: password,
            username: username)
    }
}

enum LastConnectionCredentialStore {
    private static let service = "com.rootshell.vnc.last-connection"
    private static let account = "last-successful-connection"

    static func load() throws -> VNCCredentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else {
            throw KeychainError.unexpectedResult
        }
        return try JSONDecoder().decode(LastConnectionRecord.self, from: data).credentials
    }

    static func save(_ credentials: VNCCredentials) throws {
        let data = try JSONEncoder().encode(LastConnectionRecord(credentials: credentials))
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var item = identity
        for (key, value) in attributes {
            item[key] = value
        }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }
}

enum KeychainError: Error, LocalizedError {
    case status(OSStatus)
    case unexpectedResult

    init(status: OSStatus) {
        self = .status(status)
    }

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail ?? String(localized: "Keychain error \(status)", bundle: .module)
        case .unexpectedResult:
            return String(
                localized: "The saved Keychain item did not contain credential data.",
                bundle: .module)
        }
    }
}
