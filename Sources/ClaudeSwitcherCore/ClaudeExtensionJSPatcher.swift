import Foundation

/// Patches `extension.js` (the official Claude Code VS Code extension's
/// minified bundle) so storage helpers that read `process.env.CLAUDE_CONFIG_DIR`
/// directly see the value resolved from `claudeCode.environmentVariables`
/// instead — the other half of the fix (see `VSCodeExtensionPatcher` for the
/// `package.json` scope half). Without this, even with the scope patch
/// applied, those helpers still read the wrong (or no) config dir.
///
/// This is a from-scratch Swift port of the regex patterns and pure
/// string-transform logic originally published by Leo Giovanetti in
/// `leog/claude-code-config-dir-patcher-vscode` (MIT License) —
/// `patch-regexes.js` and `patch-core.js`. See ATTRIBUTIONS.md at the repo
/// root. Ported rather than vendored-and-run-via-JavaScriptCore so this
/// project never depends on that extension staying installed or being
/// updated promptly when Anthropic changes the minified bundle shape — we
/// can react ourselves, same day, instead of waiting.
public enum ClaudeExtensionJSPatcher {
    public struct Analysis {
        public let envPatched: Bool
        public let envPatchable: Bool
        public let idePatched: Bool
        public let idePatchable: Bool
    }

    public struct PatchResult {
        public let source: String
        public let changes: [String]
    }

    // MARK: - Regexes (ported from patch-regexes.js)
    //
    // The launch-env loop has three known minified shapes across Claude Code
    // versions (older to newer): a bare name/value copy, one that skips an
    // empty CLAUDE_CONFIG_DIR override, and one that also resolves a
    // process-wrapper-aware config dir after the loop. All three are matched
    // by making the relevant pieces optional.

    private static let envNeedleRegex = try! NSRegularExpression(
        pattern:
            #"for\(let ([A-Za-z_$][\w$]*) of ([A-Za-z_$][\w$]*)\)\{?(?:if\((?:\1\.name==="CLAUDE_CONFIG_DIR"&&\1\.value===""|[A-Za-z_$][\w$]*\(\1\.name\))\)continue;)?if\(\1\.name\)([A-Za-z_$][\w$]*)\[\1\.name\]=\1\.value\|\|""[;}](?:let ([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(\2,Boolean\([A-Za-z_$][\w$]*\("claudeProcessWrapper"\)\)\);if\(\4!==void 0\)\3\.CLAUDE_CONFIG_DIR=\4;)?return \3\.CLAUDE_CODE_ENTRYPOINT="#
    )

    private static let envPatchedRegex = try! NSRegularExpression(
        pattern:
            #"if\(([A-Za-z_$][\w$]*)\.CLAUDE_CONFIG_DIR\)process\.env\.CLAUDE_CONFIG_DIR=\1\.CLAUDE_CONFIG_DIR;for\(let ([A-Za-z_$][\w$]*) of ([A-Za-z_$][\w$]*)\)\{?(?:if\((?:\2\.name==="CLAUDE_CONFIG_DIR"&&\2\.value===""|[A-Za-z_$][\w$]*\(\2\.name\))\)continue;)?if\(\2\.name\)\1\[\2\.name\]=\2\.value\|\|""[;}](?:let ([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(\3,Boolean\([A-Za-z_$][\w$]*\("claudeProcessWrapper"\)\)\);if\(\4!==void 0\)\1\.CLAUDE_CONFIG_DIR=\4;)?return \1\.CLAUDE_CODE_ENTRYPOINT="#
    )

    private static let ideNeedleRegex = try! NSRegularExpression(
        pattern: #"let ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\.join\(([A-Za-z_$][\w$]*)\.homedir\(\),"\.claude","ide"\);return"#
    )

    private static let idePatchedRegex = try! NSRegularExpression(
        pattern:
            #"let ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\.join\(process\.env\.CLAUDE_CONFIG_DIR\|\|\2\.join\(([A-Za-z_$][\w$]*)\.homedir\(\),"\.claude"\),"ide"\);return"#
    )

    // MARK: - Pure analysis/transform (ported from patch-core.js)

    public static func analyze(_ source: String) -> Analysis {
        let range = NSRange(source.startIndex..., in: source)
        return Analysis(
            envPatched: envPatchedRegex.firstMatch(in: source, range: range) != nil,
            envPatchable: envNeedleRegex.firstMatch(in: source, range: range) != nil,
            idePatched: idePatchedRegex.firstMatch(in: source, range: range) != nil,
            idePatchable: ideNeedleRegex.firstMatch(in: source, range: range) != nil
        )
    }

    public static func applyPatch(_ source: String) -> PatchResult {
        let status = analyze(source)
        var next = source
        var changes: [String] = []

        if !status.envPatched, status.envPatchable {
            next = patchEnv(next)
            changes.append("env")
        }
        // Newer builds route the IDE lock path through a CLAUDE_CONFIG_DIR-aware
        // helper, so the hardcoded needle is legitimately absent — only patch
        // when the unpatched form is actually present.
        if !status.idePatched, status.idePatchable {
            next = patchIdePath(next)
            changes.append("ide")
        }

        return PatchResult(source: next, changes: changes)
    }

    private static func patchEnv(_ source: String) -> String {
        let range = NSRange(source.startIndex..., in: source)
        guard let match = envNeedleRegex.firstMatch(in: source, range: range),
              let fullRange = Range(match.range, in: source),
              let envObjName = group(match, 3, in: source)
        else { return source }

        let prelude = "if(\(envObjName).CLAUDE_CONFIG_DIR)process.env.CLAUDE_CONFIG_DIR=\(envObjName).CLAUDE_CONFIG_DIR;"
        return source.replacingCharacters(in: fullRange, with: prelude + source[fullRange])
    }

    private static func patchIdePath(_ source: String) -> String {
        let range = NSRange(source.startIndex..., in: source)
        guard let match = ideNeedleRegex.firstMatch(in: source, range: range),
              let fullRange = Range(match.range, in: source),
              let varName = group(match, 1, in: source),
              let pathModuleName = group(match, 2, in: source),
              let osModuleName = group(match, 3, in: source)
        else { return source }

        let replacement =
            "let \(varName)=\(pathModuleName).join(process.env.CLAUDE_CONFIG_DIR||" +
            "\(pathModuleName).join(\(osModuleName).homedir(),\".claude\"),\"ide\");return"
        return source.replacingCharacters(in: fullRange, with: replacement)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in source: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: source) else {
            return nil
        }
        return String(source[range])
    }
}
