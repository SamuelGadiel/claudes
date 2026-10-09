import Cocoa

// força rebuild com hash diferente (teste de prompt de Keychain)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
