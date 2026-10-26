import AppKit
import FlatlineKit
import Observation

/// Samples CPU, memory and network on one shared timer and keeps short histories.
@MainActor
@Observable
final class MetricsEngine {
    static let historyLength = 120

    let topology: CPUTopology
    private(set) var cpu = CPULoad()
    private(set) var memory = MemoryStats()
    private(set) var network = NetworkRates()
    private(set) var loadAverage: [Double] = []
    private(set) var primaryInterface: NetworkInterfaceInfo?
    private(set) var sessionIn: UInt64 = 0
    private(set) var sessionOut: UInt64 = 0

    private(set) var cpuHistory = RingBuffer(capacity: historyLength, fill: 0.0)
    private(set) var memoryHistory = RingBuffer(capacity: historyLength, fill: 0.0)
    private(set) var networkInHistory = RingBuffer(capacity: historyLength, fill: 0.0)
    private(set) var networkOutHistory = RingBuffer(capacity: historyLength, fill: 0.0)

    /// Called after every sample; the status item redraws from here.
    @ObservationIgnored var onTick: (() -> Void)?

    @ObservationIgnored private let cpuSampler: CPUSampler
    @ObservationIgnored private let memorySampler = MemorySampler()
    @ObservationIgnored private let networkSampler = NetworkSampler()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var interval: Double = 1
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var detailsVisible = false
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        topology = CPUTopology.current()
        cpuSampler = CPUSampler(topology: topology)
    }

    func start(interval: Double) {
        self.interval = interval
        // Prime the delta-based samplers so the first real tick has a baseline.
        _ = cpuSampler.sample()
        _ = networkSampler.sample()
        observeScreenSleep()
        schedule()
    }

    func setInterval(_ interval: Double) {
        guard interval != self.interval else { return }
        self.interval = interval
        schedule()
    }

    /// The popover is open: also refresh the slower details (interface, load average).
    func setDetailsVisible(_ visible: Bool) {
        detailsVisible = visible
        if visible { refreshDetails() }
    }

    func resetSession() {
        networkSampler.resetSession()
        sessionIn = 0
        sessionOut = 0
    }

    private func schedule() {
        timer?.invalidate()
        // Nobody can see the menu bar while the displays sleep, so slow down.
        let effective = screensAsleep ? max(interval, 5) : interval
        let timer = Timer(timeInterval: effective, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = effective * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let cpu = Profiler.measure("cpuSample") { cpuSampler.sample() }
        let memory = Profiler.measure("memSample") { memorySampler.sample() }
        let network = Profiler.measure("netSample") { networkSampler.sample() }
        Profiler.measure("publish") {
            self.cpu = cpu
            self.memory = memory
            self.network = network
            sessionIn = networkSampler.sessionIn
            sessionOut = networkSampler.sessionOut

            cpuHistory.append(cpu.total)
            memoryHistory.append(memory.usedFraction)
            networkInHistory.append(network.bytesInPerSecond)
            networkOutHistory.append(network.bytesOutPerSecond)
        }

        tickCount += 1
        if detailsVisible, tickCount % 5 == 0 { refreshDetails() }
        onTick?()
        Profiler.endTick()
    }

    private func refreshDetails() {
        loadAverage = SystemInfo.loadAverage()
        primaryInterface = NetworkInfo.primary()
    }

    private func observeScreenSleep() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.screensAsleep = asleep
                    self.schedule()
                }
            })
        }
    }
}
