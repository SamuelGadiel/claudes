import Foundation

public struct SessionSyncResult {
    public let sourceDir: String
    public let destDir: String
    public let copied: [String]
    public let skippedExisting: [String]
}

public enum SessionSyncError: Error, CustomStringConvertible {
    case sourceNotFound(String)

    public var description: String {
        switch self {
        case .sourceNotFound(let path):
            return "nenhuma sessão encontrada em \(path) — essa conta nunca usou esse projeto"
        }
    }
}

/// Sync-on-switch: copia os .jsonl de sessão de um projeto específico de uma
/// conta para outra. Nunca symlink, nunca sobrescreve, nunca é automático —
/// decisão registrada em plans/specs/04-sincronizacao-sessoes.
public enum SessionSync {
    public static func sync(
        projectPath: String, from fromAccount: RegisteredAccount, to toAccount: RegisteredAccount
    ) throws -> SessionSyncResult {
        let dirName = ProjectHash.projectDirName(forPath: projectPath)
        let fm = FileManager.default

        let sourceDir =
            (fromAccount.configDir as NSString).expandingTildeInPath + "/projects/\(dirName)"
        let destDir =
            (toAccount.configDir as NSString).expandingTildeInPath + "/projects/\(dirName)"

        guard fm.fileExists(atPath: sourceDir) else {
            throw SessionSyncError.sourceNotFound(sourceDir)
        }

        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let sourceFiles = try fm.contentsOfDirectory(atPath: sourceDir)
            .filter { $0.hasSuffix(".jsonl") }

        var copied: [String] = []
        var skipped: [String] = []

        for file in sourceFiles {
            let sourcePath = sourceDir + "/" + file
            let destPath = destDir + "/" + file

            if fm.fileExists(atPath: destPath) {
                // Nunca sobrescreve: o nome é o sessionId (UUID), então um
                // conflito real de conteúdo não deveria ocorrer — mas se
                // ocorrer, preservar o que já está no destino é mais seguro
                // do que arriscar perder uma sessão em andamento.
                skipped.append(file)
                continue
            }

            try fm.copyItem(atPath: sourcePath, toPath: destPath)
            copied.append(file)
        }

        return SessionSyncResult(
            sourceDir: sourceDir, destDir: destDir, copied: copied, skippedExisting: skipped
        )
    }
}
