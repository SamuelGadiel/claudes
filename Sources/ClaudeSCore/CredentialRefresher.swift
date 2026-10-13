import Foundation

/// Forces the renewal of an expired access token before calling
/// /api/oauth/usage. Validated recipe (see plans/specs/06, inspired by
/// claude-macos-menu-usage, MIT):
///
/// - `claude mcp list` is the command confirmed to actually hit an
///   authenticated endpoint — `claude auth status` only reports cached state and
///   NEVER triggers the OAuth refresh, even with an expired token.
/// - Via the user's login shell (`-i -l`): necessary because a GUI app
///   launched by Finder/LaunchServices does not inherit the terminal's PATH
///   (unlike `cs`, which already runs inside a terminal with the right PATH).
/// - `cwd` fixed to /tmp: avoids triggering TCC prompts by touching
///   ~/Desktop, ~/Documents, etc.
/// - NEVER sends SIGTERM to the process: interrupting it mid-write causes
///   Claude Code to move the credential out of the Keychain. If the timeout
///   expires, we simply stop waiting — the process keeps running on its own.
public enum CredentialRefresher {
    @discardableResult
    public static func refreshInBackground(configDir: String, timeout: TimeInterval = 15) -> Bool {
        let process = DisclaimedProcess()
        process.executableURL = URL(fileURLWithPath: ShellPath.loginShell())
        process.arguments = ["-i", "-l", "-c", "command -v claude >/dev/null 2>&1 && claude mcp list"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        process.environment = env

        process.standardInput = .handle(.nullDevice)
        process.standardOutput = .handle(.nullDevice)
        process.standardError = .handle(.nullDevice)

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
