import Foundation

/// Resolves the absolute path of the `claude` binary, in layers from
/// cheapest to most expensive:
///
/// 1. PATH already inherited by the process — instant, covers the common
///    case (`cs` called from a terminal already has the right PATH).
/// 2. Common install locations — also instant, without spawning anything.
/// 3. PATH of the user's login shell (`ShellPath`) — only as a last
///    resort: can take seconds (measured ~2s on this machine, because of
///    prompt plugins like oh-my-zsh/powerlevel10k). Paying this cost on every
///    `cs` run from a terminal would be an unnecessary performance regression,
///    since the terminal already has the correct PATH.
///
/// Result cached per process — each `cs`/GUI app resolves it once.
public enum ClaudeExecutable {
    private static var cached: String?

    public static func resolve() -> String {
        if let cached { return cached }
        let found = resolveUncached()
        cached = found
        return found
    }

    private static func resolveUncached() -> String {
        if let path = search(in: ProcessInfo.processInfo.environment["PATH"]) {
            return path
        }
        for candidate in commonLocations() where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let path = search(in: ShellPath.resolved()) {
            return path
        }
        // We found it nowhere — return plain "claude", letting
        // Process fail with a clear error ("No such file or directory")
        // instead of getting stuck here trying more alternatives.
        return "claude"
    }

    private static func search(in path: String?) -> String? {
        guard let path else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func commonLocations() -> [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
    }
}
