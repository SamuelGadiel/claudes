import Foundation

public enum JSONSettingsFileError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case ioError(String)

    public var description: String {
        switch self {
        case .invalidJSON(let detail): return "arquivo de settings inválido: \(detail)"
        case .ioError(let detail): return "erro de IO: \(detail)"
        }
    }
}

/// Leitura/escrita de arquivos JSON de settings (VS Code, Claude Code) com
/// merge seguro: nunca sobrescreve o arquivo inteiro, só as chaves que o
/// chamador decide alterar. Usado por VSCodeSettings.
public enum JSONSettingsFile {
    public static func read(path: String, warnings: inout [String]) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw JSONSettingsFileError.ioError("não consegui ler \(path)")
        }
        return try parse(data: data, warnings: &warnings)
    }

    public static func write(_ root: [String: Any], toPath path: String) throws {
        let outData = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        // JSONSerialization escapa "/" como "\/" por padrão — válido em JSON,
        // mas verboso e fora do padrão que essas ferramentas escrevem.
        // Desescapar é seguro: dentro de uma string JSON, "\/" sempre
        // significa "/" puro.
        guard var jsonText = String(data: outData, encoding: .utf8) else {
            throw JSONSettingsFileError.ioError("falha ao serializar JSON")
        }
        jsonText = jsonText.replacingOccurrences(of: "\\/", with: "/")
        try jsonText.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Tenta parse estrito primeiro; se falhar, tenta de novo removendo
    /// comentários JSONC (VS Code e Claude Code aceitam comentários em
    /// settings.json, JSON puro não). Se precisar da segunda tentativa, os
    /// comentários originais são perdidos ao salvar — isso é avisado, nunca
    /// escondido.
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
                    "o arquivo tinha comentários (JSONC) — eles serão perdidos ao salvar esta mudança."
                )
                return dict
            }
        }

        throw JSONSettingsFileError.invalidJSON(
            "não foi possível interpretar o JSON existente; nada foi sobrescrito"
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
