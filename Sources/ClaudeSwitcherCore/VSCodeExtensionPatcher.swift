import Foundation

/// Raiz de instalação de extensões de um editor compatível com o formato do
/// VS Code (`<raiz>/extensions/anthropic.claude-code-<versão>-<plataforma>`).
/// Hoje só VS Code estável e Insiders — a mesma extensão oficial roda nos
/// dois, cada um com sua própria cópia instalada, então os dois precisam
/// ser patchados independentemente se ambos estiverem presentes. Forks como
/// Cursor/Windsurf usam esse mesmo formato de pasta e poderiam ser
/// adicionados aqui no futuro, mas não foram validados — fora de escopo
/// por ora.
public enum VSCodeEditorRoot: String, CaseIterable, CustomStringConvertible {
    case stable = "~/.vscode"
    case insiders = "~/.vscode-insiders"

    public var extensionsDirPath: String {
        (rawValue as NSString).expandingTildeInPath + "/extensions"
    }

    public var description: String {
        switch self {
        case .stable: return "VS Code"
        case .insiders: return "VS Code Insiders"
        }
    }
}

public enum VSCodeExtensionPatchError: Error, CustomStringConvertible {
    case extensionNotFound
    case packageJSONUnreadable(String)
    case settingNotFound
    case unrecognizedScope(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .extensionNotFound:
            return "extensão anthropic.claude-code não encontrada"
        case .packageJSONUnreadable(let detail):
            return "não consegui ler/decodificar o package.json da extensão mesmo após esperar " +
                "estabilizar (não é timing de update) — \(detail)"
        case .settingNotFound:
            return "o setting claudeCode.environmentVariables não existe mais no package.json — a extensão pode ter mudado de formato"
        case .unrecognizedScope(let scope):
            return "scope atual ('\(scope)') não é nem 'machine' (original) nem 'window' (patchado) — " +
                "a extensão pode ter mudado; não tentei mexer para não quebrar algo desconhecido"
        case .writeFailed(let detail):
            return "falha ao escrever o package.json patchado: \(detail)"
        }
    }
}

public struct VSCodeExtensionPatchStatus {
    public let extensionVersion: String
    public let wasAlreadyPatched: Bool
    /// Não-nil quando pulamos por detectar um update em andamento (arquivo
    /// vazio/instável) — não é sucesso nem erro, só "tenta de novo depois".
    public let skippedReason: String?
}

/// `claudeCode.environmentVariables` (que carrega CLAUDE_CONFIG_DIR) é
/// declarado no `package.json` da extensão oficial com `"scope": "machine"`
/// — segundo a documentação da Microsoft sobre scopes de configuração de
/// extensão, isso significa "settings that can be set only in user settings
/// or only in remote settings": o VS Code **ignora silenciosamente** esse
/// setting quando definido em `.vscode/settings.json` de um projeto (scope
/// workspace/folder). É a causa raiz confirmada de por que trocar de conta
/// de um projeto nunca tinha efeito real no Claude Code, mesmo com o patch
/// do leog (specs/03) aplicado e a janela recarregada — aquele patch
/// resolve um problema diferente (a extensão lendo `process.env` direto em
/// vez do setting resolvido), não a restrição de escopo em si.
///
/// A correção, confirmada empiricamente (troca de conta propagou sem
/// reload extra): trocar esse `"scope"` de `"machine"` para `"window"` no
/// `package.json` instalado — settings "window" podem ser definidos em
/// user, workspace OU remote settings, exatamente o que precisamos (cada
/// janela/projeto com seu próprio CLAUDE_CONFIG_DIR). `package.json` é só
/// metadata estática lida pelo motor de configuração do VS Code, não
/// código a interpretar — edição direta de JSON, sem JavaScriptCore.
///
/// Continua precisando do patch do leog (`extension.js`, código compilado)
/// para a parte funcional: sem ele, mesmo com o scope liberado, a extensão
/// ainda lê `process.env.CLAUDE_CONFIG_DIR` direto em alguns storage
/// helpers, ignorando o valor resolvido do setting.
public enum VSCodeExtensionPatcher {
    static let targetSetting = "claudeCode.environmentVariables"
    static let patchedScope = "window"
    static let originalScope = "machine"
    private static let backupSuffix = ".claude-switcher-scope-patch.bak"

    /// Localiza a instalação da extensão oficial dentro de uma raiz de
    /// editor específica — havendo mais de uma pasta (raro, pode acontecer
    /// durante um update), fica com a de maior versão.
    public static func locateExtensionDir(in root: VSCodeEditorRoot) -> String? {
        let extensionsDir = root.extensionsDirPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: extensionsDir) else {
            return nil
        }
        let candidates = entries.compactMap { entry -> (path: String, version: String)? in
            guard entry.hasPrefix("anthropic.claude-code-") else { return nil }
            guard let version = extractVersion(fromDirName: entry) else { return nil }
            return (extensionsDir + "/" + entry, version)
        }
        return candidates.max { compareVersions($0.version, $1.version) == .orderedAscending }?.path
    }

    /// Uma entrada por raiz de editor onde a extensão oficial está de fato
    /// instalada — 0, 1 ou 2 hoje (VS Code estável/Insiders).
    public static func allExtensionDirs() -> [String] {
        VSCodeEditorRoot.allCases.compactMap { locateExtensionDir(in: $0) }
    }

    /// "anthropic.claude-code-2.1.281-darwin-arm64" -> "2.1.281"
    private static func extractVersion(fromDirName name: String) -> String? {
        let prefix = "anthropic.claude-code-"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        // versão é tudo até o primeiro "-" seguido de uma letra (plataforma:
        // darwin-arm64, darwin-x64, win32-x64 etc.) — versões são só dígitos e pontos.
        let versionChars = rest.prefix { $0.isNumber || $0 == "." }
        return versionChars.isEmpty ? nil : String(versionChars)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rParts = rhs.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lParts.count, rParts.count) {
            let l = i < lParts.count ? lParts[i] : 0
            let r = i < rParts.count ? rParts[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    @discardableResult
    public static func ensurePatched(extensionDir: String) async throws -> VSCodeExtensionPatchStatus {
        let packageJSONPath = extensionDir + "/package.json"

        guard FileManager.default.fileExists(atPath: packageJSONPath) else {
            return VSCodeExtensionPatchStatus(
                extensionVersion: "desconhecida", wasAlreadyPatched: false,
                skippedReason: "package.json não encontrado (update em andamento?)"
            )
        }

        var text = try await TransientFileIO.readWithRetry(path: packageJSONPath)
        if text.isEmpty {
            return VSCodeExtensionPatchStatus(
                extensionVersion: "desconhecida", wasAlreadyPatched: false,
                skippedReason: "package.json vazio (update em andamento)"
            )
        }

        var parsed = parse(text)
        // Um arquivo não-vazio mas com JSON inválido pode ser um snapshot
        // parcial capturado no meio de uma reescrita — observa a
        // estabilidade antes de declarar um problema real (mesma proteção
        // que ClaudeExtensionJSPatchRunner já tem para o extension.js).
        if parsed == nil {
            let settled = try await TransientFileIO.readUntilStable(path: packageJSONPath, initial: text)
            if settled.changed {
                text = settled.source
                if text.isEmpty {
                    return VSCodeExtensionPatchStatus(
                        extensionVersion: "desconhecida", wasAlreadyPatched: false,
                        skippedReason: "package.json vazio (update em andamento)"
                    )
                }
                parsed = parse(text)
                if parsed == nil {
                    return VSCodeExtensionPatchStatus(
                        extensionVersion: "desconhecida", wasAlreadyPatched: false,
                        skippedReason: "arquivo ainda instável, tenta de novo depois"
                    )
                }
            }
        }

        guard var root = parsed else {
            throw VSCodeExtensionPatchError.packageJSONUnreadable(packageJSONPath)
        }

        let version = root["version"] as? String ?? "desconhecida"

        guard var contributes = root["contributes"] as? [String: Any],
              var configuration = contributes["configuration"] as? [String: Any],
              var properties = configuration["properties"] as? [String: Any],
              var setting = properties[targetSetting] as? [String: Any],
              let currentScope = setting["scope"] as? String
        else {
            throw VSCodeExtensionPatchError.settingNotFound
        }

        if currentScope == patchedScope {
            return VSCodeExtensionPatchStatus(extensionVersion: version, wasAlreadyPatched: true, skippedReason: nil)
        }
        guard currentScope == originalScope else {
            throw VSCodeExtensionPatchError.unrecognizedScope(currentScope)
        }

        // Backup só na primeira vez que patcheamos essa versão específica —
        // cada pasta de versão só é patcheada uma vez, não há "desfazer"
        // incremental necessário depois disso.
        let backupPath = packageJSONPath + backupSuffix
        if !FileManager.default.fileExists(atPath: backupPath) {
            try await TransientFileIO.retryOnTransientLock {
                try text.write(toFile: backupPath, atomically: true, encoding: .utf8)
            }
        }

        setting["scope"] = patchedScope
        properties[targetSetting] = setting
        configuration["properties"] = properties
        contributes["configuration"] = configuration
        root["contributes"] = contributes

        do {
            let patched = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
            try await TransientFileIO.retryOnTransientLock {
                try patched.write(to: URL(fileURLWithPath: packageJSONPath))
            }
        } catch {
            throw VSCodeExtensionPatchError.writeFailed("\(error)")
        }

        return VSCodeExtensionPatchStatus(extensionVersion: version, wasAlreadyPatched: false, skippedReason: nil)
    }

    private static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
