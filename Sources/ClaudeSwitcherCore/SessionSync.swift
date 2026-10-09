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
            return "no session found at \(path) — this account has never used this project"
        }
    }
}

/// Sync-on-switch: copies the session .jsonl files of a specific project from
/// one account to another. Never a symlink, never overwrites, never automatic —
/// decision recorded in plans/specs/04-sincronizacao-sessoes.
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
                // Never overwrites: the name is the sessionId (UUID), so a
                // real content conflict shouldn't occur — but if it
                // does, preserving what's already at the destination is safer
                // than risking the loss of a session in progress.
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
