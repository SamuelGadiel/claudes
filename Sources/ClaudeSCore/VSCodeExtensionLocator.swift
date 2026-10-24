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

    private var appBundleName: String {
        switch self {
        case .stable: return "Visual Studio Code.app"
        case .insiders: return "Visual Studio Code - Insiders.app"
        }
    }

    /// Reads the editor's own version (distinct from the extension's) directly
    /// from its app bundle's `product.json` — no subprocess spawn (e.g. `code
    /// --version`) needed for something this static. Checks both the common
    /// system-wide and per-user install locations; nil if the editor itself
    /// isn't found there (the extension can still be located independently,
    /// since it lives under `~/.vscode[-insiders]`, not under the app bundle).
    public var installedEditorVersion: String? {
        let home = NSHomeDirectory()
        for root in ["/Applications", "\(home)/Applications"] {
            let productJSONPath = "\(root)/\(appBundleName)/Contents/Resources/app/product.json"
            guard let data = FileManager.default.contents(atPath: productJSONPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String
            else { continue }
            return version
        }
        return nil
    }
}

/// Locates the official Claude Code extension's installation on disk — the
/// entry point every patch needs before it can read/write anything. See
/// `ClaudeExtensionJSPatcher`/`ClaudeExtensionJSPatchRunner` for the actual
/// patches applied to what's found here.
public enum VSCodeExtensionLocator {
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
}
