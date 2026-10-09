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
    public let linkPath: String
    public let targetPath: String
    public let linkDirInPath: Bool
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

            let linkPath = dir + "/cs"

            if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath), existing == target {
                return ShellInstallResult(
                    linkPath: linkPath, targetPath: target, linkDirInPath: pathContains(dir)
                )
            }
            if fm.fileExists(atPath: linkPath) {
                try? fm.removeItem(atPath: linkPath)
            }

            do {
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                return ShellInstallResult(
                    linkPath: linkPath, targetPath: target, linkDirInPath: pathContains(dir)
                )
            } catch {
                continue
            }
        }

        throw ShellInstallError.noWritableDirectory(candidateDirs)
    }

    private static func pathContains(_ dir: String) -> Bool {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return pathEnv.split(separator: ":").map(String.init).contains(dir)
    }
}
