import Foundation

public typealias VSCodeSettingsError = JSONSettingsFileError

public struct VSCodeSettingsResult {
    public let settingsPath: String
    public let warnings: [LocalizedWarning]
}

/// Writes/updates CLAUDE_CONFIG_DIR in .vscode/settings.json doing a safe
/// merge: never overwrites the whole file, only the
/// claudeCode.environmentVariables entry with name == "CLAUDE_CONFIG_DIR".
/// See plans/specs/02-integracao-vscode-sem-profiles.
public enum VSCodeSettings {
    public static func setConfigDir(projectPath: String, configDir: String) throws -> VSCodeSettingsResult {
        let expandedProject = (projectPath as NSString).expandingTildeInPath
        // CLAUDE_CONFIG_DIR goes into a process's environment, which doesn't
        // expand "~" on its own (that's done by the shell, not by whoever reads
        // the env var) — always write the absolute path.
        let expandedConfigDir = (configDir as NSString).expandingTildeInPath
        let vscodeDir = expandedProject + "/.vscode"
        let settingsFile = vscodeDir + "/settings.json"
        let fm = FileManager.default

        var warnings = GitRisk.warnings(forProjectPath: expandedProject, relativeFile: ".vscode/settings.json")

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsFile) {
            root = try JSONSettingsFile.read(path: settingsFile, warnings: &warnings)
        }

        var envVars = root["claudeCode.environmentVariables"] as? [[String: Any]] ?? []
        if let idx = envVars.firstIndex(where: { ($0["name"] as? String) == "CLAUDE_CONFIG_DIR" }) {
            envVars[idx]["value"] = expandedConfigDir
        } else {
            envVars.append(["name": "CLAUDE_CONFIG_DIR", "value": expandedConfigDir])
        }
        root["claudeCode.environmentVariables"] = envVars

        try fm.createDirectory(atPath: vscodeDir, withIntermediateDirectories: true)
        try JSONSettingsFile.write(root, toPath: settingsFile)

        return VSCodeSettingsResult(settingsPath: settingsFile, warnings: warnings)
    }
}
