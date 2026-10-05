import AppKit

/// App bootstrap. Runs as a menu-bar-only (accessory) app: no Dock icon, no windows.
public enum NeckReliefMain {

    private static var delegateKeeper: AppDelegate?

    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegateKeeper = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }
}
