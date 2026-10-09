import CryptoKit
import Foundation

public enum AccountDiscovery {
    private static let defaultConfigDir = ("~/.claude" as NSString).expandingTildeInPath

    /// service == "Claude Code-credentials" para o CLAUDE_CONFIG_DIR default,
    /// ou "Claude Code-credentials-<sha256(path)[:8]>" para qualquer outro.
    /// Confirmado empiricamente nesta máquina (ver plans/specs/01-...).
    public static func keychainService(forConfigDir path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded != defaultConfigDir else {
            return "Claude Code-credentials"
        }
        let digest = SHA256.hash(data: Data(expanded.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// Status de uma conta que acabou de ser criada — sabemos de antemão
    /// que não há credencial ainda, então não vale consultar o Keychain.
    public static func notLoggedInStatus(for account: RegisteredAccount) -> AccountStatus {
        AccountStatus(
            name: account.name, configDir: account.configDir,
            keychainService: keychainService(forConfigDir: account.configDir),
            expiresAt: nil, refreshTokenExpiresAt: nil, subscriptionType: nil, rateLimitTier: nil,
            error: "conta recém-criada, ainda sem login"
        )
    }

    public static func status(for account: RegisteredAccount) -> AccountStatus {
        let service = keychainService(forConfigDir: account.configDir)

        do {
            let data = try Keychain.readPassword(service: service)
            let payload = try JSONDecoder().decode(CredentialPayload.self, from: data)

            guard let oauth = payload.claudeAiOauth else {
                return AccountStatus(
                    name: account.name, configDir: account.configDir, keychainService: service,
                    expiresAt: nil, refreshTokenExpiresAt: nil, subscriptionType: nil, rateLimitTier: nil,
                    error: "credencial encontrada, mas sem o campo claudeAiOauth"
                )
            }

            return AccountStatus(
                name: account.name,
                configDir: account.configDir,
                keychainService: service,
                expiresAt: Date(timeIntervalSince1970: Double(oauth.expiresAt) / 1000),
                refreshTokenExpiresAt: oauth.refreshTokenExpiresAt.map {
                    Date(timeIntervalSince1970: Double($0) / 1000)
                },
                subscriptionType: oauth.subscriptionType,
                rateLimitTier: oauth.rateLimitTier,
                error: nil
            )
        } catch {
            return AccountStatus(
                name: account.name, configDir: account.configDir, keychainService: service,
                expiresAt: nil, refreshTokenExpiresAt: nil, subscriptionType: nil, rateLimitTier: nil,
                error: "\(error)"
            )
        }
    }
}
