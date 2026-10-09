import Foundation

/// Força a renovação de um access token expirado antes de chamar
/// /api/oauth/usage. Receita validada (ver plans/specs/06, inspirada em
/// claude-macos-menu-usage, MIT):
///
/// - `claude mcp list` é o comando confirmado a de fato bater um endpoint
///   autenticado — `claude auth status` só reporta estado cacheado e NUNCA
///   dispara o refresh OAuth, mesmo com o token expirado.
/// - Via o shell de login do usuário (`-i -l`): necessário porque um app
///   GUI lançado pelo Finder/LaunchServices não herda o PATH do terminal
///   (diferente do `cs`, que já roda dentro de um terminal com PATH certo).
/// - `cwd` fixado em /tmp: evita disparar prompts de TCC por tocar em
///   ~/Desktop, ~/Documents etc.
/// - NUNCA envia SIGTERM ao processo: interromper no meio da escrita faz o
///   Claude Code mover a credencial para fora do Keychain. Se o timeout
///   expirar, simplesmente paramos de esperar — o processo segue sozinho.
public enum CredentialRefresher {
    @discardableResult
    public static func refreshInBackground(configDir: String, timeout: TimeInterval = 15) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShellPath.loginShell())
        process.arguments = ["-i", "-l", "-c", "command -v claude >/dev/null 2>&1 && claude mcp list"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        process.environment = env

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

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
