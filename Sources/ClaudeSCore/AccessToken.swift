import Foundation

/// The only point in Core that reads the real accessToken from the Keychain —
/// every other credential read (AccountDiscovery) deliberately ignores it.
/// Used only to authenticate the call to /api/oauth/usage (specs/06);
/// callers must use the value immediately and never persist it.
private struct AccessTokenPayload: Decodable {
    let claudeAiOauth: OAuth?
    struct OAuth: Decodable {
        let accessToken: String
    }
}

public enum AccessTokenError: Error, CustomStringConvertible {
    case notFound
    case missingInPayload

    public var description: String {
        switch self {
        case .notFound: return "no credential found in Keychain for this account"
        case .missingInPayload: return "credential found, but missing accessToken"
        }
    }
}

public enum AccessToken {
    public static func read(for account: RegisteredAccount) throws -> String {
        let service = AccountDiscovery.keychainService(forConfigDir: account.configDir)
        let data: Data
        do {
            data = try Keychain.readPassword(service: service)
        } catch {
            throw AccessTokenError.notFound
        }
        guard let token = try JSONDecoder().decode(AccessTokenPayload.self, from: data).claudeAiOauth?.accessToken
        else {
            throw AccessTokenError.missingInPayload
        }
        return token
    }
}
