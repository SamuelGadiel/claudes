import Foundation

public struct ClaudeAuthStatus: Decodable {
    public let loggedIn: Bool
    public let email: String?
    public let orgName: String?
    public let subscriptionType: String?
}

public enum ClaudeAuthStatusError: Error, CustomStringConvertible {
    case processLaunchFailed(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .processLaunchFailed(let detail): return "failed to execute claude auth status: \(detail)"
        case .decoding(let detail): return "error decoding claude auth status response: \(detail)"
        }
    }
}

/// Reads the account's email, organization, and subscription type (Pro/Team/etc) —
/// `claude auth status` already returns this as JSON, fast (short-lived process,
/// without the control protocol used by UsageControlClient, which doesn't expose
/// email). The command returns valid JSON both logged in and logged out
/// (without blocking waiting for interactive login).
public enum ClaudeAuthStatusClient {
    public static func fetch(configDir: String, timeout: TimeInterval = 10) throws -> ClaudeAuthStatus {
        let process = DisclaimedProcess()
        process.executableURL = URL(fileURLWithPath: ClaudeExecutable.resolve())
        process.arguments = ["auth", "status"]
        // Fixed to /tmp, same reasoning as CredentialRefresher: this is a
        // background utility call made by the GUI app (not the user's
        // interactive project session via `cs`), and `claude` touching
        // ~/Desktop, ~/Documents, ~/Downloads etc. during startup triggers
        // TCC prompts attributed to this app for each of those folders.
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        process.environment = env

        process.standardInput = .handle(.nullDevice)
        let stdoutPipe = Pipe()
        process.standardOutput = .pipe(stdoutPipe)
        process.standardError = .pipe(Pipe())

        do {
            try process.run()
        } catch {
            throw ClaudeAuthStatusError.processLaunchFailed("\(error)")
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        do {
            return try JSONDecoder().decode(ClaudeAuthStatus.self, from: data)
        } catch {
            throw ClaudeAuthStatusError.decoding("\(error)")
        }
    }
}
