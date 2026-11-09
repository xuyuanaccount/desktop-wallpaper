import AppKit

@main
enum EntryPoint {
    @MainActor
    static func main() {
        let application = WallpaperApplication.shared
        let delegate = WallpaperApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class WallpaperApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if !EditingMenu.performShortcut(event) { super.sendEvent(event) }
    }
}
