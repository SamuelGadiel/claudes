import ClaudeSCore
import Foundation

/// The single place the GUI decides to show Core-level text (errors,
/// warnings) in the user's language instead of the Core's canonical English.
/// Everything else in this target should go through these two properties
/// instead of interpolating a `LocalizableError`/`GitRiskWarning` or an
/// `Error` directly — that keeps the "translate or not" decision in one spot
/// rather than repeated at every call site.
///
/// The CLI target never imports this file (it isn't part of its dependency
/// graph), so it stays English-only by construction — there's no runtime
/// "am I the CLI or the GUI" check to keep in sync.
extension LocalizableText {
    var localizedForDisplay: String {
        let format = NSLocalizedString(l10nKey, bundle: AppResources.bundle, comment: "")
        return l10nArgs.isEmpty ? format : String(format: format, arguments: l10nArgs)
    }
}

extension Error {
    /// Display string for any error surfaced in the GUI: translated when the
    /// error conforms to `LocalizableError` (every Core error a user-facing
    /// flow can throw does), otherwise the system's own localized message.
    var localizedForDisplay: String {
        if let text = self as? LocalizableText {
            return text.localizedForDisplay
        }
        return (self as NSError).localizedDescription
    }
}
