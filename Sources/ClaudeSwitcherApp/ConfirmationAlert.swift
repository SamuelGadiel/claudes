import AppKit

/// NSAlert nativo, centralizado na tela — diferente de um
/// `.confirmationDialog` do SwiftUI, que fica espremido dentro do nosso
/// popover pequeno.
enum ConfirmationAlert {
    static func confirmDestructive(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
