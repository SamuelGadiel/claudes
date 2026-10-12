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
///
/// Outcomes are returned as structured data, not pre-formatted English
/// strings — this is Core (no UI/localization concerns); the App layer is
/// the one that turns each case into a localized message.
public enum ClaudePatchCoordinator {
    public enum ScopeOutcome {
        case alreadyApplied(extensionVersion: String)
        case appliedNow(extensionVersion: String)
        case skipped(reason: String)
        case error(String)

        public var extensionVersion: String? {
            switch self {
            case .alreadyApplied(let version), .appliedNow(let version): return version
            case .skipped, .error: return nil
            }
        }
    }

    public enum JSOutcome {
        case alreadyPatched
        case patchedNow(changes: [String])
        case skipped(reason: String)
        case error(String)
    }

    public struct Entry {
        public let root: VSCodeEditorRoot
        public let editorVersion: String?
        public let scope: ScopeOutcome
        public let js: JSOutcome
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

            let scope: ScopeOutcome
            do {
                let status = try await VSCodeExtensionPatcher.ensurePatched(extensionDir: extensionDir)
                if let reason = status.skippedReason {
                    scope = .skipped(reason: reason)
                } else {
                    scope = status.wasAlreadyPatched
                        ? .alreadyApplied(extensionVersion: status.extensionVersion)
                        : .appliedNow(extensionVersion: status.extensionVersion)
                }
            } catch {
                scope = .error("\(error)")
                hadRealError = true
            }

            let js: JSOutcome
            do {
                let status = try await ClaudeExtensionJSPatchRunner.ensurePatched(extensionDir: extensionDir)
                if !status.changes.isEmpty {
                    js = .patchedNow(changes: status.changes)
                } else if let reason = status.skippedReason {
                    js = .skipped(reason: reason)
                } else {
                    js = .alreadyPatched
                }
            } catch {
                js = .error("\(error)")
                hadRealError = true
            }

            entries.append(Entry(root: root, editorVersion: root.installedEditorVersion, scope: scope, js: js))
        }

        if log {
            if entries.isEmpty {
                NSLog("claude-switcher: no Claude extension installation found (VS Code/Insiders)")
            } else {
                for entry in entries {
                    NSLog("claude-switcher: Claude extension patch (\(entry.root)) — \(entry.scope); \(entry.js)")
                }
            }
        }

        return Summary(entries: entries, hadRealError: hadRealError)
    }
}

extension ClaudePatchCoordinator.ScopeOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyApplied(let version): return "scope already applied (extension \(version))"
        case .appliedNow(let version): return "scope applied now (extension \(version))"
        case .skipped(let reason): return "scope skipped (\(reason))"
        case .error(let detail): return "error in scope patch — \(detail)"
        }
    }
}

extension ClaudePatchCoordinator.JSOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyPatched: return "extension.js already patched"
        case .patchedNow(let changes): return "extension.js patched now (\(changes.joined(separator: ", ")))"
        case .skipped(let reason): return "extension.js skipped (\(reason))"
        case .error(let detail): return "error in extension.js patch — \(detail)"
        }
    }
}
