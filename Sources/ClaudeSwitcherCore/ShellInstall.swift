import Foundation

/// Instala (ou atualiza) um link simbólico para o binário `cs` em execução
/// dentro de um diretório que já esteja no PATH do usuário — o mesmo padrão
/// do "Shell Command: Install 'code' in PATH" do VS Code, ou do "docker" do
/// Docker Desktop. Reusável tanto pelo próprio CLI (`cs install-cli`) quanto
/// pela futura GUI de status bar na primeira abertura — nenhum dos dois faz
/// mais do que isso; não há IPC nem dependência entre os dois binários.
public enum ShellInstallError: Error, CustomStringConvertible {
    case noWritableDirectory([String])

    public var description: String {
        switch self {
        case .noWritableDirectory(let tried):
            return "Não encontrei um diretório gravável para instalar o 'cs' (tentei: "
                + "\(tried.joined(separator: ", "))). Rode com sudo, ou crie um dos "
                + "diretórios acima e adicione ao PATH manualmente."
        }
    }
}

public struct ShellInstallResult {
    public let linkPath: String
    public let targetPath: String
    public let linkDirInPath: Bool
}

public enum ShellInstall {
    /// Em ordem de preferência: /usr/local/bin é o destino convencional no
    /// macOS para binários instalados fora de um package manager (quase
    /// sempre já existe e já está no PATH de qualquer shell padrão);
    /// ~/.local/bin é o fallback sem precisar de permissão elevada.
    static let candidateDirs = [
        "/usr/local/bin",
        ("~/.local/bin" as NSString).expandingTildeInPath,
    ]

    /// Caminho absoluto do binário `cs` que está rodando agora, com symlinks
    /// resolvidos. Deliberadamente dinâmico (não hardcoded): o .app pode
    /// estar em ~/Applications, /Applications, ou ser rodado via `swift run`
    /// durante o desenvolvimento.
    public static func currentExecutablePath() -> String {
        let arg0 = CommandLine.arguments[0]
        let absolute = arg0.hasPrefix("/")
            ? arg0
            : FileManager.default.currentDirectoryPath + "/" + arg0
        return (absolute as NSString).resolvingSymlinksInPath
    }

    @discardableResult
    public static func install() throws -> ShellInstallResult {
        let target = currentExecutablePath()
        let fm = FileManager.default

        for dir in candidateDirs {
            if !fm.fileExists(atPath: dir) {
                // ~/.local/bin pode não existir ainda; criamos só dentro da
                // home do usuário — nunca em /usr/local sem ele já existir.
                guard dir.hasPrefix(NSHomeDirectory()) else { continue }
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            guard fm.isWritableFile(atPath: dir) else { continue }

            let linkPath = dir + "/cs"

            if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath), existing == target {
                return ShellInstallResult(
                    linkPath: linkPath, targetPath: target, linkDirInPath: pathContains(dir)
                )
            }
            if fm.fileExists(atPath: linkPath) {
                try? fm.removeItem(atPath: linkPath)
            }

            do {
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                return ShellInstallResult(
                    linkPath: linkPath, targetPath: target, linkDirInPath: pathContains(dir)
                )
            } catch {
                continue
            }
        }

        throw ShellInstallError.noWritableDirectory(candidateDirs)
    }

    private static func pathContains(_ dir: String) -> Bool {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return pathEnv.split(separator: ":").map(String.init).contains(dir)
    }
}
