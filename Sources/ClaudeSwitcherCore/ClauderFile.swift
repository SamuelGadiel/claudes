import Foundation

/// .clauderc na raiz do projeto: { "account": "<slug>" }.
/// Grava o nome lógico da conta, nunca um path — por isso é seguro commitar
/// (cada pessoa resolve o slug para o próprio accounts.json local).
/// Ver plans/specs/02-integracao-vscode-sem-profiles.
struct ClauderC: Codable {
    var account: String
}

public enum ClauderFile {
    static let filename = ".clauderc"

    public struct Found {
        public let path: String
        public let account: String
    }

    /// Sobe diretórios a partir de `dir` até achar um .clauderc, igual à
    /// forma como o git resolve .git subindo até a raiz do repositório.
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
        let path = (dir as NSString).expandingTildeInPath + "/" + filename
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ClauderC(account: accountSlug))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
