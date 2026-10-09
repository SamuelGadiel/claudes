import Foundation

/// Só declara os campos que nos interessam. O JSONDecoder ignora qualquer
/// chave não declarada aqui — isso inclui accessToken/refreshToken e os
/// blocos de mcpOAuth de outros plugins. Eles nunca chegam a existir como
/// propriedade Swift nesta struct.
struct ClaudeAiOAuth: Decodable {
    let expiresAt: Int64
    let refreshTokenExpiresAt: Int64?
    let subscriptionType: String?
    let rateLimitTier: String?
}

struct CredentialPayload: Decodable {
    let claudeAiOauth: ClaudeAiOAuth?
}

public struct RegisteredAccount: Codable {
    public let name: String
    /// Identificador técnico usado em `cs <slug>`, `cs set <slug>` etc.
    /// Estável (sem espaço/acento/caixa), diferente do `name` que é só exibição.
    public let slug: String
    public let configDir: String

    public init(name: String, slug: String, configDir: String) {
        self.name = name
        self.slug = slug
        self.configDir = configDir
    }
}

/// ~/Library/Application Support/ClaudeSwitcher/accounts.json
public struct AccountsFile: Codable {
    public var accounts: [RegisteredAccount]
    /// slug da conta usada quando o projeto não define nenhuma (via .clauderc).
    /// Sempre não-nil a partir da primeira conta criada (ver AccountsConfig).
    public var defaultAccountSlug: String?

    public init(accounts: [RegisteredAccount], defaultAccountSlug: String?) {
        self.accounts = accounts
        self.defaultAccountSlug = defaultAccountSlug
    }
}

public struct AccountStatus {
    public let name: String
    public let configDir: String
    public let keychainService: String
    public let expiresAt: Date?
    public let refreshTokenExpiresAt: Date?
    public let subscriptionType: String?
    public let rateLimitTier: String?
    public let error: String?

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }
}
