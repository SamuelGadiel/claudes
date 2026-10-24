import Foundation

/// Runs the patches of the official Claude Code extension's `extension.js`
/// (see `ClaudeExtensionJSPatcher`) and reports each sub-patch separately —
/// "clauderc" (reads our own file, highest priority) and "env" (the
/// propagation fix that distributes whatever's resolved to every internal
/// reader). Both live in the same file and are applied/read together, but
/// reported as two independent outcomes since they can fail independently.
/// Applies to every extension installation found (VS Code stable and/or
/// Insiders, if both are present — see `VSCodeEditorRoot`). Called both on
/// automatic startup/watcher and from the manual "Reapply patch" menu item.
///
/// Outcomes are returned as structured data, not pre-formatted English
/// strings — this is Core (no UI/localization concerns); the App layer is
/// the one that turns each case into a localized message.
public enum ClaudePatchCoordinator {
    public enum SubPatchOutcome {
        case alreadyApplied
        case appliedNow
        case skipped(reason: String)
        case error(String)
    }

    public struct Entry {
        public let root: VSCodeEditorRoot
        public let editorVersion: String?
        public let extensionVersion: String?
        public let clauderc: SubPatchOutcome
        public let env: SubPatchOutcome
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
            guard let extensionDir = VSCodeExtensionLocator.locateExtensionDir(in: root) else { continue }

            var extensionVersion: String?
            let clauderc: SubPatchOutcome
            let env: SubPatchOutcome

            do {
                let status = try await ClaudeExtensionJSPatchRunner.ensurePatched(extensionDir: extensionDir)
                extensionVersion = status.extensionVersion
                if let reason = status.skippedReason {
                    clauderc = .skipped(reason: reason)
                    env = .skipped(reason: reason)
                } else {
                    let before = status.analysisBeforePatch
                    clauderc = Self.outcome(
                        wasAlreadyPatched: before?.clauderPatched == true,
                        appliedNow: status.changes.contains("clauderc")
                    )
                    env = Self.outcome(
                        wasAlreadyPatched: before?.envPatched == true,
                        appliedNow: status.changes.contains("env")
                    )
                }
            } catch {
                clauderc = .error("\(error)")
                env = .error("\(error)")
                hadRealError = true
            }

            entries.append(Entry(
                root: root, editorVersion: root.installedEditorVersion, extensionVersion: extensionVersion,
                clauderc: clauderc, env: env
            ))
        }

        if log {
            if entries.isEmpty {
                NSLog("claudes: no Claude extension installation found (VS Code/Insiders)")
            } else {
                for entry in entries {
                    NSLog("claudes: Claude extension patch (\(entry.root)) — clauderc: \(entry.clauderc); env: \(entry.env)")
                }
            }
        }

        return Summary(entries: entries, hadRealError: hadRealError)
    }

    private static func outcome(wasAlreadyPatched: Bool, appliedNow: Bool) -> SubPatchOutcome {
        if wasAlreadyPatched { return .alreadyApplied }
        if appliedNow { return .appliedNow }
        return .skipped(reason: "patch point not found in this extension.js version")
    }
}

extension ClaudePatchCoordinator.SubPatchOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyApplied: return "already applied"
        case .appliedNow: return "applied now"
        case .skipped(let reason): return "skipped (\(reason))"
        case .error(let detail): return "error — \(detail)"
        }
    }
}
