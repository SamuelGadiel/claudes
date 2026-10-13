import Foundation

/// Installs (or updates) a symbolic link to the running `cs` binary
/// inside a directory that is already in the user's PATH — the same pattern
/// as VS Code's "Shell Command: Install 'code' in PATH", or Docker Desktop's
/// "docker". Reusable both by the CLI itself (`cs install-cli`) and
/// by the future status bar GUI on first launch — neither does
/// more than this; there's no IPC or dependency between the two binaries.
public enum ShellInstallError: Error, CustomStringConvertible {
    case noWritableDirectory([String])

    public var description: String {
        switch self {
        case .noWritableDirectory(let tried):
            return "Could not find a writable directory to install 'cs' (tried: "
                + "\(tried.joined(separator: ", "))). Run with sudo, or create one of the "
                + "directories above and add it to PATH manually."
        }
    }
}

public struct ShellInstallResult {
    /// `cs`'s own link — kept as the primary path for backward compatibility
    /// with anything already reading this result's old shape.
    public let linkPath: String
    public let targetPath: String
    public let linkDirInPath: Bool
    /// The `claudes` alias installed alongside `cs`, same directory, same
    /// target — identical behavior either way, since the CLI only ever
    /// looks at its arguments, never at which name it was invoked as.
    public let aliasLinkPath: String
}

public enum ShellInstall {
    /// In order of preference: /usr/local/bin is the conventional destination on
    /// macOS for binaries installed outside a package manager (it almost
    /// always already exists and is already in the PATH of any standard shell);
    /// ~/.local/bin is the fallback that doesn't need elevated permission.
    static let candidateDirs = [
        "/usr/local/bin",
        ("~/.local/bin" as NSString).expandingTildeInPath,
    ]

    /// Absolute path of the `cs` binary currently running, with symlinks
    /// resolved. Deliberately dynamic (not hardcoded): the .app may
    /// be in ~/Applications, /Applications, or be run via `swift run`
    /// during development.
    public static func currentExecutablePath() -> String {
        let arg0 = CommandLine.arguments[0]
        let absolute = arg0.hasPrefix("/")
            ? arg0
            : FileManager.default.currentDirectoryPath + "/" + arg0
        return (absolute as NSString).resolvingSymlinksInPath
    }

    @discardableResult
    public static func install() throws -> ShellInstallResult {
        let target = currentExecutablePath()
        let fm = FileManager.default

        for dir in candidateDirs {
            if !fm.fileExists(atPath: dir) {
                // ~/.local/bin may not exist yet; we only create it inside the
                // user's home — never under /usr/local unless it already exists.
                guard dir.hasPrefix(NSHomeDirectory()) else { continue }
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            guard fm.isWritableFile(atPath: dir) else { continue }

            guard let csLink = ensureLink(named: "cs", to: target, in: dir, fm: fm) else { continue }
            // Best-effort: if `cs` installed but `claudes` somehow can't
            // (shouldn't happen, same dir/target just confirmed writable),
            // still return success for `cs` rather than failing the whole
            // install over the alias.
            let claudesLink = ensureLink(named: "claudes", to: target, in: dir, fm: fm) ?? (dir + "/claudes")

            return ShellInstallResult(
                linkPath: csLink, targetPath: target, linkDirInPath: pathContains(dir),
                aliasLinkPath: claudesLink
            )
        }

        throw ShellInstallError.noWritableDirectory(candidateDirs)
    }

    /// Creates (or repoints) `<dir>/<name>` as a symlink to `target`. Returns
    /// nil only on an actual filesystem failure — not finding anything to
    /// change (already correct) still returns the path.
    private static func ensureLink(named name: String, to target: String, in dir: String, fm: FileManager) -> String? {
        let linkPath = dir + "/" + name

        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath), existing == target {
            return linkPath
        }
        if fm.fileExists(atPath: linkPath) {
            try? fm.removeItem(atPath: linkPath)
        }

        do {
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
            return linkPath
        } catch {
            return nil
        }
    }

    private static func pathContains(_ dir: String) -> Bool {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return pathEnv.split(separator: ":").map(String.init).contains(dir)
    }
}
