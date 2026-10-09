import Foundation

public enum ClaudeExtensionJSPatchError: Error, CustomStringConvertible {
    case extensionNotFound
    case envPatchPointNotFound(version: String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .extensionNotFound:
            return "extensão anthropic.claude-code não encontrada em ~/.vscode/extensions"
        case .envPatchPointNotFound(let version):
            return "não encontrei o ponto de patch esperado no extension.js da versão \(version) — " +
                "a Anthropic pode ter mudado o formato minificado; precisa atualizar os regexes"
        case .writeFailed(let detail):
            return "falha ao escrever extension.js patchado: \(detail)"
        }
    }
}

public struct ClaudeExtensionJSPatchStatus {
    public let extensionVersion: String
    /// Vazio quando já estava tudo aplicado, ou quando pulamos por detectar
    /// um update em andamento (ver `skippedReason`).
    public let changes: [String]
    public let skippedReason: String?
}

/// I/O em volta de `ClaudeExtensionJSPatcher` (a lógica pura de
/// análise/transformação) — localizar o `extension.js` instalado, ler com
/// retry/backoff (a extensão pode estar no meio de um update, arquivo
/// momentaneamente vazio ou parcial), fazer backup, escrever com retry em
/// caso de lock transiente. Mesmas proteções que
/// `leog/claude-code-config-dir-patcher-vscode` usa (ver ATTRIBUTIONS.md),
/// adaptadas de callbacks/setTimeout para Swift Concurrency — ver
/// `TransientFileIO` (compartilhado com `VSCodeExtensionPatcher`).
public enum ClaudeExtensionJSPatchRunner {
    private static let backupSuffix = ".claude-switcher-js-patch.bak"

    @discardableResult
    public static func ensurePatched() async throws -> ClaudeExtensionJSPatchStatus {
        guard let extensionDir = VSCodeExtensionPatcher.locateExtensionDir() else {
            throw ClaudeExtensionJSPatchError.extensionNotFound
        }
        let jsPath = extensionDir + "/extension.js"
        let version = extensionVersion(extensionDir: extensionDir)

        guard FileManager.default.fileExists(atPath: jsPath) else {
            return ClaudeExtensionJSPatchStatus(
                extensionVersion: version, changes: [], skippedReason: "extension.js não encontrado (update em andamento?)"
            )
        }

        var source = try await TransientFileIO.readWithRetry(path: jsPath)
        if source.isEmpty {
            return ClaudeExtensionJSPatchStatus(
                extensionVersion: version, changes: [], skippedReason: "extension.js vazio (update em andamento)"
            )
        }

        var status = ClaudeExtensionJSPatcher.analyze(source)

        // Um arquivo não-vazio sem o ponto de patch pode ser um snapshot
        // parcial capturado no meio de uma reescrita — observa a estabilidade
        // antes de declarar um problema real.
        if !status.envPatched, !status.envPatchable {
            let settled = try await TransientFileIO.readUntilStable(path: jsPath, initial: source)
            if settled.changed {
                source = settled.source
                if source.isEmpty {
                    return ClaudeExtensionJSPatchStatus(
                        extensionVersion: version, changes: [], skippedReason: "extension.js vazio (update em andamento)"
                    )
                }
                status = ClaudeExtensionJSPatcher.analyze(source)
                if !status.envPatched, !status.envPatchable {
                    return ClaudeExtensionJSPatchStatus(
                        extensionVersion: version, changes: [], skippedReason: "arquivo ainda instável, tenta de novo depois"
                    )
                }
            }
        }

        guard status.envPatched || status.envPatchable else {
            throw ClaudeExtensionJSPatchError.envPatchPointNotFound(version: version)
        }

        let result = ClaudeExtensionJSPatcher.applyPatch(source)
        guard !result.changes.isEmpty else {
            return ClaudeExtensionJSPatchStatus(extensionVersion: version, changes: [], skippedReason: nil)
        }

        let backupPath = jsPath + backupSuffix
        if !FileManager.default.fileExists(atPath: backupPath) {
            try await TransientFileIO.retryOnTransientLock {
                try FileManager.default.copyItem(atPath: jsPath, toPath: backupPath)
            }
        }
        do {
            try await TransientFileIO.retryOnTransientLock {
                try result.source.write(toFile: jsPath, atomically: true, encoding: .utf8)
            }
        } catch {
            throw ClaudeExtensionJSPatchError.writeFailed("\(error)")
        }

        return ClaudeExtensionJSPatchStatus(extensionVersion: version, changes: result.changes, skippedReason: nil)
    }

    private static func extensionVersion(extensionDir: String) -> String {
        guard let data = FileManager.default.contents(atPath: extensionDir + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "desconhecida" }
        return json["version"] as? String ?? "desconhecida"
    }
}
