import Foundation

/// Forwards execution to the real `claude` binary, similar to "fvm flutter" for
/// the Flutter SDK. Resolved via PATH (/usr/bin/env), never hardcoded — and
/// never via the user's shell alias, because Process doesn't inherit aliases.
public enum ClaudeGateway {
    /// Used by the final gateway (`cs <slug> ...`, `cs` alone): the `cs`
    /// process has nothing left to do afterward, so it exits with the same
    /// exit code as `claude`.
    public static func run(configDir: String?, arguments: [String]) -> Never {
        exit(execute(configDir: configDir, arguments: arguments))
    }

    /// Used when `cs` still needs to print something afterward (e.g. `cs add`
    /// calling `claude auth login` and then confirming the registration).
    @discardableResult
    public static func execute(configDir: String?, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ClaudeExecutable.resolve())
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let configDir {
            env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        } else {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        process.environment = env

        // Inherits stdio directly (no Pipe) to preserve the TTY — essential
        // for Claude Code's interactive mode to work normally.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("cs: failed to execute claude: \(error)\n".utf8))
            return 1
        }

        process.waitUntilExit()
        return process.terminationStatus
    }
}
