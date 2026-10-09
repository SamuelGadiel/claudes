import Foundation

public enum AccountCreationError: Error, CustomStringConvertible {
    case emptyName
    case invalidSlug
    case reservedSlug(String)
    case duplicateAccount
    case duplicateConfigDir(String)
    case directoryCreationFailed(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .emptyName: return "nome não pode ser vazio"
        case .invalidSlug: return "não foi possível gerar um slug válido a partir do nome"
        case .reservedSlug(let slug): return "'\(slug)' é um comando reservado — escolha outro nome ou informe um slug"
        case .duplicateAccount: return "já existe uma conta com esse nome ou slug"
        case .duplicateConfigDir(let dir): return "já existe uma conta registrada apontando para \(dir)"
        case .directoryCreationFailed(let detail): return "erro ao criar diretório: \(detail)"
        case .notFound(let identifier): return "conta '\(identifier)' não encontrada"
        }
    }
}

/// Criação de conta — lógica compartilhada entre `cs add` e o fluxo
/// equivalente na GUI (specs/05), para nunca duplicar as mesmas validações
/// em dois lugares.
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

        let account = RegisteredAccount(name: name, slug: slug, configDir: expandedConfigDir)
        file.accounts.append(account)
        if markDefault || file.accounts.count == 1 {
            file.defaultAccountSlug = slug
        }
        save(file)

        return account
    }

    /// Remove do registro, apaga o diretório (`CLAUDE_CONFIG_DIR`) e a
    /// credencial correspondente no Keychain — limpeza completa, pedida
    /// explicitamente pelo usuário (specs/05: "remover" deve remover de
    /// verdade, não deixar pastas órfãs). Promove outra conta a default se
    /// a removida era a default e ainda sobram contas.
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
