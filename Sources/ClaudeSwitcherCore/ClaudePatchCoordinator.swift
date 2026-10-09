import Foundation

/// Roda os dois patches da extensão oficial do Claude Code em sequência —
/// são independentes entre si (um edita `package.json`, o outro
/// `extension.js`), mas ambos precisam estar aplicados para a troca de
/// conta funcionar de ponta a ponta: o patch de scope faz o VS Code aceitar
/// `claudeCode.environmentVariables` vindo de workspace settings, e o
/// patch de `extension.js` faz os storage helpers da extensão enxergarem
/// esse valor dentro do próprio processo dela (não só em subprocessos que
/// ela lança). Chamado tanto no startup/watcher automático quanto no item
/// manual "Reaplicar patch" do menu.
public enum ClaudePatchCoordinator {
    public struct Summary {
        public let scopeMessage: String
        public let jsMessage: String
        /// true só para falhas reais (ex: extension.js mudou de formato) —
        /// nunca para "extensão não instalada", que é esperado em quem só
        /// usa o terminal.
        public let hadRealError: Bool
    }

    @discardableResult
    public static func applyAll(log: Bool) async -> Summary {
        var hadRealError = false

        let scopeMessage: String
        do {
            let status = try VSCodeExtensionPatcher.ensurePatched()
            scopeMessage = status.wasAlreadyPatched
                ? "scope já aplicado (extensão \(status.extensionVersion))"
                : "scope aplicado agora (extensão \(status.extensionVersion))"
        } catch VSCodeExtensionPatchError.extensionNotFound {
            scopeMessage = "extensão Claude não encontrada"
        } catch {
            scopeMessage = "erro no patch de scope — \(error)"
            hadRealError = true
        }

        let jsMessage: String
        do {
            let status = try await ClaudeExtensionJSPatchRunner.ensurePatched()
            if !status.changes.isEmpty {
                jsMessage = "extension.js patchado agora (\(status.changes.joined(separator: ", ")))"
            } else if let reason = status.skippedReason {
                jsMessage = "extension.js pulado (\(reason))"
            } else {
                jsMessage = "extension.js já patchado"
            }
        } catch ClaudeExtensionJSPatchError.extensionNotFound {
            jsMessage = "extensão Claude não encontrada"
        } catch {
            jsMessage = "erro no patch de extension.js — \(error)"
            hadRealError = true
        }

        if log {
            NSLog("claude-switcher: patch da extensão Claude — \(scopeMessage); \(jsMessage)")
        }

        return Summary(scopeMessage: scopeMessage, jsMessage: jsMessage, hadRealError: hadRealError)
    }
}
