import Foundation

/// Único ponto do Core que lê o accessToken de verdade do Keychain — toda
/// outra leitura de credencial (AccountDiscovery) deliberadamente o ignora.
/// Usado apenas para autenticar a chamada a /api/oauth/usage (specs/06);
/// quem chama deve usar o valor imediatamente e nunca persisti-lo.
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
        case .notFound: return "nenhuma credencial encontrada no Keychain para essa conta"
        case .missingInPayload: return "credencial encontrada, mas sem accessToken"
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
