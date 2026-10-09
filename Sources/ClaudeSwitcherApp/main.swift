import Cocoa

// force rebuild with a different hash (Keychain prompt test)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
