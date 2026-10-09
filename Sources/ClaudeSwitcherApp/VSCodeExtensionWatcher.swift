import ClaudeSwitcherCore
import Foundation

/// Mantém os dois patches da extensão oficial do Claude Code (ver
/// ClaudePatchCoordinator) sempre aplicados, reagindo em tempo real quando
/// a extensão é atualizada — sem polling. O usuário deixa o app rodando
/// indefinidamente na status bar (não reinicia no dia a dia), então rodar
/// os patches só uma vez no startup não é suficiente: quando o VS Code
/// atualiza a extensão sozinho em background, ela ganha uma pasta nova
/// (`anthropic.claude-code-<nova-versão>-darwin-arm64`) com os arquivos
/// originais, sem patch nenhum.
///
/// Observa `extensions/` de cada `VSCodeEditorRoot` presente (estável
/// e/ou Insiders) via `DispatchSource` (kqueue) — o mesmo mecanismo
/// reativo que a própria extensão oficial usa internamente para observar
/// mudanças de configuração (ver `watchGlobalClaudeFileAt` no
/// `extension.js` dela), em vez de checar em intervalos.
@MainActor
final class VSCodeExtensionWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?

    func start() {
        applyNow()

        for root in VSCodeEditorRoot.allCases {
            watch(path: root.extensionsDirPath)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources = []
    }

    /// Diretório pode não existir ainda (editor nunca instalado nesta
    /// máquina) — `open` falha silenciosamente nesse caso, sem problema:
    /// simplesmente não observamos essa raiz.
    private func watch(path: String) {
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleApply() }
        source.setCancelHandler { close(fileDescriptor) }
        source.resume()
        sources.append(source)
    }

    /// Debounce compartilhado entre todas as raízes observadas: a extração
    /// de um update pode gerar mais de um evento de escrita em sequência
    /// rápida (pasta antiga removida, nova criada) — espera a poeira
    /// baixar antes de reler os arquivos, pra não pegar um estado
    /// intermediário.
    private func scheduleApply() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyNow() }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func applyNow() {
        // .utility: o patch de extension.js pode levar até ~1.6s em casos
        // raros (retry/backoff contra um update em andamento) — nunca na
        // main thread.
        Task.detached(priority: .utility) {
            await ClaudePatchCoordinator.applyAll(log: true)
        }
    }
}
