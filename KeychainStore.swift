import Foundation
import Security

struct KeychainStore {
    let service: String
    let account: String

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        try delete(allowMissing: true)

        var query = baseQuery
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }

        return String(data: data, encoding: .utf8)
    }

    func delete() throws {
        try delete(allowMissing: false)
    }

    private func delete(allowMissing: Bool) throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if allowMissing, status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainError: LocalizedError {
    case invalidData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            "The saved Keychain item could not be decoded."
        case .unhandledStatus(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}
