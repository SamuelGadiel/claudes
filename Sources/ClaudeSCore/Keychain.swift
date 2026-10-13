import Foundation
import Security

enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case unexpectedData
    case osStatus(OSStatus)

    var description: String {
        switch self {
        case .notFound:
            return "no credential found in Keychain"
        case .unexpectedData:
            return "Keychain item with no readable data"
        case .osStatus(let status):
            return "Keychain error (OSStatus \(status))"
        }
    }
}

enum Keychain {
    static func readPassword(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.notFound
            }
            throw KeychainError.osStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }
        return data
    }

    /// Removes the item — used when deleting an account entirely (specs/05).
    /// Does not throw if the item no longer exists (idempotent).
    static func deletePassword(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
