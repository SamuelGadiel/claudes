import Foundation

/// Checa se .vscode/settings.json está versionado sem estar no .gitignore.
/// Ver risco documentado em plans/specs/02-integracao-vscode-sem-profiles:
/// CLAUDE_CONFIG_DIR é um path local da máquina do usuário e nunca deveria
/// ser commitado num projeto compartilhado.
enum GitRisk {
    static func warnings(forProjectPath projectPath: String, relativeFile: String) -> [String] {
        guard isInsideGitWorkTree(cwd: projectPath) else { return [] }

        if isIgnored(cwd: projectPath, relativePath: relativeFile) {
            return []
        }

        if isTracked(cwd: projectPath, relativePath: relativeFile) {
            return [
                "ATENÇÃO: \(relativeFile) está versionado neste repositório e NÃO está no " +
                ".gitignore. Escrever CLAUDE_CONFIG_DIR aqui vaza o path local da sua máquina " +
                "para o time e força sua conta em quem mais abrir o projeto. Considere adicionar " +
                "\(relativeFile) (ou a pasta .vscode/) ao .gitignore antes de prosseguir."
            ]
        }

        return [
            "Aviso: \(relativeFile) ainda não está commitado nem no .gitignore deste " +
            "repositório. Se for um projeto compartilhado, adicione ao .gitignore antes de " +
            "rodar git add."
        ]
    }

    private static func run(_ args: [String], cwd: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func isInsideGitWorkTree(cwd: String) -> Bool {
        run(["rev-parse", "--is-inside-work-tree"], cwd: cwd) == 0
    }

    private static func isIgnored(cwd: String, relativePath: String) -> Bool {
        run(["check-ignore", "-q", relativePath], cwd: cwd) == 0
    }

    private static func isTracked(cwd: String, relativePath: String) -> Bool {
        run(["ls-files", "--error-unmatch", relativePath], cwd: cwd) == 0
    }
}
