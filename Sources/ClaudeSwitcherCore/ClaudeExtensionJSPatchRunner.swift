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
/// adaptadas de callbacks/setTimeout para Swift Concurrency.
public enum ClaudeExtensionJSPatchRunner {
    private static let backupSuffix = ".claude-switcher-js-patch.bak"
    private static let retryDelaysNanoseconds: [UInt64] = [50_000_000, 150_000_000, 400_000_000, 1_000_000_000]

    @discardableResult
    public static func ensurePatched() async throws -> ClaudeExtensionJSPatchStatus {
        guard let extensionDir = VSCodeExtensionPatcher.locateExtensionDir() else {
            throw ClaudeExtensionJSPatchError.extensionNotFound
        }
        let jsPath = extensionDir + "/extension.js"
        let version = extensionVersion(extensionDir: extensionDir)

        guard FileManager.default.fileExists(atPath: jsPath) else {
            return ClaudeExtensionJSPatchStatus(extensionVersion: version, changes: [], skippedReason: "extension.js não encontrado (update em andamento?)")
        }

        var source = try await readWithRetry(path: jsPath)
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
            let settled = try await readUntilStable(path: jsPath, initial: source)
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
            try await retryOnTransientLock {
                try FileManager.default.copyItem(atPath: jsPath, toPath: backupPath)
            }
        }
        do {
            try await retryOnTransientLock {
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

    private static func readRaw(path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Enquanto a extensão instala/atualiza, o VS Code trunca o extension.js
    /// antes de reescrevê-lo — uma leitura nesse instante pode pegar vazio.
    private static func readWithRetry(path: String) async throws -> String {
        var source = readRaw(path: path)
        for delay in retryDelaysNanoseconds where source.isEmpty {
            try await Task.sleep(nanoseconds: delay)
            source = readRaw(path: path)
        }
        return source
    }

    private struct StableReadResult {
        let source: String
        let changed: Bool
    }

    /// Relê ao longo de uma janela pra distinguir um update em andamento de
    /// um arquivo já assentado: se o conteúdo mudar em algum ponto, ainda
    /// está sendo escrito; se nunca mudar, é um arquivo genuinamente estável
    /// (e, se mesmo assim não tiver o ponto de patch, é uma regressão real).
    private static func readUntilStable(path: String, initial: String) async throws -> StableReadResult {
        var latest = initial
        var changed = false
        for delay in retryDelaysNanoseconds {
            try await Task.sleep(nanoseconds: delay)
            let current = readRaw(path: path)
            if current != latest {
                changed = true
                latest = current
            }
        }
        return StableReadResult(source: latest, changed: changed)
    }

    /// Scanners de antivírus ou o próprio host da extensão podem segurar o
    /// arquivo aberto brevemente logo após uma atualização — retry com
    /// backoff em vez de falhar na primeira tentativa.
    private static func retryOnTransientLock(_ operation: () throws -> Void) async throws {
        for attempt in 0...retryDelaysNanoseconds.count {
            do {
                try operation()
                return
            } catch {
                let nsError = error as NSError
                let isTransient = nsError.domain == NSPOSIXErrorDomain
                    && (nsError.code == Int(EBUSY) || nsError.code == Int(EPERM))
                guard isTransient, attempt < retryDelaysNanoseconds.count else { throw error }
                try await Task.sleep(nanoseconds: retryDelaysNanoseconds[attempt])
            }
        }
    }
}
