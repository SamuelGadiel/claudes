import Foundation

public enum ClaudeExtensionJSPatchError: Error, CustomStringConvertible {
    case extensionNotFound
    case envPatchPointNotFound(version: String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .extensionNotFound:
            return "anthropic.claude-code extension not found"
        case .envPatchPointNotFound(let version):
            return "could not find the expected patch point in extension.js for version \(version) — " +
                "Anthropic may have changed the minified format; the regexes need updating"
        case .writeFailed(let detail):
            return "failed to write patched extension.js: \(detail)"
        }
    }
}

public struct ClaudeExtensionJSPatchStatus {
    public let extensionVersion: String
    /// Empty when everything was already applied, or when we skipped because we detected
    /// an update in progress (see `skippedReason`).
    public let changes: [String]
    public let skippedReason: String?
    /// The state of each sub-patch *before* this call — nil only when we
    /// skipped before ever analyzing the file. Combined with `changes`, this
    /// is what lets a caller (e.g. `ClaudePatchCoordinator`) report each
    /// sub-patch ("env", "clauderc"...) as its own already-applied/applied-now
    /// outcome, without this type needing to know about that reporting shape.
    public let analysisBeforePatch: ClaudeExtensionJSPatcher.Analysis?
}

/// I/O around `ClaudeExtensionJSPatcher` (the pure analysis/transform
/// logic) — locate the installed `extension.js`, read with
/// retry/backoff (the extension may be in the middle of an update, file
/// momentarily empty or partial), make a backup, write with retry in
/// case of a transient lock. Same protections that
/// `leog/claude-code-config-dir-patcher-vscode` uses (see ATTRIBUTIONS.md),
/// adapted from callbacks/setTimeout to Swift Concurrency — see
/// `TransientFileIO` (shared with `VSCodeExtensionLocator`).
public enum ClaudeExtensionJSPatchRunner {
    private static let backupSuffix = ".claudes-js-patch.bak"

    @discardableResult
    public static func ensurePatched(extensionDir: String) async throws -> ClaudeExtensionJSPatchStatus {
        let jsPath = extensionDir + "/extension.js"
        let version = extensionVersion(extensionDir: extensionDir)

        guard FileManager.default.fileExists(atPath: jsPath) else {
            return ClaudeExtensionJSPatchStatus(
                extensionVersion: version, changes: [],
                skippedReason: "extension.js not found (update in progress?)", analysisBeforePatch: nil
            )
        }

        var source = try await TransientFileIO.readWithRetry(path: jsPath)
        if source.isEmpty {
            return ClaudeExtensionJSPatchStatus(
                extensionVersion: version, changes: [],
                skippedReason: "extension.js empty (update in progress)", analysisBeforePatch: nil
            )
        }

        var status = ClaudeExtensionJSPatcher.analyze(source)

        // A non-empty file without the patch point might be a partial
        // snapshot captured mid-rewrite — observe stability
        // before declaring a real problem.
        if !status.envPatched, !status.envPatchable {
            let settled = try await TransientFileIO.readUntilStable(path: jsPath, initial: source)
            if settled.changed {
                source = settled.source
                if source.isEmpty {
                    return ClaudeExtensionJSPatchStatus(
                        extensionVersion: version, changes: [],
                        skippedReason: "extension.js empty (update in progress)", analysisBeforePatch: nil
                    )
                }
                status = ClaudeExtensionJSPatcher.analyze(source)
                if !status.envPatched, !status.envPatchable {
                    return ClaudeExtensionJSPatchStatus(
                        extensionVersion: version, changes: [],
                        skippedReason: "file still unstable, try again later", analysisBeforePatch: nil
                    )
                }
            }
        }

        guard status.envPatched || status.envPatchable else {
            throw ClaudeExtensionJSPatchError.envPatchPointNotFound(version: version)
        }

        let result = ClaudeExtensionJSPatcher.applyPatch(source)
        guard !result.changes.isEmpty else {
            return ClaudeExtensionJSPatchStatus(
                extensionVersion: version, changes: [], skippedReason: nil, analysisBeforePatch: status
            )
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

        return ClaudeExtensionJSPatchStatus(
            extensionVersion: version, changes: result.changes, skippedReason: nil, analysisBeforePatch: status
        )
    }

    private static func extensionVersion(extensionDir: String) -> String {
        guard let data = FileManager.default.contents(atPath: extensionDir + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "unknown" }
        return json["version"] as? String ?? "unknown"
    }
}
