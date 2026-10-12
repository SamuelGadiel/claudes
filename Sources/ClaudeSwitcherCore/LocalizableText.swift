import Foundation

/// A piece of user-facing text exposed as a stable English-language format
/// key plus its arguments, instead of an already-interpolated string — so a
/// presentation layer can look the key up in its own strings table and
/// reformat it with the same arguments, in whatever language it wants.
///
/// The CLI never does that lookup: it has no dependency on any strings table
/// and just renders `englishText`, so its output stays English-only with no
/// runtime check anywhere. Only `ClaudeSwitcherApp` (the GUI) imports the
/// helper that re-renders this in the user's language — see
/// `LocalizableText.localizedForDisplay` there. That's the single place the
/// "CLI vs. GUI" decision is made.
public protocol LocalizableText {
    /// The English text, with `%@`/`%d`/... placeholders where `l10nArgs` go —
    /// also the lookup key in Localizable.strings.
    var l10nKey: String { get }
    var l10nArgs: [CVarArg] { get }
}

extension LocalizableText {
    public var englishText: String {
        l10nArgs.isEmpty ? l10nKey : String(format: l10nKey, arguments: l10nArgs)
    }
}

/// An `Error` that opts into the `LocalizableText` contract — conformers
/// build their `CustomStringConvertible.description` (what the CLI prints)
/// directly from `englishText`, so there's exactly one place per error type
/// that spells out the English copy.
public protocol LocalizableError: Error, LocalizableText {}

/// A non-fatal, user-facing warning (not an `Error`) surfaced by Core
/// operations — e.g. GitRisk's ".gitignore" checks or JSONSettingsFile's
/// "comments will be lost" notice. Same key+args contract as
/// `LocalizableError`, just without the `Error` conformance.
public struct LocalizedWarning: LocalizableText {
    public let l10nKey: String
    public let l10nArgs: [CVarArg]

    public init(l10nKey: String, l10nArgs: [CVarArg] = []) {
        self.l10nKey = l10nKey
        self.l10nArgs = l10nArgs
    }
}
