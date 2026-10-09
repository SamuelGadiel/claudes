import Foundation

/// Retry/backoff compartilhado pelos dois patches da extensão Claude
/// (`VSCodeExtensionPatcher` e `ClaudeExtensionJSPatchRunner`) — mesma
/// classe de proteção contra timing de atualização: o VS Code pode estar no
/// meio de extrair/escrever os arquivos da nova versão quando o
/// `VSCodeExtensionWatcher` reage ao evento de mudança no diretório, então
/// uma leitura imediata pode pegar um arquivo momentaneamente vazio ou
/// parcial, e uma escrita pode esbarrar num lock transiente (AV scanner,
/// o próprio processo que instalou, etc).
enum TransientFileIO {
    static let retryDelaysNanoseconds: [UInt64] = [50_000_000, 150_000_000, 400_000_000, 1_000_000_000]

    static func readRaw(path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Enquanto a extensão instala/atualiza, o VS Code pode truncar o
    /// arquivo antes de reescrevê-lo — uma leitura nesse instante pode
    /// pegar vazio.
    static func readWithRetry(path: String) async throws -> String {
        var source = readRaw(path: path)
        for delay in retryDelaysNanoseconds where source.isEmpty {
            try await Task.sleep(nanoseconds: delay)
            source = readRaw(path: path)
        }
        return source
    }

    struct StableReadResult {
        let source: String
        let changed: Bool
    }

    /// Relê ao longo de uma janela pra distinguir um update em andamento de
    /// um arquivo já assentado: se o conteúdo mudar em algum ponto, ainda
    /// está sendo escrito; se nunca mudar, é um arquivo genuinamente
    /// estável (e, se mesmo assim não tiver o que procuramos, é uma
    /// regressão real, não um falso positivo de timing).
    static func readUntilStable(path: String, initial: String) async throws -> StableReadResult {
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

    /// Scanners de antivírus ou o próprio processo que instalou podem
    /// segurar o arquivo aberto brevemente logo após uma atualização —
    /// retry com backoff em vez de falhar na primeira tentativa.
    static func retryOnTransientLock(_ operation: () throws -> Void) async throws {
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
