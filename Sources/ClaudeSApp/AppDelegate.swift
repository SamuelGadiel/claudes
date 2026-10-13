import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var vscodeExtensionWatcher: VSCodeExtensionWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()

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
}
