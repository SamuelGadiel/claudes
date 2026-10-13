import Foundation

/// Checks whether .vscode/settings.json is tracked by git without being in
/// .gitignore. See the risk documented in plans/specs/02-integracao-vscode-sem-profiles:
/// CLAUDE_CONFIG_DIR is a path local to the user's machine and should never
/// be committed in a shared project.
enum GitRisk {
    static func warnings(forProjectPath projectPath: String, relativeFile: String) -> [LocalizedWarning] {
        guard isInsideGitWorkTree(cwd: projectPath) else { return [] }

        if isIgnored(cwd: projectPath, relativePath: relativeFile) {
            return []
        }

        if isTracked(cwd: projectPath, relativePath: relativeFile) {
            // Deliberately just a warning, not an automatic fix (see git history
            // for a rejected attempt with `git update-index --skip-worktree`):
            // that command ignores the whole file, not just the CLAUDE_CONFIG_DIR
            // entry inside it — any other, legitimately shared setting someone adds
            // to this same file later would silently stop syncing too. Still open;
            // see plans/KANBAN.md.
            return [
                LocalizedWarning(
                    l10nKey: "WARNING: %@ is tracked in this repository and is NOT in .gitignore. "
                        + "Writing CLAUDE_CONFIG_DIR here leaks your machine's local path to the team "
                        + "and forces your account on anyone else who opens the project. Consider adding "
                        + "%@ (or the .vscode/ folder) to .gitignore before proceeding.",
                    l10nArgs: [relativeFile, relativeFile]
                )
            ]
        }

        return [
            LocalizedWarning(
                l10nKey: "Warning: %@ is not yet committed nor in this repository's .gitignore. "
                    + "If this is a shared project, add it to .gitignore before running git add.",
                l10nArgs: [relativeFile]
            )
        ]
    }

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

    private static func run(_ args: [String], cwd: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func isInsideGitWorkTree(cwd: String) -> Bool {
        run(["rev-parse", "--is-inside-work-tree"], cwd: cwd) == 0
    }

    private static func isIgnored(cwd: String, relativePath: String) -> Bool {
        run(["check-ignore", "-q", relativePath], cwd: cwd) == 0
    }

    private static func isTracked(cwd: String, relativePath: String) -> Bool {
        run(["ls-files", "--error-unmatch", relativePath], cwd: cwd) == 0
    }
}
