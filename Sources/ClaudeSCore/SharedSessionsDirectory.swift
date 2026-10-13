import CryptoKit
import Foundation

/// All accounts point `projects/` at this single directory via a symlink —
/// there is no per-account session storage anymore, and no copying between
/// accounts: it's the same files on disk no matter which account is active.
/// Chats belong to the project, not to whichever account happened to be
/// logged in when they were written.
///
/// Deliberately a community technique, not an Anthropic-documented or
/// supported one — confirmed working by reading real reports of people doing
/// this (`ln -sf ~/.claude/projects ~/.claude-work/projects`), but there's no
/// guarantee it keeps working across every future Claude Code release. If
/// session history stops showing up after an update, this is the first place
/// to check.
///
/// Never touches the content of any `.jsonl`/session file — that structure is
/// internal to Claude Code and documented as changing between versions
/// (code.claude.com/docs/en/sessions: "scripts that parse these files
/// directly can break on any release"). Every operation here treats session
/// data as an opaque blob: move it, compare whole files for equality, never
/// read or interpret what's inside.
public enum SharedSessionsDirectory {
    public static let directoryName = ".claude-shared-chats"
    public static let path: String = ("~/" + directoryName as NSString).expandingTildeInPath
    /// The slug an account name would collide with (`Slug.make("Shared
    /// Chats") == "shared-chats"`) — kept reserved in `ReservedCommands`.
    public static let reservedSlug = "shared-chats"

    public enum AdoptError: Error, CustomStringConvertible {
        case notADirectory(String)
        case io(String)

        public var description: String {
            switch self {
            case .notADirectory(let path): return "\(path) exists but isn't a directory"
            case .io(let detail): return "filesystem error: \(detail)"
            }
        }
    }

    public struct AdoptResult {
        /// Project directories moved over with no name collision at all.
        public let projectsMovedCleanly: [String]
        /// Items (session files or per-session subfolders) that already
        /// existed at the destination with byte-identical content — the
        /// duplicate from the origin was simply dropped, nothing lost.
        public let identicalSkipped: [String]
        /// Items that collided with different content — both were kept: the
        /// larger one (heuristic: larger means more complete/more recently
        /// continued) retains its original name and stays resumable by ID,
        /// the smaller one is preserved alongside it with a
        /// ".conflict-from-<slug>" suffix, never deleted.
        public let conflictsPreserved: [String]
        /// true when `projects/` was already the shared symlink — nothing to do.
        public let alreadyAdopted: Bool
    }

    /// Makes `configDir/projects` a symlink into the shared directory,
    /// merging in any pre-existing session data found there first. Safe to
    /// call on a brand-new account (nothing to merge, just creates the
    /// symlink) or an account that already has real session history on disk
    /// (e.g. importing one created before this app existed, or one used
    /// before this feature shipped).
    @discardableResult
    public static func adopt(configDir: String, accountSlug: String) throws -> AdoptResult {
        let fm = FileManager.default
        let expandedConfigDir = (configDir as NSString).expandingTildeInPath
        let projectsPath = expandedConfigDir + "/projects"

        try ensureSharedDirectoryExists()

        if let existingTarget = try? fm.destinationOfSymbolicLink(atPath: projectsPath), existingTarget == path {
            return AdoptResult(
                projectsMovedCleanly: [], identicalSkipped: [], conflictsPreserved: [], alreadyAdopted: true
            )
        }

        var projectsMovedCleanly: [String] = []
        var identicalSkipped: [String] = []
        var conflictsPreserved: [String] = []

        if fm.fileExists(atPath: projectsPath) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: projectsPath, isDirectory: &isDir)
            guard isDir.boolValue else { throw AdoptError.notADirectory(projectsPath) }

            let projectDirs = (try? fm.contentsOfDirectory(atPath: projectsPath)) ?? []
            for projectDir in projectDirs {
                let sourceProjectPath = projectsPath + "/" + projectDir
                let destProjectPath = path + "/" + projectDir

                if !fm.fileExists(atPath: destProjectPath) {
                    try move(from: sourceProjectPath, to: destProjectPath)
                    projectsMovedCleanly.append(projectDir)
                    continue
                }

                // Destination already has this project (from a previously
                // adopted account) — merge item by item instead of the whole
                // folder.
                let items = (try? fm.contentsOfDirectory(atPath: sourceProjectPath)) ?? []
                for item in items {
                    let sourceItemPath = sourceProjectPath + "/" + item
                    let destItemPath = destProjectPath + "/" + item

                    guard fm.fileExists(atPath: destItemPath) else {
                        try move(from: sourceItemPath, to: destItemPath)
                        continue
                    }

                    if try itemsAreIdentical(sourceItemPath, destItemPath) {
                        try fm.removeItem(atPath: sourceItemPath)
                        identicalSkipped.append("\(projectDir)/\(item)")
                        continue
                    }

                    let sourceSize = try sizeOnDisk(sourceItemPath)
                    let destSize = try sizeOnDisk(destItemPath)
                    if sourceSize > destSize {
                        // The incoming copy is the larger one — it takes the
                        // canonical name, the existing smaller one is
                        // preserved under a conflict suffix instead.
                        let preservedPath = destProjectPath + "/" + item + ".conflict-from-existing"
                        try fm.moveItem(atPath: destItemPath, toPath: uniquePath(preservedPath))
                        try move(from: sourceItemPath, to: destItemPath)
                    } else {
                        let conflictPath = destProjectPath + "/" + item + ".conflict-from-\(accountSlug)"
                        try move(from: sourceItemPath, to: uniquePath(conflictPath))
                    }
                    conflictsPreserved.append("\(projectDir)/\(item)")
                }
                try? fm.removeItem(atPath: sourceProjectPath)
            }
            try fm.removeItem(atPath: projectsPath)
        }

        try fm.createSymbolicLink(atPath: projectsPath, withDestinationPath: path)

        return AdoptResult(
            projectsMovedCleanly: projectsMovedCleanly, identicalSkipped: identicalSkipped,
            conflictsPreserved: conflictsPreserved, alreadyAdopted: false
        )
    }

    /// Deletes every session for one project from the shared directory —
    /// never touches other projects, since they live in their own
    /// `<projectDirName>` folder. Irreversible; the caller is responsible for
    /// confirming with the user first.
    public static func clearHistory(forProjectPath projectPath: String) throws {
        let dirName = ProjectHash.projectDirName(forPath: projectPath)
        let target = path + "/" + dirName
        guard FileManager.default.fileExists(atPath: target) else { return }
        try FileManager.default.removeItem(atPath: target)
    }

    private static func ensureSharedDirectoryExists() throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw AdoptError.io("\(error)")
        }
    }

    private static func move(from source: String, to destination: String) throws {
        do {
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        } catch {
            throw AdoptError.io("\(error)")
        }
    }

    /// Appends a numeric suffix until the path doesn't collide with anything
    /// already there — guards against two accounts both conflicting on the
    /// exact same item name in the same merge pass.
    private static func uniquePath(_ candidate: String) -> String {
        guard FileManager.default.fileExists(atPath: candidate) else { return candidate }
        var n = 2
        while FileManager.default.fileExists(atPath: "\(candidate)-\(n)") { n += 1 }
        return "\(candidate)-\(n)"
    }

    private static func sizeOnDisk(_ path: String) throws -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try fm.attributesOfItem(atPath: path)
            return (attrs[.size] as? Int) ?? 0
        }
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total = 0
        for case let relative as String in enumerator {
            let full = path + "/" + relative
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &entryIsDir), !entryIsDir.boolValue else { continue }
            if let attrs = try? fm.attributesOfItem(atPath: full), let size = attrs[.size] as? Int {
                total += size
            }
        }
        return total
    }

    /// Byte-for-byte comparison, directories included — only ever used to
    /// decide "is this a true duplicate I can drop", never to merge content.
    private static func itemsAreIdentical(_ lhs: String, _ rhs: String) throws -> Bool {
        let fm = FileManager.default
        var lhsIsDir: ObjCBool = false
        var rhsIsDir: ObjCBool = false
        fm.fileExists(atPath: lhs, isDirectory: &lhsIsDir)
        fm.fileExists(atPath: rhs, isDirectory: &rhsIsDir)
        guard lhsIsDir.boolValue == rhsIsDir.boolValue else { return false }

        if !lhsIsDir.boolValue {
            guard let lhsData = fm.contents(atPath: lhs), let rhsData = fm.contents(atPath: rhs) else { return false }
            return SHA256.hash(data: lhsData) == SHA256.hash(data: rhsData)
        }

        let lhsEntries = ((try? fm.contentsOfDirectory(atPath: lhs)) ?? []).sorted()
        let rhsEntries = ((try? fm.contentsOfDirectory(atPath: rhs)) ?? []).sorted()
        guard lhsEntries == rhsEntries else { return false }
        for entry in lhsEntries where try !itemsAreIdentical(lhs + "/" + entry, rhs + "/" + entry) {
            return false
        }
        return true
    }
}
