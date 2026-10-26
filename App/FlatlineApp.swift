import AppKit

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
    }
}
