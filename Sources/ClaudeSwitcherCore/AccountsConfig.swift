import Foundation

/// Formato legado (antes de existir `slug`/`defaultAccountSlug`): um array
/// simples de contas, sem default. Usado só para migrar accounts.json
/// existentes sem perder o que já estava registrado.
private struct LegacyAccount: Decodable {
    let name: String
    let configDir: String
}

public enum AccountsConfig {
    public static let configDirPath = ("~/Library/Application Support/ClaudeSwitcher" as NSString)
        .expandingTildeInPath
    public static let configFilePath = configDirPath + "/accounts.json"

    /// `messages` traz avisos informativos (config criada, arquivo migrado)
    /// para quem chamou decidir como exibir — o Core nunca imprime direto,
    /// porque é compartilhado entre o CLI `cs` e a futura GUI de status bar.
    public static func load() -> (file: AccountsFile, messages: [String]) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: configFilePath) else {
            let defaults = AccountsFile(
                accounts: [
                    RegisteredAccount(name: "Pessoal", slug: "pessoal", configDir: "~/.claude"),
                    RegisteredAccount(name: "Trabalho", slug: "trabalho", configDir: "~/.claudew"),
                ],
                defaultAccountSlug: "pessoal"
            )
            save(defaults)
            return (defaults, ["Config default criada em \(configFilePath) (use 'cs add'/'cs remove' para ajustar)"])
        }

        guard let data = fm.contents(atPath: configFilePath) else {
            return (AccountsFile(accounts: [], defaultAccountSlug: nil), ["Não consegui ler \(configFilePath)"])
        }

        if let file = try? JSONDecoder().decode(AccountsFile.self, from: data) {
            return (file, [])
        }

        // Formato legado: array simples sem slug/default. Migra preservando
        // os dados e promovendo a primeira conta a default.
        if let legacy = try? JSONDecoder().decode([LegacyAccount].self, from: data) {
            let migrated = legacy.map {
                RegisteredAccount(name: $0.name, slug: Slug.make(from: $0.name), configDir: $0.configDir)
            }
            let file = AccountsFile(accounts: migrated, defaultAccountSlug: migrated.first?.slug)
            save(file)
            return (file, ["accounts.json migrado para o novo formato (com slug + conta default)."])
        }

        return (
            AccountsFile(accounts: [], defaultAccountSlug: nil),
            ["Não consegui parsear \(configFilePath) — formato desconhecido."]
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

    /// Aceita slug ou nome (case-insensitive) — comandos novos usam slug,
    /// mas isso evita quebrar quem ainda digita o nome amigável.
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
