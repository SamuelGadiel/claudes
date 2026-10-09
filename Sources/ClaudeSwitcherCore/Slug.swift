import Foundation

public enum Slug {
    /// "Cliente X" -> "cliente-x", "Time Mobile 2" -> "time-mobile-2".
    /// Remove acentos, baixa caixa, troca qualquer sequência de caracteres
    /// não alfanuméricos por um único "-", sem "-" nas pontas.
    public static func make(from name: String) -> String {
        let folded = name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        let lowered = folded.lowercased()

        var result = ""
        var pendingDash = false

        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash && !result.isEmpty {
                    result.append("-")
                }
                result.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }

        return result
    }
}
