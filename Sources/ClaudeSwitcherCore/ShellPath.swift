import Foundation

/// Resolve o PATH real do shell de login do usuário — único recurso contra
/// o PATH mínimo que um app GUI lançado via Finder/LaunchServices herda do
/// launchd. Caro: mede ~2s nesta máquina (oh-my-zsh/powerlevel10k no
/// `.zshrc`) — por isso só é chamado como último recurso por
/// `ClaudeExecutable`, nunca direto por quem só precisa rodar `claude`.
enum ShellPath {
    private static var cached: String?

    static func resolved() -> String {
        if let cached { return cached }
        let resolved = resolve()
        cached = resolved
        return resolved
    }

    /// Mais confiável que a env var `$SHELL` para um app GUI (que não herda
    /// o ambiente do terminal do usuário) — lê direto da base de usuários
    /// do sistema.
    static func loginShell() -> String {
        guard let pw = getpwuid(getuid()) else { return "/bin/zsh" }
        return String(cString: pw.pointee.pw_shell)
    }

    private static func resolve() -> String {
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = loginShell()
        // Delimitador único em volta do valor real — um shell interativo (-i)
        // pode imprimir banners/MOTD de plugins (oh-my-zsh, starship etc.)
        // antes do nosso echo; sem isso, esse ruído poluiria o PATH extraído.
        let marker = "__cs_path__"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i carrega .zshrc/.bashrc, -l carrega .zprofile — entre os dois
        // cobrem onde a maioria das pessoas exporta PATH.
        process.arguments = ["-ilc", "echo \"\(marker):$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return fallback
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        // Shell de login mal configurado poderia travar esperando algo —
        // nunca deixamos isso pendurar a resolução indefinidamente.
        if semaphore.wait(timeout: .now() + 5) == .timedOut, process.isRunning {
            process.terminate()
            return fallback
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return fallback }

        for line in output.split(separator: "\n").reversed() {
            if line.hasPrefix("\(marker):") {
                let value = line.dropFirst(marker.count + 1).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? fallback : value
            }
        }
        return fallback
    }
}
