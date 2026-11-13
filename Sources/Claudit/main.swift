import AppKit

// Plain AppKit entry point: Claudit is a menu bar item only, so it declares no SwiftUI scenes
// (an empty SwiftUI Settings scene is what produced a stray "Settings" window).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
