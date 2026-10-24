import ClaudeSCore
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var vscodeExtensionWatcher: VSCodeExtensionWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()

        installCLIIfBundled()

        AccountAuthMonitor.shared.start()
        ExpiryMonitor.shared.start()
        UsageThresholdMonitor.shared.start()

        // The user leaves the app running indefinitely in the status bar — it's
        // not enough to apply the patch once at startup, it needs to keep
        // watching to react when VS Code updates the extension
        // on its own in the background.
        let watcher = VSCodeExtensionWatcher()
        watcher.start()
        vscodeExtensionWatcher = watcher
    }

    /// Mirrors VS Code's "Shell Command: Install 'code' in PATH" — except
    /// automatic, on every launch, so simply running the app (wherever it's
    /// placed — /Applications, ~/Applications, or anywhere else the user
    /// double-clicks it from) is enough for `cs`/`claudes` to work from the
    /// terminal, same as the official `cs install-cli` does for itself.
    /// Re-running on every launch (not just the first) makes the symlink
    /// self-heal if the user later moves the app. Best-effort: a dev build
    /// run via `swift run` has no bundled `cs` next to it, and a user
    /// without write access to any candidate PATH directory just doesn't
    /// get the CLI — neither case should block the app from opening.
    private func installCLIIfBundled() {
        let csPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cs").path
        guard FileManager.default.isExecutableFile(atPath: csPath) else { return }
        _ = try? ShellInstall.install(target: csPath)
    }
}
