import Foundation

/// Keeps per-developer files (e.g. .clauderc) out of version control.
enum GitRisk {
    /// Adds `relativeFile` to `dir`'s .gitignore if one exists there and
    /// doesn't already list it — used right after creating a per-developer
    /// file (e.g. .clauderc), so it's never accidentally committed to a
    /// shared project. Deliberately keyed off the .gitignore file itself, not
    /// off "is this a git repository": a .gitignore can exist before `git
    /// init` ever runs (e.g. prepared ahead of time) and still deserves this.
    /// No .gitignore at all -> nothing to add it to, so this is a no-op.
    static func ensureIgnored(forProjectPath dir: String, relativeFile: String, comment: String) {
        let gitignorePath = (dir as NSString).expandingTildeInPath + "/.gitignore"
        guard FileManager.default.fileExists(atPath: gitignorePath) else { return }
        guard let contents = try? String(contentsOfFile: gitignorePath, encoding: .utf8) else { return }

        let alreadyListed = contents
            .components(separatedBy: .newlines)
            .contains { $0.trimmingCharacters(in: .whitespaces) == relativeFile }
        guard !alreadyListed else { return }

        let entry = "\n# \(comment)\n\(relativeFile)\n"
        guard let entryData = entry.data(using: .utf8) else { return }
        guard let handle = FileHandle(forWritingAtPath: gitignorePath) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(entryData)
    }
}
