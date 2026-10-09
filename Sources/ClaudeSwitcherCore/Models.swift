import Foundation

/// Only declares the fields we care about. JSONDecoder ignores any key not
/// declared here — that includes accessToken/refreshToken and the
/// mcpOAuth blocks of other plugins. They never end up existing as a Swift
/// property in this struct.
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
    /// Technical identifier used in `cs <slug>`, `cs set <slug>`, etc.
    /// Stable (no spaces/accents/case changes), unlike `name` which is display-only.
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
    /// Slug of the account used when the project doesn't define one (via .clauderc).
    /// Always non-nil from the first created account onward (see AccountsConfig).
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
