import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var expiryMonitor: ExpiryMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
        let monitor = ExpiryMonitor()
        monitor.start()
        expiryMonitor = monitor
    }
}
