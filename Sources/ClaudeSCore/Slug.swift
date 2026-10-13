import Foundation

public enum Slug {
    /// "Client X" -> "client-x", "Mobile Team 2" -> "mobile-team-2".
    /// Removes accents, lowercases, replaces any sequence of
    /// non-alphanumeric characters with a single "-", with no "-" at the ends.
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
