import Foundation

/// Legacy format (before `slug`/`defaultAccountSlug` existed): a plain
/// array of accounts, with no default. Used only to migrate existing
/// accounts.json files without losing what was already registered.
private struct LegacyAccount: Decodable {
    let name: String
    let configDir: String
}

public enum AccountsConfig {
    public static let configDirPath = ("~/Library/Application Support/ClaudeSwitcher" as NSString)
        .expandingTildeInPath
    public static let configFilePath = configDirPath + "/accounts.json"

    /// `messages` carries informational notices (config created, file migrated)
    /// for the caller to decide how to display — Core never prints directly,
    /// since it's shared between the `cs` CLI and the future status bar GUI.
    public static func load() -> (file: AccountsFile, messages: [String]) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: configFilePath) else {
            let defaults = AccountsFile(
                accounts: [
                    RegisteredAccount(name: "Personal", slug: "personal", configDir: "~/.claude"),
                    RegisteredAccount(name: "Work", slug: "work", configDir: "~/.claudew"),
                ],
                defaultAccountSlug: "personal"
            )
            save(defaults)
            return (defaults, ["Default config created at \(configFilePath) (use 'cs add'/'cs remove' to adjust it)"])
        }

        guard let data = fm.contents(atPath: configFilePath) else {
            return (AccountsFile(accounts: [], defaultAccountSlug: nil), ["Could not read \(configFilePath)"])
        }

        if let file = try? JSONDecoder().decode(AccountsFile.self, from: data) {
            return (file, [])
        }

        // Legacy format: plain array without slug/default. Migrates preserving
        // the data and promoting the first account to default.
        if let legacy = try? JSONDecoder().decode([LegacyAccount].self, from: data) {
            let migrated = legacy.map {
                RegisteredAccount(name: $0.name, slug: Slug.make(from: $0.name), configDir: $0.configDir)
            }
            let file = AccountsFile(accounts: migrated, defaultAccountSlug: migrated.first?.slug)
            save(file)
            return (file, ["accounts.json migrated to the new format (with slug + default account)."])
        }

        return (
            AccountsFile(accounts: [], defaultAccountSlug: nil),
            ["Could not parse \(configFilePath) — unknown format."]
        )
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
