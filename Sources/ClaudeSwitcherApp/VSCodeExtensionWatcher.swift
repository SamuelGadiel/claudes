import ClaudeSwitcherCore
import Foundation

/// Mantém o patch de scope da extensão oficial do VS Code (ver
/// VSCodeExtensionPatcher) sempre aplicado, reagindo em tempo real quando
/// a extensão é atualizada — sem polling. O usuário deixa o app rodando
/// indefinidamente na status bar (não reinicia no dia a dia), então rodar
/// o patch só uma vez no startup não é suficiente: quando o VS Code
/// atualiza a extensão sozinho em background, ela ganha uma pasta nova
/// (`anthropic.claude-code-<nova-versão>-darwin-arm64`) com o
/// `package.json` original (scope "machine" de novo).
///
/// Observa `~/.vscode/extensions` via `DispatchSource` (kqueue) — o mesmo
/// mecanismo reativo que a própria extensão oficial usa internamente para
/// observar mudanças de configuração (ver `watchGlobalClaudeFileAt` no
/// `extension.js` dela), em vez de checar em intervalos.
@MainActor
final class VSCodeExtensionWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?

    func start() {
        applyNow()

        let path = ("~/.vscode/extensions" as NSString).expandingTildeInPath
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleApply() }
        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Debounce: a extração de um update pode gerar mais de um evento de
    /// escrita no diretório em sequência rápida (pasta antiga removida,
    /// nova criada) — espera a poeira baixar antes de ler o package.json,
    /// pra não pegar um estado intermediário.
    private func scheduleApply() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyNow() }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func applyNow() {
        do {
            let status = try VSCodeExtensionPatcher.ensurePatched()
            if !status.wasAlreadyPatched {
                NSLog("claude-switcher: patch de scope (re)aplicado na extensão VS Code \(status.extensionVersion)")
            }
        } catch VSCodeExtensionPatchError.extensionNotFound {
            // Sem VS Code/extensão instalada — nada a fazer.
        } catch {
            NSLog("claude-switcher: falha ao verificar/aplicar patch da extensão VS Code: \(error)")
        }
    }
}
