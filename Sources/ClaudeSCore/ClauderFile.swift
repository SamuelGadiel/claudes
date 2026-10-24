import Foundation

/// A single `{name, value}` entry — same shape VS Code's own
/// `claudeCode.environmentVariables` setting uses, kept identical on purpose
/// so the extension-side patch (specs/03) can read this file exactly the
/// same way it already reads that setting, no new parsing logic needed there.
struct ClauderEnvVar: Codable {
    var name: String
    var value: String
}

/// .clauderc at the project root. Two fields:
/// - `claude_account`: the account's logical name (slug), never a path —
///   portable across machines, safe to commit if a team wants to share it.
/// - `claudeCode.environmentVariables`: resolved locally on this machine
///   every time the account is written here. Not portable (carries a real
///   local path) — that's why `write` always keeps this file out of version
///   control (see `GitRisk.ensureIgnored`), regardless of whether the
///   `claude_account` field alone would have been safe to share.
/// See plans/specs/02-integracao-vscode-sem-profiles.
struct ClauderC: Codable {
    var claudeAccount: String
    var environmentVariables: [ClauderEnvVar]?

    enum CodingKeys: String, CodingKey {
        case claudeAccount = "claude_account"
        case environmentVariables = "claudeCode.environmentVariables"
    }
}

public enum ClauderFile {
    static let filename = ".clauderc"

    public struct Found {
        public let path: String
        public let account: String
    }

    /// Walks up directories starting from `dir` until it finds a .clauderc, the
    /// same way git resolves .git by walking up to the repository root.
    public static func find(startingAt dir: String) -> Found? {
        let fm = FileManager.default
        var current = (dir as NSString).standardizingPath

        while true {
            let candidate = current + "/" + filename
            if fm.fileExists(atPath: candidate),
               let data = fm.contents(atPath: candidate),
               let parsed = try? JSONDecoder().decode(ClauderC.self, from: data) {
                return Found(path: candidate, account: parsed.claudeAccount)
            }

            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { return nil }
            current = parent
        }
    }

    public static func write(account: RegisteredAccount, inDir dir: String) throws {
        let expandedDir = (dir as NSString).expandingTildeInPath
        let path = expandedDir + "/" + filename
        // CLAUDE_CONFIG_DIR goes into a process's environment, which doesn't
        // expand "~" on its own (that's done by the shell, not by whoever reads
        // the env var) — always write the absolute path.
        let expandedConfigDir = (account.configDir as NSString).expandingTildeInPath
        let envVars = [ClauderEnvVar(name: "CLAUDE_CONFIG_DIR", value: expandedConfigDir)]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ClauderC(claudeAccount: account.slug, environmentVariables: envVars))
        try data.write(to: URL(fileURLWithPath: path))
        GitRisk.ensureIgnored(
            forProjectPath: expandedDir, relativeFile: filename,
            comment: "Per-developer Claude account selection (claudes) — not shared with the team"
        )
    }
}
