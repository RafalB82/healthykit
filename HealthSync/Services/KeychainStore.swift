import Foundation
import Security

protocol TokenProviding {
    func readUploadToken(id: UUID) throws -> String?
    func saveUploadToken(_ token: String, id: UUID) throws
    func deleteUploadToken(id: UUID) throws
    func readHostedIngestToken() throws -> String?
    func readHostedAgentToken() throws -> String?
    func saveHostedAgentToken(_ token: String) throws
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            "Keychain operation failed with status \(status)."
        case .invalidData:
            "Stored Keychain token is invalid."
        }
    }
}

struct KeychainStore: TokenProviding {
    private let service = "com.megabyte0x.HealthSync"
    private let hostedIngestTokenAccount = "hostedIngestToken"
    private let hostedAgentTokenAccount = "hostedAgentToken"

    func readUploadToken(id: UUID) throws -> String? {
        try readToken(account: "uploadToken.\(id.uuidString)")
    }

    func saveUploadToken(_ token: String, id: UUID) throws {
        try saveToken(token, account: "uploadToken.\(id.uuidString)")
    }

    func deleteUploadToken(id: UUID) throws {
        try deleteToken(account: "uploadToken.\(id.uuidString)")
    }

    func readHostedIngestToken() throws -> String? {
        try readToken(account: hostedIngestTokenAccount)
    }

    func readHostedAgentToken() throws -> String? {
        try readToken(account: hostedAgentTokenAccount)
    }

    func saveHostedAgentToken(_ token: String) throws {
        try saveToken(token, account: hostedAgentTokenAccount)
    }

    private func readToken(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return token
    }

    private func saveToken(_ token: String, account: String) throws {
        let data = Data(token.utf8)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func deleteToken(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
