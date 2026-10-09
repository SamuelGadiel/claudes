import Foundation

public enum VSCodeExtensionPatchError: Error, CustomStringConvertible {
    case extensionNotFound
    case packageJSONUnreadable(String)
    case settingNotFound
    case unrecognizedScope(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .extensionNotFound:
            return "extensão anthropic.claude-code não encontrada em ~/.vscode/extensions"
        case .packageJSONUnreadable(let detail):
            return "não consegui ler o package.json da extensão: \(detail)"
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

    /// Localiza a instalação da extensão oficial — havendo mais de uma
    /// pasta (raro, pode acontecer durante um update), fica com a de maior
    /// versão.
    public static func locateExtensionDir() -> String? {
        let extensionsDir = ("~/.vscode/extensions" as NSString).expandingTildeInPath
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
    public static func ensurePatched() throws -> VSCodeExtensionPatchStatus {
        guard let extensionDir = locateExtensionDir() else {
            throw VSCodeExtensionPatchError.extensionNotFound
        }
        let packageJSONPath = extensionDir + "/package.json"

        guard let data = FileManager.default.contents(atPath: packageJSONPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
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
            return VSCodeExtensionPatchStatus(extensionVersion: version, wasAlreadyPatched: true)
        }
        guard currentScope == originalScope else {
            throw VSCodeExtensionPatchError.unrecognizedScope(currentScope)
        }

        // Backup só na primeira vez que patcheamos essa versão específica —
        // cada pasta de versão só é patcheada uma vez, não há "desfazer"
        // incremental necessário depois disso.
        let backupPath = packageJSONPath + backupSuffix
        if !FileManager.default.fileExists(atPath: backupPath) {
            try? data.write(to: URL(fileURLWithPath: backupPath))
        }

        setting["scope"] = patchedScope
        properties[targetSetting] = setting
        configuration["properties"] = properties
        contributes["configuration"] = configuration
        root["contributes"] = contributes

        do {
            let patched = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
            try patched.write(to: URL(fileURLWithPath: packageJSONPath))
        } catch {
            throw VSCodeExtensionPatchError.writeFailed("\(error)")
        }

        return VSCodeExtensionPatchStatus(extensionVersion: version, wasAlreadyPatched: false)
    }
}
