import Foundation

/// Runs the two patches of the official Claude Code extension in sequence —
/// they're independent of each other (one edits `package.json`, the other
/// `extension.js`), but both need to be applied for the account switch
/// to work end to end: the scope patch makes VS Code accept
/// `claudeCode.environmentVariables` coming from workspace settings, and the
/// `extension.js` patch makes the extension's storage helpers see
/// that value within its own process (not only in subprocesses it
/// launches). Applies to every extension installation found (VS Code
/// stable and/or Insiders, if both are present — see
/// `VSCodeEditorRoot`). Called both on automatic startup/watcher and
/// from the manual "Reapply patch" menu item.
public enum ClaudePatchCoordinator {
    public struct Entry {
        public let root: VSCodeEditorRoot
        public let scopeMessage: String
        public let jsMessage: String
    }

    public struct Summary {
        public let entries: [Entry]
        /// true only for real failures (e.g. extension.js changed format) —
        /// never for "no installation found", which is expected for
        /// anyone who only uses the terminal.
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
                    scopeMessage = "scope skipped (\(reason))"
                } else {
                    scopeMessage = status.wasAlreadyPatched
                        ? "scope already applied (extension \(status.extensionVersion))"
                        : "scope applied now (extension \(status.extensionVersion))"
                }
            } catch {
                scopeMessage = "error in scope patch — \(error)"
                hadRealError = true
            }

            let jsMessage: String
            do {
                let status = try await ClaudeExtensionJSPatchRunner.ensurePatched(extensionDir: extensionDir)
                if !status.changes.isEmpty {
                    jsMessage = "extension.js patched now (\(status.changes.joined(separator: ", ")))"
                } else if let reason = status.skippedReason {
                    jsMessage = "extension.js skipped (\(reason))"
                } else {
                    jsMessage = "extension.js already patched"
                }
            } catch {
                jsMessage = "error in extension.js patch — \(error)"
                hadRealError = true
            }

            entries.append(Entry(root: root, scopeMessage: scopeMessage, jsMessage: jsMessage))
        }

        if log {
            if entries.isEmpty {
                NSLog("claude-switcher: no Claude extension installation found (VS Code/Insiders)")
            } else {
                for entry in entries {
                    NSLog("claude-switcher: Claude extension patch (\(entry.root)) — \(entry.scopeMessage); \(entry.jsMessage)")
                }
            }
        }

        return Summary(entries: entries, hadRealError: hadRealError)
    }
}
