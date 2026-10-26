import FlatlineKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PopoverState {
    var showingSettings = false
}

extension EnvironmentValues {
    @Entry var accent: Color = Accent.phosphor.color
}

struct PopoverView: View {
    let engine: MetricsEngine
    @Bindable var preferences: Preferences
    let updater: Updater
    @Bindable var state: PopoverState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(chipName: engine.topology.chipName)
            if state.showingSettings {
                SettingsView(preferences: preferences, updater: updater)
            } else {
                CPUCard(engine: engine)
                MemoryCard(engine: engine)
                NetworkCard(engine: engine, preferences: preferences)
            }
            FooterView(state: state)
        }
        .padding(14)
        .frame(width: 340)
        // The default popover glass lets busy windows show through the numbers.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .fontDesign(.monospaced)
        .tint(preferences.accent.color)
        .environment(\.accent, preferences.accent.color)
    }
}

private struct HeaderView: View {
    let chipName: String
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.headline)
            Text("flatline")
                .font(.headline)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(chipName)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("up \(SystemInfo.bootDate.map { Format.duration(context.date.timeIntervalSince($0)) } ?? "?")")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(accent)
    }
}

private struct FooterView: View {
    @Bindable var state: PopoverState

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        HStack {
            Button {
                state.showingSettings.toggle()
            } label: {
                Label(state.showingSettings ? "done" : "settings", systemImage: state.showingSettings ? "chevron.left" : "gearshape")
            }
            .keyboardShortcut(",")
            Text("v\(version)")
                .foregroundStyle(.tertiary)
            Spacer()
            Button("quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// Shared card chrome: title, headline value, content.
struct Card<Content: View>: View {
    let title: String
    var value: String?
    @ViewBuilder var content: Content
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(accent)
                Spacer()
                if let value {
                    Text(value)
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                }
            }
            content
        }
        .padding(10)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(0.18)))
    }
}
