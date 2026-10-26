import FlatlineKit
import SwiftUI

private let traceSamples = 60

struct CPUCard: View {
    let engine: MetricsEngine
    @Environment(\.accent) private var accent

    var body: some View {
        let cpu = engine.cpu
        Card(title: "CPU", value: Format.percent(cpu.total)) {
            TraceView(values: engine.cpuHistory.suffix(traceSamples), color: accent)
                .frame(height: 44)

            HStack(spacing: 12) {
                Stat(label: "usr", value: Format.percent(cpu.user))
                Stat(label: "sys", value: Format.percent(cpu.system))
                Spacer()
                if engine.loadAverage.count == 3 {
                    Stat(label: "load", value: engine.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))
                }
            }

            ForEach(Array(engine.topology.clusters.enumerated()), id: \.element.id) { index, cluster in
                ClusterRow(
                    cluster: cluster,
                    load: index < cpu.perCluster.count ? cpu.perCluster[index] : 0,
                    perCore: cpu.perCore,
                    color: index == 0 ? accent : accent.opacity(0.55)
                )
            }
        }
    }
}

private struct ClusterRow: View {
    let cluster: CoreCluster
    let load: Double
    let perCore: [Double]
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text("\(cluster.letter)×\(cluster.cores.count)")
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(Format.percent(load))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            HStack(spacing: 2) {
                ForEach(cluster.cores, id: \.self) { core in
                    CoreBar(value: core < perCore.count ? perCore[core] : 0, color: color)
                }
            }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cluster.name) cores \(Format.percent(load))")
    }
}

private struct CoreBar: View {
    let value: Double
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.fill.tertiary)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .scaleEffect(x: 1, y: max(0.04, min(1, value)), anchor: .bottom)
            }
            .frame(maxWidth: 14)
            .frame(height: 16)
    }
}

struct MemoryCard: View {
    let engine: MetricsEngine
    @Environment(\.accent) private var accent

    var body: some View {
        let memory = engine.memory
        Card(title: "MEMORY", value: Format.percent(memory.usedFraction)) {
            HStack {
                Text("\(Format.bytes(memory.used)) of \(Format.bytes(memory.physical))")
                    .foregroundStyle(.secondary)
                Spacer()
                PressureBadge(pressure: memory.pressure, fraction: memory.pressureFraction)
            }
            .font(.caption)

            StackedBar(total: Double(memory.physical), segments: [
                (Double(memory.app), accent),
                (Double(memory.wired), accent.opacity(0.6)),
                (Double(memory.compressed), .orange),
                (Double(memory.cached), .secondary.opacity(0.35)),
            ])
            .frame(height: 8)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Legend(color: accent, label: "app", value: Format.bytes(memory.app))
                    Legend(color: accent.opacity(0.6), label: "wired", value: Format.bytes(memory.wired))
                }
                GridRow {
                    Legend(color: .orange, label: "comp", value: Format.bytes(memory.compressed))
                    Legend(color: .secondary.opacity(0.35), label: "cache", value: Format.bytes(memory.cached))
                }
                GridRow {
                    Legend(color: .clear, label: "swap", value: memory.swapTotal > 0 ? "\(Format.bytes(memory.swapUsed)) / \(Format.bytes(memory.swapTotal))" : "none")
                        .gridCellColumns(2)
                }
            }
            .font(.caption)
        }
    }
}

private struct PressureBadge: View {
    let pressure: MemoryPressure
    let fraction: Double

    private var label: String {
        switch pressure {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }

    private var color: Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    var body: some View {
        Text("pressure \(Format.percent(fraction)) · \(label)")
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private struct StackedBar: View {
    let total: Double
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { index in
                    let (value, color) = segments[index]
                    Rectangle()
                        .fill(color)
                        .frame(width: total > 0 ? max(0, geometry.size.width * value / total - 1) : 0)
                }
                Spacer(minLength: 0)
            }
            .background(.fill.tertiary)
            .clipShape(.rect(cornerRadius: 3))
        }
        .accessibilityHidden(true)
    }
}

private struct Legend: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

struct NetworkCard: View {
    let engine: MetricsEngine
    let preferences: Preferences
    @Environment(\.accent) private var accent

    private var uploadColor: Color {
        preferences.accent == .magenta ? Accent.cyan.color : Accent.magenta.color
    }

    var body: some View {
        let bits = preferences.networkUnit == .bits
        let down = engine.networkInHistory.suffix(traceSamples)
        let up = engine.networkOutHistory.suffix(traceSamples)
        let peak = max(10_000, down.max() ?? 0, up.max() ?? 0)

        Card(title: "NETWORK") {
            HStack {
                Rate(arrow: "↓", value: Format.rate(engine.network.bytesInPerSecond, bits: bits), color: accent)
                Spacer()
                Rate(arrow: "↑", value: Format.rate(engine.network.bytesOutPerSecond, bits: bits), color: uploadColor)
            }

            TraceView(values: down, scale: peak, color: accent, mirror: up, mirrorColor: uploadColor)
                .frame(height: 52)

            HStack(spacing: 8) {
                Text("session").foregroundStyle(.secondary)
                Text("↓ \(Format.decimalBytes(engine.sessionIn))")
                Text("↑ \(Format.decimalBytes(engine.sessionOut))")
                Spacer()
                Button("reset") { engine.resetSession() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .monospacedDigit()

            if let interface = engine.primaryInterface {
                Text([interface.name, interface.ipv4].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct Rate: View {
    let arrow: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(arrow).foregroundStyle(color)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 15, weight: .semibold))
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}
