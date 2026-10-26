import AppKit
import Observation
import SwiftUI

/// Owns the status item: redraws it each tick, opens the popover on click
/// and a small menu on right-click or Control-click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let engine: MetricsEngine
    private let preferences: Preferences
    private let updater: Updater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let popoverState = PopoverState()

    private struct RenderKey: Equatable {
        var layout: MenuBarRenderer.Layout
        var appearance: NSAppearance.Name
        var scale: CGFloat
    }
    private var lastRender: RenderKey?
    private var lastAccessibilityLabel: String?

    /// Holds the rendered bitmap. Setting `button.image` instead makes NSButton
    /// re-render the image on the CPU every tick, which was about 2 ms of work;
    /// a layer's contents go straight to the window server.
    private let contentLayer = CALayer()
    private static let horizontalPadding: CGFloat = 4

    init(engine: MetricsEngine, preferences: Preferences, updater: Updater) {
        self.engine = engine
        self.preferences = preferences
        self.updater = updater
        super.init()

        statusItem.autosaveName = "flatline"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.wantsLayer = true
            contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            button.layer?.addSublayer(contentLayer)
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        engine.onTick = { [weak self] in self?.redraw() }
        observePreferences()
        redraw()
    }

    private func redraw() {
        guard let button = statusItem.button else { return }
        Profiler.measure("a11y") {
            let label = MenuBarRenderer.accessibilityLabel(engine: engine, preferences: preferences)
            if label != lastAccessibilityLabel {
                lastAccessibilityLabel = label
                button.setAccessibilityLabel(label)
            }
        }

        let layout = Profiler.measure("layout") { MenuBarRenderer.layout(engine: engine, preferences: preferences) }
        let appearance = button.effectiveAppearance
        let scale = button.window?.backingScaleFactor ?? 2
        let key = RenderKey(layout: layout, appearance: appearance.name, scale: scale)
        guard key != lastRender else { return }
        lastRender = key

        guard let image = Profiler.measure("render", { MenuBarRenderer.image(for: layout, appearance: appearance, scale: scale) }) else { return }
        Profiler.measure("setImage") {
            let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let length = size.width + 2 * Self.horizontalPadding
            if statusItem.length != length { statusItem.length = length }
            contentLayer.contentsScale = scale
            contentLayer.frame = CGRect(
                x: Self.horizontalPadding,
                y: ((button.bounds.height - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            contentLayer.contents = image
        }
    }

    /// Redraw (and retime) as soon as a setting changes instead of waiting for the next tick.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.showCPU
            _ = preferences.showMemory
            _ = preferences.showNetwork
            _ = preferences.cpuStyle
            _ = preferences.memoryStyle
            _ = preferences.networkStyle
            _ = preferences.memoryDisplay
            _ = preferences.networkUnit
            _ = preferences.refreshInterval
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.engine.setInterval(self.preferences.refreshInterval)
                self.redraw()
                self.observePreferences()
            }
        }
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover(settings: false)
        }
    }

    private func togglePopover(settings: Bool) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }

        popoverState.showingSettings = settings
        let controller = NSHostingController(rootView: PopoverView(engine: engine, preferences: preferences, updater: updater, state: popoverState))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller

        engine.setDetailsVisible(true)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI tree so nothing renders while the popover is closed.
        popover.contentViewController = nil
        engine.setDetailsVisible(false)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open flatline", action: #selector(openPopover), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit flatline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left-click goes back to the popover.
        statusItem.menu = nil
    }

    @objc private func openPopover() { togglePopover(settings: false) }
    @objc private func openSettings() { togglePopover(settings: true) }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
}
