import Foundation

/// Repassa execução para o binário `claude` real, igual a "fvm flutter" para
/// o Flutter SDK. Resolvido via PATH (/usr/bin/env), nunca hardcoded — e
/// nunca pelo alias de shell do usuário, porque Process não herda aliases.
public enum ClaudeGateway {
    /// Usado pelo gateway final (`cs <slug> ...`, `cs` sozinho): o processo
    /// `cs` não tem mais nada a fazer depois, então termina com o mesmo
    /// exit code do `claude`.
    public static func run(configDir: String?, arguments: [String]) -> Never {
        exit(execute(configDir: configDir, arguments: arguments))
    }

    /// Usado quando `cs` ainda precisa imprimir algo depois (ex.: `cs add`
    /// chamando `claude auth login` e então confirmando o cadastro).
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

        // Herda stdio diretamente (sem Pipe) para preservar o TTY — essencial
        // para o modo interativo do Claude Code funcionar normalmente.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("cs: falha ao executar claude: \(error)\n".utf8))
            return 1
        }

        process.waitUntilExit()
        return process.terminationStatus
    }
}
