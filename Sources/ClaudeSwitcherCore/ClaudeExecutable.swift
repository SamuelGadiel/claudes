import Foundation

/// Resolve o caminho absoluto do binário `claude`, em camadas da mais
/// barata para a mais cara:
///
/// 1. PATH já herdado pelo processo — instantâneo, cobre o caso comum
///    (`cs` chamado de um terminal já tem o PATH certo).
/// 2. Locais de instalação comuns — também instantâneo, sem spawnar nada.
/// 3. PATH do shell de login do usuário (`ShellPath`) — só como último
///    recurso: pode levar segundos (medido ~2s nesta máquina, por causa de
///    plugins de prompt como oh-my-zsh/powerlevel10k). Pagar isso em todo
///    `cs` rodado de um terminal seria uma regressão de performance sem
///    necessidade nenhuma, já que o terminal já tem o PATH correto.
///
/// Resultado cacheado por processo — cada `cs`/app GUI resolve uma vez.
public enum ClaudeExecutable {
    private static var cached: String?

    public static func resolve() -> String {
        if let cached { return cached }
        let found = resolveUncached()
        cached = found
        return found
    }

    private static func resolveUncached() -> String {
        if let path = search(in: ProcessInfo.processInfo.environment["PATH"]) {
            return path
        }
        for candidate in commonLocations() where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let path = search(in: ShellPath.resolved()) {
            return path
        }
        // Não encontramos em lugar nenhum — devolve "claude" puro, deixando
        // o Process falhar com um erro claro ("No such file or directory")
        // em vez de travar aqui tentando mais alternativas.
        return "claude"
    }

    private static func search(in path: String?) -> String? {
        guard let path else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func commonLocations() -> [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
    }
}
