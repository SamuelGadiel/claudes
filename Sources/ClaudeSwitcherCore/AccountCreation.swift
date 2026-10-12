import Foundation

public enum AccountCreationError: LocalizableError, CustomStringConvertible {
    case emptyName
    case invalidSlug
    case reservedSlug(String)
    case duplicateAccount
    case duplicateConfigDir(String)
    case directoryCreationFailed(String)
    case notFound(String)

    public var l10nKey: String {
        switch self {
        case .emptyName: return "name cannot be empty"
        case .invalidSlug: return "could not generate a valid slug from the name"
        case .reservedSlug: return "'%@' is a reserved command — choose another name or provide a slug"
        case .duplicateAccount: return "an account with that name or slug already exists"
        case .duplicateConfigDir: return "an account already registered pointing to %@ already exists"
        case .directoryCreationFailed: return "error creating directory: %@"
        case .notFound: return "account '%@' not found"
        }
    }

    public var l10nArgs: [CVarArg] {
        switch self {
        case .reservedSlug(let slug): return [slug]
        case .duplicateConfigDir(let dir): return [dir]
        case .directoryCreationFailed(let detail): return [detail]
        case .notFound(let identifier): return [identifier]
        case .emptyName, .invalidSlug, .duplicateAccount: return []
        }
    }

    public var description: String { englishText }
}

/// Account creation — logic shared between `cs add` and the equivalent
/// flow in the GUI (specs/05), so the same validations are never duplicated
/// in two places.
extension AccountsConfig {
    @discardableResult
    public static func addAccount(
        name: String, dir: String? = nil, slugOverride: String? = nil, markDefault: Bool = false
    ) throws -> RegisteredAccount {
        guard !name.isEmpty else { throw AccountCreationError.emptyName }

        let slug = slugOverride ?? Slug.make(from: name)
        guard !slug.isEmpty else { throw AccountCreationError.invalidSlug }
        guard !ReservedCommands.names.contains(slug) else { throw AccountCreationError.reservedSlug(slug) }

        var (file, _) = load()
        guard find(identifier: slug, in: file) == nil, find(identifier: name, in: file) == nil else {
            throw AccountCreationError.duplicateAccount
        }

        let expandedConfigDir = ((dir ?? "~/.claude-\(slug)") as NSString).expandingTildeInPath
        guard !file.accounts.contains(where: {
            ($0.configDir as NSString).expandingTildeInPath == expandedConfigDir
        }) else {
            throw AccountCreationError.duplicateConfigDir(expandedConfigDir)
        }

        do {
            try FileManager.default.createDirectory(
                atPath: expandedConfigDir, withIntermediateDirectories: true
            )
        } catch {
            throw AccountCreationError.directoryCreationFailed("\(error)")
        }

        // Every account's `projects/` is a symlink into SharedSessionsDirectory
        // from the moment it's created — there's no per-account session
        // storage model to migrate away from later. Harmless no-op for a
        // brand-new, never-used directory (nothing to merge, just creates the
        // symlink); only does real merge work when adopting a directory that
        // already has session history (e.g. importing an account created
        // before this app existed).
        try SharedSessionsDirectory.adopt(configDir: expandedConfigDir, accountSlug: slug)

        let account = RegisteredAccount(name: name, slug: slug, configDir: expandedConfigDir)
        file.accounts.append(account)
        if markDefault || file.accounts.count == 1 {
            file.defaultAccountSlug = slug
        }
        save(file)

        return account
    }

    /// Removes it from the registry, deletes the directory (`CLAUDE_CONFIG_DIR`)
    /// and the corresponding credential in the Keychain — a complete cleanup,
    /// explicitly requested by the user (specs/05: "remove" should actually
    /// remove, not leave orphan folders). Promotes another account to default if
    /// the removed one was the default and accounts still remain.
    @discardableResult
    public static func removeAccount(slug: String) throws -> RegisteredAccount {
        var (file, _) = load()
        guard let account = find(identifier: slug, in: file) else {
            throw AccountCreationError.notFound(slug)
        }

        file.accounts.removeAll { $0.slug == account.slug }
        if file.defaultAccountSlug == account.slug {
            file.defaultAccountSlug = file.accounts.first?.slug
        }
        save(file)

        Keychain.deletePassword(service: AccountDiscovery.keychainService(forConfigDir: account.configDir))
        try? FileManager.default.removeItem(atPath: account.configDir)

        return account
    }
}
