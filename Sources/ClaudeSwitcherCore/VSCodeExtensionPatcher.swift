import Foundation

/// Extension installation root of an editor compatible with the VS Code
/// format (`<root>/extensions/anthropic.claude-code-<version>-<platform>`).
/// Today only VS Code stable and Insiders — the same official extension runs on
/// both, each with its own installed copy, so both need to
/// be patched independently if both are present. Forks like
/// Cursor/Windsurf use this same folder format and could be
/// added here in the future, but haven't been validated — out of scope
/// for now.
public enum VSCodeEditorRoot: String, CaseIterable, CustomStringConvertible {
    case stable = "~/.vscode"
    case insiders = "~/.vscode-insiders"

    public var extensionsDirPath: String {
        (rawValue as NSString).expandingTildeInPath + "/extensions"
    }

    public var description: String {
        switch self {
        case .stable: return "VS Code"
        case .insiders: return "VS Code Insiders"
        }
    }
}

public enum VSCodeExtensionPatchError: Error, CustomStringConvertible {
    case extensionNotFound
    case packageJSONUnreadable(String)
    case settingNotFound
    case unrecognizedScope(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .extensionNotFound:
            return "anthropic.claude-code extension not found"
        case .packageJSONUnreadable(let detail):
            return "could not read/decode the extension's package.json even after waiting " +
                "for it to stabilize (not an update-timing issue) — \(detail)"
        case .settingNotFound:
            return "the claudeCode.environmentVariables setting no longer exists in package.json — the extension may have changed format"
        case .unrecognizedScope(let scope):
            return "current scope ('\(scope)') is neither 'machine' (original) nor 'window' (patched) — " +
                "the extension may have changed; not touching it to avoid breaking something unknown"
        case .writeFailed(let detail):
            return "failed to write the patched package.json: \(detail)"
        }
    }
}

public struct VSCodeExtensionPatchStatus {
    public let extensionVersion: String
    public let wasAlreadyPatched: Bool
    /// Non-nil when we skipped because we detected an update in progress (empty/
    /// unstable file) — it's neither success nor error, just "try again later".
    public let skippedReason: String?
}

/// `claudeCode.environmentVariables` (which carries CLAUDE_CONFIG_DIR) is
/// declared in the official extension's `package.json` with `"scope": "machine"`
/// — per Microsoft's documentation on extension configuration scopes,
/// this means "settings that can be set only in user settings
/// or only in remote settings": VS Code **silently ignores** this
/// setting when defined in a project's `.vscode/settings.json` (workspace/
/// folder scope). This is the confirmed root cause of why switching accounts
/// on a project never had a real effect on Claude Code, even with leog's
/// patch (specs/03) applied and the window reloaded — that patch
/// solves a different problem (the extension reading `process.env` directly
/// instead of the resolved setting), not the scope restriction itself.
///
/// The fix, confirmed empirically (account switch propagated without an
/// extra reload): change that `"scope"` from `"machine"` to `"window"` in the
/// installed `package.json` — "window" settings can be defined in
/// user, workspace OR remote settings, exactly what we need (each
/// window/project with its own CLAUDE_CONFIG_DIR). `package.json` is just
/// static metadata read by VS Code's configuration engine, not
/// code to be interpreted — direct JSON editing, no JavaScriptCore.
///
/// Still needs leog's patch (`extension.js`, compiled code)
/// for the functional part: without it, even with the scope unlocked, the
/// extension still reads `process.env.CLAUDE_CONFIG_DIR` directly in some storage
/// helpers, ignoring the setting's resolved value.
public enum VSCodeExtensionPatcher {
    static let targetSetting = "claudeCode.environmentVariables"
    static let patchedScope = "window"
    static let originalScope = "machine"
    private static let backupSuffix = ".claude-switcher-scope-patch.bak"

    /// Locates the official extension's installation within a specific
    /// editor root — if there's more than one folder (rare, can happen
    /// during an update), keeps the one with the highest version.
    public static func locateExtensionDir(in root: VSCodeEditorRoot) -> String? {
        let extensionsDir = root.extensionsDirPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: extensionsDir) else {
            return nil
        }
        let candidates = entries.compactMap { entry -> (path: String, version: String)? in
            guard entry.hasPrefix("anthropic.claude-code-") else { return nil }
            guard let version = extractVersion(fromDirName: entry) else { return nil }
            return (extensionsDir + "/" + entry, version)
        }
        return candidates.max { compareVersions($0.version, $1.version) == .orderedAscending }?.path
    }

    /// One entry per editor root where the official extension is actually
    /// installed — 0, 1, or 2 today (VS Code stable/Insiders).
    public static func allExtensionDirs() -> [String] {
        VSCodeEditorRoot.allCases.compactMap { locateExtensionDir(in: $0) }
    }

    /// "anthropic.claude-code-2.1.281-darwin-arm64" -> "2.1.281"
    private static func extractVersion(fromDirName name: String) -> String? {
        let prefix = "anthropic.claude-code-"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        // version is everything up to the first "-" followed by a letter (platform:
        // darwin-arm64, darwin-x64, win32-x64, etc.) — versions are only digits and dots.
        let versionChars = rest.prefix { $0.isNumber || $0 == "." }
        return versionChars.isEmpty ? nil : String(versionChars)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rParts = rhs.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lParts.count, rParts.count) {
            let l = i < lParts.count ? lParts[i] : 0
            let r = i < rParts.count ? rParts[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    @discardableResult
    public static func ensurePatched(extensionDir: String) async throws -> VSCodeExtensionPatchStatus {
        let packageJSONPath = extensionDir + "/package.json"

        guard FileManager.default.fileExists(atPath: packageJSONPath) else {
            return VSCodeExtensionPatchStatus(
                extensionVersion: "unknown", wasAlreadyPatched: false,
                skippedReason: "package.json not found (update in progress?)"
            )
        }

        var text = try await TransientFileIO.readWithRetry(path: packageJSONPath)
        if text.isEmpty {
            return VSCodeExtensionPatchStatus(
                extensionVersion: "unknown", wasAlreadyPatched: false,
                skippedReason: "package.json empty (update in progress)"
            )
        }

        var parsed = parse(text)
        // A non-empty file with invalid JSON might be a partial
        // snapshot captured mid-rewrite — observe
        // stability before declaring a real problem (same protection
        // that ClaudeExtensionJSPatchRunner already has for extension.js).
        if parsed == nil {
            let settled = try await TransientFileIO.readUntilStable(path: packageJSONPath, initial: text)
            if settled.changed {
                text = settled.source
                if text.isEmpty {
                    return VSCodeExtensionPatchStatus(
                        extensionVersion: "unknown", wasAlreadyPatched: false,
                        skippedReason: "package.json empty (update in progress)"
                    )
                }
                parsed = parse(text)
                if parsed == nil {
                    return VSCodeExtensionPatchStatus(
                        extensionVersion: "unknown", wasAlreadyPatched: false,
                        skippedReason: "file still unstable, try again later"
                    )
                }
            }
        }

        guard var root = parsed else {
            throw VSCodeExtensionPatchError.packageJSONUnreadable(packageJSONPath)
        }

        let version = root["version"] as? String ?? "unknown"

        guard var contributes = root["contributes"] as? [String: Any],
              var configuration = contributes["configuration"] as? [String: Any],
              var properties = configuration["properties"] as? [String: Any],
              var setting = properties[targetSetting] as? [String: Any],
              let currentScope = setting["scope"] as? String
        else {
            throw VSCodeExtensionPatchError.settingNotFound
        }

        if currentScope == patchedScope {
            return VSCodeExtensionPatchStatus(extensionVersion: version, wasAlreadyPatched: true, skippedReason: nil)
        }
        guard currentScope == originalScope else {
            throw VSCodeExtensionPatchError.unrecognizedScope(currentScope)
        }

        // Backup only the first time we patch this specific version —
        // each version folder is only patched once, no incremental "undo"
        // is needed after that.
        let backupPath = packageJSONPath + backupSuffix
        if !FileManager.default.fileExists(atPath: backupPath) {
            try await TransientFileIO.retryOnTransientLock {
                try text.write(toFile: backupPath, atomically: true, encoding: .utf8)
            }
        }

        setting["scope"] = patchedScope
        properties[targetSetting] = setting
        configuration["properties"] = properties
        contributes["configuration"] = configuration
        root["contributes"] = contributes

        do {
            let patched = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
            try await TransientFileIO.retryOnTransientLock {
                try patched.write(to: URL(fileURLWithPath: packageJSONPath))
            }
        } catch {
            throw VSCodeExtensionPatchError.writeFailed("\(error)")
        }

        return VSCodeExtensionPatchStatus(extensionVersion: version, wasAlreadyPatched: false, skippedReason: nil)
    }

    private static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
