import AppKit
import ServiceManagement

@main
@MainActor
enum FlatlineApp {
    // NSApplication holds its delegate weakly.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let updater = Updater()
    private lazy var engine = MetricsEngine()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start(interval: preferences.refreshInterval)
        statusItem = StatusItemController(engine: engine, preferences: preferences, updater: updater)
        offerLaunchAtLoginOnce()
    }

    /// Asks once whether to start at login; a menu bar monitor is most useful
    /// when it's always there. The choice can be changed later in settings.
    private func offerLaunchAtLoginOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "offeredLaunchAtLogin") else { return }

        // A copy running from the DMG (or translocated by Gatekeeper) can't
        // register a login item; ask once it has been moved to Applications.
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return }

        defaults.set(true, forKey: "offeredLaunchAtLogin")
        guard SMAppService.mainApp.status != .enabled else { return }

        // Let the status item appear first so the question has context.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let alert = NSAlert()
            alert.messageText = "Start flatline when you log in?"
            alert.informativeText = "flatline lives in the menu bar. You can change this any time in its settings."
            alert.addButton(withTitle: "Start at Login")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                try? SMAppService.mainApp.register()
            }
        }
    }
}
