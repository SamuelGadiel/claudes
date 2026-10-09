import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var expiryMonitor: ExpiryMonitor?
    private var vscodeExtensionWatcher: VSCodeExtensionWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()

        let monitor = ExpiryMonitor()
        monitor.start()
        expiryMonitor = monitor

        // Usuário deixa o app rodando indefinidamente na status bar — não
        // basta aplicar o patch uma vez no startup, precisa continuar
        // observando pra reagir quando o VS Code atualizar a extensão
        // sozinho em background.
        let watcher = VSCodeExtensionWatcher()
        watcher.start()
        vscodeExtensionWatcher = watcher
    }
}
