import Foundation

public enum JSONSettingsFileError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case ioError(String)

    public var description: String {
        switch self {
        case .invalidJSON(let detail): return "invalid settings file: \(detail)"
        case .ioError(let detail): return "IO error: \(detail)"
        }
    }
}

/// Reading/writing of settings JSON files (VS Code, Claude Code) with a
/// safe merge: never overwrites the whole file, only the keys the
/// caller decides to change. Used by VSCodeSettings.
public enum JSONSettingsFile {
    public static func read(path: String, warnings: inout [String]) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw JSONSettingsFileError.ioError("could not read \(path)")
        }
        return try parse(data: data, warnings: &warnings)
    }

    public static func write(_ root: [String: Any], toPath path: String) throws {
        let outData = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        // JSONSerialization escapes "/" as "\/" by default — valid JSON,
        // but verbose and not the standard these tools write.
        // Unescaping is safe: inside a JSON string, "\/" always
        // means a plain "/".
        guard var jsonText = String(data: outData, encoding: .utf8) else {
            throw JSONSettingsFileError.ioError("failed to serialize JSON")
        }
        jsonText = jsonText.replacingOccurrences(of: "\\/", with: "/")
        try jsonText.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Tries strict parsing first; if it fails, tries again removing
    /// JSONC comments (VS Code and Claude Code accept comments in
    /// settings.json, plain JSON doesn't). If the second attempt is needed, the
    /// original comments are lost on save — this is warned about, never
    /// hidden.
    private static func parse(data: Data, warnings: inout [String]) throws -> [String: Any] {
        if let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] {
            return dict
        }

        if let text = String(data: data, encoding: .utf8) {
            let stripped = stripComments(text)
            if let strippedData = stripped.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: strippedData),
               let dict = obj as? [String: Any] {
                warnings.append(
                    "the file had comments (JSONC) — they will be lost when this change is saved."
                )
                return dict
            }
        }

        throw JSONSettingsFileError.invalidJSON(
            "could not parse the existing JSON; nothing was overwritten"
        )
    }

    private static func stripComments(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        var inString = false
        var escaped = false

        while i < text.endIndex {
            let c = text[i]

            if inString {
                result.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i = text.index(after: i)
                continue
            }

            if c == "\"" {
                inString = true
                result.append(c)
                i = text.index(after: i)
                continue
            }

            if c == "/", text.index(after: i) < text.endIndex {
                let next = text[text.index(after: i)]
                if next == "/" {
                    while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                    continue
                }
                if next == "*" {
                    i = text.index(i, offsetBy: 2)
                    while i < text.endIndex {
                        if text[i] == "*", text.index(after: i) < text.endIndex,
                           text[text.index(after: i)] == "/" {
                            i = text.index(i, offsetBy: 2)
                            break
                        }
                        i = text.index(after: i)
                    }
                    continue
                }
            }

            result.append(c)
            i = text.index(after: i)
        }

        return result
    }
}
