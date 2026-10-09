import Foundation

/// Reproduces the directory name that Claude Code uses at
/// <CLAUDE_CONFIG_DIR>/projects/<dirName>/ for a given project path.
/// Confirmed empirically against 10 real projects on this machine
/// (plans/specs/04-sincronizacao-sessoes): it is not a hash — it's the absolute
/// path with each "/" replaced by "-". Does not resolve symlinks (evidence: the
/// observed names match the direct path, not a realpath via
/// /private/var or /System/Volumes/Data).
enum ProjectHash {
    static func projectDirName(forPath path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if expanded.count > 1, expanded.hasSuffix("/") {
            expanded.removeLast()
        }
        return expanded.replacingOccurrences(of: "/", with: "-")
    }
}
