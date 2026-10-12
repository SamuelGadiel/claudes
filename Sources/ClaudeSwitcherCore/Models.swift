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

public enum AccountLoginState {
    /// No readable credential in the Keychain — a newly created account, or
    /// one fully revoked.
    case neverLoggedIn
    /// A credential exists, but `refreshTokenExpiresAt` is in the past — the
    /// access token can no longer be renewed automatically, needs a real
    /// login again.
    case expired
    case loggedIn
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

    /// Never compares `expiresAt` (the access token) against now — that one
    /// expires and silently renews itself all the time, that's normal. Only
    /// `refreshTokenExpiresAt` reflects a session that actually needs a new
    /// login. See specs/01-gerenciamento-contas-storage.
    public var loginState: AccountLoginState {
        if error != nil { return .neverLoggedIn }
        if let refreshTokenExpiresAt, refreshTokenExpiresAt < Date() { return .expired }
        return .loggedIn
    }
}
