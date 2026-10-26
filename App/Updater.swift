import AppKit
import Sparkle

/// Sparkle updates from https://flatline.banast.as/appcast.xml (see Info.plist).
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        // flatline has no Dock icon; activate so Sparkle's window comes to the front.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    // Background apps opt in to gentle reminders; without this Sparkle warns
    // that a scheduled update alert may go unnoticed behind other apps.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // A scheduled check found an update: bring the alert forward.
        if handleShowingUpdate && !state.userInitiated {
            DispatchQueue.main.async { NSApp.activate() }
        }
    }
}
