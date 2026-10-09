import ClaudeSwitcherCore
import Foundation

/// Controla `claude auth login` diretamente (stdin/stdout via Pipe, sem
/// terminal visível) — login continua 100% delegado ao binário oficial,
/// nós só repassamos o código que o usuário cola de volta para o processo
/// que já está esperando por ele. Nunca implementamos nada de OAuth aqui.
@MainActor
final class LoginSessionController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case waitingForCode
        case submitting
        case success
        case failure(String)
    }

    @Published var state: State = .idle
    @Published var codeInput = ""

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var outputBuffer = ""

    func start(configDir: String) {
        cancel()
        state = .starting
        codeInput = ""
        outputBuffer = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ClaudeExecutable.resolve())
        process.arguments = ["auth", "login"]

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        process.environment = env

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        stdinHandle = stdinPipe.fileHandleForWriting
        self.process = process

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.handleOutput(text) }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.handleTermination(proc.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            state = .failure("Não consegui iniciar o login: \(error)")
        }
    }

    private func handleOutput(_ text: String) {
        outputBuffer += text
        guard case .starting = state else { return }
        // "claude auth login" abre o browser sozinho e, em seguida, mostra
        // um prompt pedindo o código colado de volta — assim que vemos
        // qualquer sinal de que está esperando, mostramos o campo. Não
        // tentamos extrair a URL do texto: ela vem com sequências de escape
        // de hyperlink do terminal (OSC 8), ficaria ilegível exibida crua.
        let lower = outputBuffer.lowercased()
        guard lower.contains("paste") || lower.contains("code") else { return }
        state = .waitingForCode
    }

    func submitCode() {
        guard let stdinHandle else { return }
        state = .submitting
        stdinHandle.write(Data((codeInput + "\n").utf8))
    }

    private func handleTermination(_ status: Int32) {
        process = nil
        stdinHandle = nil
        if status == 0 {
            state = .success
        } else if state != .idle {
            state = .failure("O processo de login terminou com código \(status).")
        }
    }

    /// Nunca mata o processo no meio de uma escrita de credencial — se o
    /// usuário cancela antes de colar o código, o processo ainda não
    /// começou a gravar nada sensível, então terminate() aqui é seguro
    /// (diferente de CredentialRefresher).
    func cancel() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        state = .idle
        codeInput = ""
        outputBuffer = ""
    }
}
