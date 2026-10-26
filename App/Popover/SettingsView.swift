import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let updater: Updater
    @Environment(\.accent) private var accent
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var autoCheck = false
    @State private var autoDownload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Section(title: "MENU BAR") {
                MetricRow(name: "cpu", isOn: $preferences.showCPU, style: $preferences.cpuStyle, isLast: isLast(preferences.showCPU))
                MetricRow(name: "mem", isOn: $preferences.showMemory, style: $preferences.memoryStyle, isLast: isLast(preferences.showMemory))
                MetricRow(name: "net", isOn: $preferences.showNetwork, style: $preferences.networkStyle, isLast: isLast(preferences.showNetwork))
            }

            Section(title: "UNITS") {
                Row("memory") {
                    Picker("memory", selection: $preferences.memoryDisplay) {
                        ForEach(MemoryDisplay.allCases) { Text($0.label).tag($0) }
                    }
                }
                Row("network") {
                    Picker("network", selection: $preferences.networkUnit) {
                        ForEach(NetworkUnit.allCases) { Text($0.label).tag($0) }
                    }
                }
            }

            Section(title: "GENERAL") {
                Row("refresh") {
                    Picker("refresh", selection: $preferences.refreshInterval) {
                        ForEach(Preferences.refreshIntervals, id: \.self) { interval in
                            Text(interval < 1 ? "½s" : "\(Int(interval))s").tag(interval)
                        }
                    }
                }
                Row("accent") {
                    HStack(spacing: 8) {
                        ForEach(Accent.allCases) { option in
                            Button {
                                preferences.accent = option
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: preferences.accent == option ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.rawValue)
                        }
                    }
                }
                Toggle("launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption2).foregroundStyle(.red)
                }
            }

            Section(title: "UPDATES") {
                Toggle("check automatically", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, on in updater.automaticallyChecks = on }
                Toggle("download automatically", isOn: $autoDownload)
                    .onChange(of: autoDownload) { _, on in updater.automaticallyDownloads = on }
                    .disabled(!autoCheck)
                Button("check now") { updater.checkForUpdates() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .pickerStyle(.segmented)
        .toggleStyle(.switch)
        .controlSize(.small)
        .onAppear {
            autoCheck = updater.automaticallyChecks
            autoDownload = updater.automaticallyDownloads
        }
    }

    /// The last enabled metric can't be switched off, or the status item would be empty.
    private func isLast(_ isOn: Bool) -> Bool {
        isOn && preferences.enabledMetricCount == 1
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(accent)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            content.labelsHidden()
        }
    }
}

private struct MetricRow: View {
    let name: String
    @Binding var isOn: Bool
    @Binding var style: DisplayStyle
    let isLast: Bool

    var body: some View {
        HStack {
            Toggle(name, isOn: $isOn)
                .disabled(isLast)
                .frame(width: 80, alignment: .leading)
            Picker(name, selection: $style) {
                ForEach(DisplayStyle.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .disabled(!isOn)
        }
    }
}
