import AppKit

/// Native NSAlert, centered on screen — unlike a SwiftUI
/// `.confirmationDialog`, which gets squeezed inside our
/// small popover.
enum ConfirmationAlert {
    static func confirmDestructive(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
