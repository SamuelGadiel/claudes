import Foundation

/// Where to load localized strings from — used everywhere instead of the
/// SwiftPM-generated `Bundle.module` directly.
///
/// `Bundle.module`'s accessor resolves resources relative to
/// `Bundle.main.bundleURL` — the `.app` bundle's own root, *not*
/// `Contents/Resources`. Staging the resource bundle there to match it
/// makes `codesign` reject the app ("unsealed contents present in the
/// bundle root"): everything in a signed bundle has to live under
/// `Contents/`. This is a known SwiftPM/app-bundle mismatch, not something
/// specific to this project.
///
/// Fix: look for the resource bundle inside `Contents/Resources` first —
/// the conventional, sealable location our build script (scripts/build-app.sh)
/// actually copies it to — and only fall back to `Bundle.module` for
/// development (`swift run`/a loose debug binary), where there's no `.app`
/// bundle at all.
enum AppResources {
    static let bundle: Bundle = {
        if let resourcesURL = Bundle.main.resourceURL {
            let candidate = resourcesURL.appendingPathComponent("claude-switcher_ClaudeSwitcherApp.bundle")
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return Bundle.module
    }()
}
