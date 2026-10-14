import ClaudeSCore
import Foundation

/// Controls `claude auth login` directly (stdin/stdout via Pipe, no
/// visible terminal) — login remains 100% delegated to the official binary,
/// we only pass the code the user pastes back to the process
/// that's already waiting for it. We never implement any OAuth here.
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

    private var process: DisclaimedProcess?
    private var stdinHandle: FileHandle?
    private var outputBuffer = ""

    func start(configDir: String) {
        cancel()
        state = .starting
        codeInput = ""
        outputBuffer = ""

        let process = DisclaimedProcess()
        process.executableURL = URL(fileURLWithPath: ClaudeExecutable.resolve())
        process.arguments = ["auth", "login"]
        // Fixed to /tmp: this is a background utility call made by the GUI
        // app (not the user's interactive project session via `cs`), and
        // `claude` touching ~/Desktop, ~/Documents, ~/Downloads etc. during
        // startup triggers TCC prompts attributed to this app for each of
        // those folders.
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        process.environment = env

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = .pipe(stdinPipe)
        process.standardOutput = .pipe(outputPipe)
        process.standardError = .pipe(outputPipe)

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
            state = .failure(String(
                format: NSLocalizedString("Could not start login: %@", bundle: AppResources.bundle, comment: ""),
                error.localizedForDisplay
            ))
        }
    }

    private func handleOutput(_ text: String) {
        outputBuffer += text
        guard case .starting = state else { return }
        // "claude auth login" opens the browser on its own and then shows
        // a prompt asking for the code to be pasted back — as soon as we see
        // any sign that it's waiting, we show the field. We don't
        // try to extract the URL from the text: it comes with terminal
        // hyperlink escape sequences (OSC 8), it would be unreadable shown raw.
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
            state = .failure(String(
                format: NSLocalizedString("The login process exited with code %d.", bundle: AppResources.bundle, comment: ""),
                status
            ))
        }
    }

    /// Never kills the process in the middle of writing a credential — if the
    /// user cancels before pasting the code, the process hasn't
    /// started writing anything sensitive yet, so terminate() here is safe.
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
