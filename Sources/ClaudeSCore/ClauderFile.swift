import Foundation

/// .clauderc at the project root: { "account": "<slug>" }.
/// Stores the account's logical name, never a path — which is why it's safe to
/// commit (each person resolves the slug against their own local accounts.json).
/// See plans/specs/02-integracao-vscode-sem-profiles.
struct ClauderC: Codable {
    var account: String
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
                return Found(path: candidate, account: parsed.account)
            }

            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { return nil }
            current = parent
        }
    }

    public static func write(accountSlug: String, inDir dir: String) throws {
        let expandedDir = (dir as NSString).expandingTildeInPath
        let path = expandedDir + "/" + filename
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ClauderC(account: accountSlug))
        try data.write(to: URL(fileURLWithPath: path))
        GitRisk.ensureIgnored(
            forProjectPath: expandedDir, relativeFile: filename,
            comment: "Per-developer Claude account selection (claudes) — not shared with the team"
        )
    }
}
