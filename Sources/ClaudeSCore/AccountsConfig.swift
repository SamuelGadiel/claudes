import Foundation

/// Legacy format (before `slug`/`defaultAccountSlug` existed): a plain
/// array of accounts, with no default. Used only to migrate existing
/// accounts.json files without losing what was already registered.
private struct LegacyAccount: Decodable {
    let name: String
    let configDir: String
}

public enum AccountsConfig {
    public static let configDirPath = ("~/Library/Application Support/ClaudeS" as NSString)
        .expandingTildeInPath
    public static let configFilePath = configDirPath + "/accounts.json"

    /// The whole project (and this folder along with it) was renamed from
    /// "Claude Switcher" — moved here, once, so accounts registered before
    /// the rename aren't orphaned.
    private static let legacyConfigDirPath = ("~/Library/Application Support/ClaudeSwitcher" as NSString)
        .expandingTildeInPath

    private static func migrateFromLegacyAppSupportDirIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configDirPath), fm.fileExists(atPath: legacyConfigDirPath) else { return }
        try? fm.moveItem(atPath: legacyConfigDirPath, toPath: configDirPath)
    }

    /// `messages` carries informational notices (config created, file migrated)
    /// for the caller to decide how to display — Core never prints directly,
    /// since it's shared between the `cs` CLI and the future status bar GUI.
    public static func load() -> (file: AccountsFile, messages: [String]) {
        let fm = FileManager.default
        migrateFromLegacyAppSupportDirIfNeeded()

        guard fm.fileExists(atPath: configFilePath) else {
            let defaults = AccountsFile(
                accounts: [
                    RegisteredAccount(name: "Personal", slug: "personal", configDir: "~/.claude"),
                    RegisteredAccount(name: "Work", slug: "work", configDir: "~/.claudew"),
                ],
                defaultAccountSlug: "personal"
            )
            save(defaults)
            var messages = ["Default config created at \(configFilePath) (use 'cs add'/'cs remove' to adjust it)"]
            messages += adoptSharedSessions(for: defaults)
            return (defaults, messages)
        }

        guard let data = fm.contents(atPath: configFilePath) else {
            return (AccountsFile(accounts: [], defaultAccountSlug: nil), ["Could not read \(configFilePath)"])
        }

        if let file = try? JSONDecoder().decode(AccountsFile.self, from: data) {
            return (file, adoptSharedSessions(for: file))
        }

        // Legacy format: plain array without slug/default. Migrates preserving
        // the data and promoting the first account to default.
        if let legacy = try? JSONDecoder().decode([LegacyAccount].self, from: data) {
            let migrated = legacy.map {
                RegisteredAccount(name: $0.name, slug: Slug.make(from: $0.name), configDir: $0.configDir)
            }
            let file = AccountsFile(accounts: migrated, defaultAccountSlug: migrated.first?.slug)
            save(file)
            var messages = ["accounts.json migrated to the new format (with slug + default account)."]
            messages += adoptSharedSessions(for: file)
            return (file, messages)
        }

        return (
            AccountsFile(accounts: [], defaultAccountSlug: nil),
            ["Could not parse \(configFilePath) — unknown format."]
        )
    }

    /// Transparently keeps every registered account on the shared chat
    /// directory (spec 04) — not a user-facing command, not an opt-in: it's
    /// how accounts work. Covers both a brand-new install and an
    /// accounts.json that predates this app having the shared-sessions
    /// model at all. The common case (already adopted) is a cheap symlink
    /// check per account; only an account that still has real session data
    /// on disk pays for an actual merge, and only once.
    private static func adoptSharedSessions(for file: AccountsFile) -> [String] {
        var messages: [String] = []
        for account in file.accounts {
            guard let result = try? SharedSessionsDirectory.adopt(configDir: account.configDir, accountSlug: account.slug),
                  !result.alreadyAdopted
            else { continue }
            messages.append("'\(account.name)': adopted the shared chat directory (\(SharedSessionsDirectory.path)).")
        }
        return messages
    }

    public static func save(_ file: AccountsFile) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: configDirPath, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: URL(fileURLWithPath: configFilePath))
    }

    /// Accepts slug or name (case-insensitive) — newer commands use slug,
    /// but this avoids breaking anyone who still types the friendly name.
    public static func find(identifier: String, in file: AccountsFile) -> RegisteredAccount? {
        file.accounts.first {
            $0.slug.caseInsensitiveCompare(identifier) == .orderedSame
                || $0.name.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    public static func defaultAccount(in file: AccountsFile) -> RegisteredAccount? {
        guard let slug = file.defaultAccountSlug else { return nil }
        return file.accounts.first { $0.slug == slug }
    }
}
