import Foundation

public enum UsageControlError: Error, CustomStringConvertible {
    case processLaunchFailed(String)
    case timeout
    case decoding(Error)

    public var description: String {
        switch self {
        case .processLaunchFailed(let detail): return "falha ao executar claude: \(detail)"
        case .timeout: return "claude não respondeu a tempo"
        case .decoding(let error): return "erro ao decodificar resposta: \(error)"
        }
    }
}

/// Busca o uso real da conta invocando o próprio binário `claude` no modo de
/// protocolo que o Claude Agent SDK usa (`--input-format stream-json
/// --output-format stream-json`) e mandando uma control_request
/// `{"subtype":"get_usage"}` — o MESMO mecanismo que a extensão oficial do
/// VS Code usa para a tela "Account & Usage" (confirmado lendo
/// `extension.js`: `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET`
/// manda `{subtype:"get_usage"}`).
///
/// Isto substitui `UsageAPIClient` (chamada HTTP direta a
/// `/api/oauth/usage`) como fonte primária: aquele endpoint falhava de
/// forma consistente e inexplicada para a conta Pessoal (rate limit ou
/// 401 recorrentes) enquanto claude.ai, o CLI e a extensão sempre
/// funcionaram — delegar a chamada real para o binário oficial (que sabe
/// se autenticar/chamar corretamente, decida lá dentro como decidir)
/// elimina essa diferença de comportamento. Funciona sob demanda, sem
/// exigir nenhuma sessão ativa nem interação prévia.
public enum UsageControlClient {
    public static func fetch(configDir: String, timeout: TimeInterval = 10) throws -> UsageResponse {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ClaudeExecutable.resolve())
        process.arguments = [
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "-p",
        ]

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

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
            // Terminate aqui é seguro: isto é uma leitura (get_usage), não
            // um fluxo de renovação de credencial no meio de uma escrita —
            // diferente de CredentialRefresher, que nunca mata o processo.
            process.terminate()
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
