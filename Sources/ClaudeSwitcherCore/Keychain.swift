import Foundation
import Security

enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case unexpectedData
    case osStatus(OSStatus)

    var description: String {
        switch self {
        case .notFound:
            return "nenhuma credencial encontrada no Keychain"
        case .unexpectedData:
            return "item do Keychain sem dados legíveis"
        case .osStatus(let status):
            return "erro de Keychain (OSStatus \(status))"
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

    /// Remove o item — usado ao apagar uma conta por completo (specs/05).
    /// Não lança erro se o item já não existir (idempotente).
    static func deletePassword(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
