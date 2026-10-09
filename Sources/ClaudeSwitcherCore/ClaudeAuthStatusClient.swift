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
        case .processLaunchFailed(let detail): return "falha ao executar claude auth status: \(detail)"
        case .decoding(let detail): return "erro ao decodificar resposta de claude auth status: \(detail)"
        }
    }
}

/// Lê e-mail, organização e tipo de assinatura (Pro/Team/etc) da conta —
/// `claude auth status` já devolve isso em JSON, rápido (processo curto,
/// sem o protocolo de controle usado por UsageControlClient, que não expõe
/// e-mail). O comando retorna JSON válido tanto logado quanto deslogado
/// (sem travar esperando login interativo).
public enum ClaudeAuthStatusClient {
    public static func fetch(configDir: String, timeout: TimeInterval = 10) throws -> ClaudeAuthStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ClaudeExecutable.resolve())
        process.arguments = ["auth", "status"]

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        process.environment = env

        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

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
