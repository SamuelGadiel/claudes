import Foundation

/// Roda os dois patches da extensão oficial do Claude Code em sequência —
/// são independentes entre si (um edita `package.json`, o outro
/// `extension.js`), mas ambos precisam estar aplicados para a troca de
/// conta funcionar de ponta a ponta: o patch de scope faz o VS Code aceitar
/// `claudeCode.environmentVariables` vindo de workspace settings, e o
/// patch de `extension.js` faz os storage helpers da extensão enxergarem
/// esse valor dentro do próprio processo dela (não só em subprocessos que
/// ela lança). Aplica em cada instalação da extensão encontrada (VS Code
/// estável e/ou Insiders, se ambos estiverem presentes — ver
/// `VSCodeEditorRoot`). Chamado tanto no startup/watcher automático quanto
/// no item manual "Reaplicar patch" do menu.
public enum ClaudePatchCoordinator {
    public struct Entry {
        public let root: VSCodeEditorRoot
        public let scopeMessage: String
        public let jsMessage: String
    }

    public struct Summary {
        public let entries: [Entry]
        /// true só para falhas reais (ex: extension.js mudou de formato) —
        /// nunca para "nenhuma instalação encontrada", que é esperado em
        /// quem só usa o terminal.
        public let hadRealError: Bool
    }

    @discardableResult
    public static func applyAll(log: Bool) async -> Summary {
        var entries: [Entry] = []
        var hadRealError = false

        for root in VSCodeEditorRoot.allCases {
            guard let extensionDir = VSCodeExtensionPatcher.locateExtensionDir(in: root) else { continue }

            let scopeMessage: String
            do {
                let status = try await VSCodeExtensionPatcher.ensurePatched(extensionDir: extensionDir)
                if let reason = status.skippedReason {
                    scopeMessage = "scope pulado (\(reason))"
                } else {
                    scopeMessage = status.wasAlreadyPatched
                        ? "scope já aplicado (extensão \(status.extensionVersion))"
                        : "scope aplicado agora (extensão \(status.extensionVersion))"
                }
            } catch {
                scopeMessage = "erro no patch de scope — \(error)"
                hadRealError = true
            }

            let jsMessage: String
            do {
                let status = try await ClaudeExtensionJSPatchRunner.ensurePatched(extensionDir: extensionDir)
                if !status.changes.isEmpty {
                    jsMessage = "extension.js patchado agora (\(status.changes.joined(separator: ", ")))"
                } else if let reason = status.skippedReason {
                    jsMessage = "extension.js pulado (\(reason))"
                } else {
                    jsMessage = "extension.js já patchado"
                }
            } catch {
                jsMessage = "erro no patch de extension.js — \(error)"
                hadRealError = true
            }

            entries.append(Entry(root: root, scopeMessage: scopeMessage, jsMessage: jsMessage))
        }

        if log {
            if entries.isEmpty {
                NSLog("claude-switcher: nenhuma instalação da extensão Claude encontrada (VS Code/Insiders)")
            } else {
                for entry in entries {
                    NSLog("claude-switcher: patch da extensão Claude (\(entry.root)) — \(entry.scopeMessage); \(entry.jsMessage)")
                }
            }
        }

        return Summary(entries: entries, hadRealError: hadRealError)
    }
}
