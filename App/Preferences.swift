import AppKit
import Observation
import SwiftUI

enum DisplayStyle: String, CaseIterable, Identifiable {
    case text, trace, textAndTrace
    var id: Self { self }
    var label: String {
        switch self {
        case .text: "text"
        case .trace: "trace"
        case .textAndTrace: "both"
        }
    }
}

enum MemoryDisplay: String, CaseIterable, Identifiable {
    case percent, gigabytes
    var id: Self { self }
    var label: String { self == .percent ? "% used" : "GB used" }
}

enum NetworkUnit: String, CaseIterable, Identifiable {
    case bytes, bits
    var id: Self { self }
    var label: String { self == .bytes ? "bytes/s" : "bits/s" }
}

enum Accent: String, CaseIterable, Identifiable {
    case phosphor, cyan, magenta, amber, system
    var id: Self { self }

    var color: Color {
        switch self {
        case .phosphor: Color(red: 0.20, green: 0.95, blue: 0.45)
        case .cyan: Color(red: 0.15, green: 0.85, blue: 1.00)
        case .magenta: Color(red: 1.00, green: 0.25, blue: 0.75)
        case .amber: Color(red: 1.00, green: 0.72, blue: 0.10)
        case .system: .accentColor
        }
    }
}

/// User settings, persisted to `UserDefaults`.
@MainActor
@Observable
final class Preferences {
    static let refreshIntervals: [Double] = [0.5, 1, 2, 5]

    var refreshInterval: Double { didSet { save(refreshInterval, "refreshInterval") } }
    var showCPU: Bool { didSet { save(showCPU, "showCPU") } }
    var showMemory: Bool { didSet { save(showMemory, "showMemory") } }
    var showNetwork: Bool { didSet { save(showNetwork, "showNetwork") } }
    var cpuStyle: DisplayStyle { didSet { save(cpuStyle.rawValue, "cpuStyle") } }
    var memoryStyle: DisplayStyle { didSet { save(memoryStyle.rawValue, "memoryStyle") } }
    var networkStyle: DisplayStyle { didSet { save(networkStyle.rawValue, "networkStyle") } }
    var memoryDisplay: MemoryDisplay { didSet { save(memoryDisplay.rawValue, "memoryDisplay") } }
    var networkUnit: NetworkUnit { didSet { save(networkUnit.rawValue, "networkUnit") } }
    var accent: Accent { didSet { save(accent.rawValue, "accent") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "refreshInterval": 1.0,
            "showCPU": true,
            "showMemory": true,
            "showNetwork": true,
        ])
        refreshInterval = defaults.double(forKey: "refreshInterval")
        showCPU = defaults.bool(forKey: "showCPU")
        showMemory = defaults.bool(forKey: "showMemory")
        showNetwork = defaults.bool(forKey: "showNetwork")
        cpuStyle = Self.load(defaults, "cpuStyle", .text)
        memoryStyle = Self.load(defaults, "memoryStyle", .text)
        networkStyle = Self.load(defaults, "networkStyle", .text)
        memoryDisplay = Self.load(defaults, "memoryDisplay", .percent)
        networkUnit = Self.load(defaults, "networkUnit", .bytes)
        accent = Self.load(defaults, "accent", .phosphor)

        if !showCPU && !showMemory && !showNetwork { showCPU = true }
    }

    var enabledMetricCount: Int {
        [showCPU, showMemory, showNetwork].filter(\.self).count
    }

    private func save(_ value: some Sendable, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private static func load<T: RawRepresentable<String>>(_ defaults: UserDefaults, _ key: String, _ fallback: T) -> T {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }
}
