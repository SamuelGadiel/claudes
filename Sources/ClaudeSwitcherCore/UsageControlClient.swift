import Foundation

public enum UsageControlError: Error, CustomStringConvertible {
    case processLaunchFailed(String)
    case timeout
    case decoding(Error)

    public var description: String {
        switch self {
        case .processLaunchFailed(let detail): return "failed to execute claude: \(detail)"
        case .timeout: return "claude did not respond in time"
        case .decoding(let error): return "error decoding response: \(error)"
        }
    }
}

/// Fetches the account's real usage by invoking the `claude` binary itself in the
/// protocol mode the Claude Agent SDK uses (`--input-format stream-json
/// --output-format stream-json`) and sending a control_request
/// `{"subtype":"get_usage"}` — the SAME mechanism the official VS Code
/// extension uses for the "Account & Usage" screen (confirmed by reading
/// `extension.js`: `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET`
/// sends `{subtype:"get_usage"}`).
///
/// This replaces `UsageAPIClient` (direct HTTP call to
/// `/api/oauth/usage`) as the primary source: that endpoint consistently
/// and inexplicably failed for the Personal account (recurring rate limit or
/// 401) while claude.ai, the CLI, and the extension always
/// worked — delegating the real call to the official binary (which knows
/// how to authenticate/call correctly, however it decides internally)
/// eliminates that behavioral difference. Works on demand, without
/// requiring any active session or prior interaction.
public enum UsageControlClient {
    public static func fetch(configDir: String, timeout: TimeInterval = 10) throws -> UsageResponse {
        let process = DisclaimedProcess()
        process.executableURL = URL(fileURLWithPath: ClaudeExecutable.resolve())
        process.arguments = [
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "-p",
        ]
        // Fixed to /tmp, same reasoning as CredentialRefresher: this is a
        // background utility call made by the GUI app (not the user's
        // interactive project session via `cs`), and `claude` touching
        // ~/Desktop, ~/Documents, ~/Downloads etc. during startup triggers
        // TCC prompts attributed to this app for each of those folders.
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = .pipe(stdinPipe)
        process.standardOutput = .pipe(stdoutPipe)
        process.standardError = .pipe(Pipe())

        let requestId = "cs-\(UUID().uuidString.prefix(8))"
        let semaphore = DispatchSemaphore(value: 0)
        var resultLine: Data?
        var buffer = Data()
        let newline = Data([0x0A])

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)

            while let range = buffer.range(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)

                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "control_response",
                      let response = obj["response"] as? [String: Any],
                      response["request_id"] as? String == requestId
                else { continue }

                resultLine = line
                semaphore.signal()
            }
        }

        do {
            try process.run()
        } catch {
            throw UsageControlError.processLaunchFailed("\(error)")
        }

        let requestJSON = "{\"type\":\"control_request\",\"request_id\":\"\(requestId)\"," +
            "\"request\":{\"subtype\":\"get_usage\"}}\n"
        stdinPipe.fileHandleForWriting.write(Data(requestJSON.utf8))

        let waitResult = semaphore.wait(timeout: .now() + timeout)

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            // Terminate here is safe: this is a read (get_usage), not
            // a credential renewal flow in the middle of a write —
            // unlike CredentialRefresher, which never kills the process.
            // SIGTERM alone was observed not being enough: `claude` in this
            // mode can ignore it and keep running indefinitely (confirmed by
            // leaked zombie processes accumulating over repeated calls) —
            // escalate to SIGKILL after a short grace period.
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            process.forceTerminate()
        }

        guard waitResult == .success, let line = resultLine else {
            throw UsageControlError.timeout
        }

        return try decode(line)
    }

    private struct Envelope: Decodable {
        struct OuterResponse: Decodable {
            struct InnerPayload: Decodable {
                let rateLimits: RateLimitsPayload?
                enum CodingKeys: String, CodingKey {
                    case rateLimits = "rate_limits"
                }
            }
            let response: InnerPayload?
        }
        let response: OuterResponse
    }

    private struct RateLimitsPayload: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let extraUsage: ExtraUsage?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case extraUsage = "extra_usage"
        }
    }

    private static func decode(_ data: Data) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try UsageDateParsing.decode($0) }
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            let rateLimits = envelope.response.response?.rateLimits
            return UsageResponse(
                fiveHour: rateLimits?.fiveHour,
                sevenDay: rateLimits?.sevenDay,
                sevenDayOpus: rateLimits?.sevenDayOpus,
                extraUsage: rateLimits?.extraUsage
            )
        } catch {
            throw UsageControlError.decoding(error)
        }
    }
}
