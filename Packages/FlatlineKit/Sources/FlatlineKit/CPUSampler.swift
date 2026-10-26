import Darwin

/// Cumulative scheduler ticks for one logical CPU. Counters are 32-bit and wrap.
public struct CoreTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// CPU load over one sampling interval. All values are fractions in 0...1.
public struct CPULoad: Sendable, Equatable {
    public var total: Double = 0
    public var user: Double = 0
    public var system: Double = 0
    public var perCore: [Double] = []
    /// Indexed like `CPUTopology.clusters`.
    public var perCluster: [Double] = []

    public init() {}
}

public final class CPUSampler {
    public let topology: CPUTopology
    // mach_host_self() adds a send right on every call, so take it once.
    private let host = mach_host_self()
    private var previous: [CoreTicks] = []

    public init(topology: CPUTopology) {
        self.topology = topology
    }

    deinit {
        mach_port_deallocate(task_self_trap(), host)
    }

    /// Load since the previous call. The first call returns zeros.
    public func sample() -> CPULoad {
        let current = readTicks()
        defer { previous = current }
        guard !current.isEmpty, previous.count == current.count else { return CPULoad() }
        return Self.load(from: previous, to: current, topology: topology)
    }

    public static func load(from old: [CoreTicks], to new: [CoreTicks], topology: CPUTopology) -> CPULoad {
        var load = CPULoad()
        load.perCore = [Double](repeating: 0, count: new.count)
        var clusterBusy = [UInt64](repeating: 0, count: topology.clusters.count)
        var clusterAll = [UInt64](repeating: 0, count: topology.clusters.count)
        var user: UInt64 = 0, system: UInt64 = 0, all: UInt64 = 0

        for core in new.indices where core < old.count {
            let u = UInt64(new[core].user &- old[core].user)
            let s = UInt64(new[core].system &- old[core].system)
            let i = UInt64(new[core].idle &- old[core].idle)
            let n = UInt64(new[core].nice &- old[core].nice)
            let busy = u + s + n
            let coreAll = busy + i

            load.perCore[core] = coreAll > 0 ? Double(busy) / Double(coreAll) : 0
            user += u + n
            system += s
            all += coreAll

            if core < topology.clusterOfCore.count {
                let cluster = topology.clusterOfCore[core]
                if cluster < clusterBusy.count {
                    clusterBusy[cluster] += busy
                    clusterAll[cluster] += coreAll
                }
            }
        }

        if all > 0 {
            load.user = Double(user) / Double(all)
            load.system = Double(system) / Double(all)
            load.total = min(1, load.user + load.system)
        }
        load.perCluster = zip(clusterBusy, clusterAll).map { $1 > 0 ? Double($0) / Double($1) : 0 }
        return load
    }

    private func readTicks() -> [CoreTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(
                task_self_trap(),
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            return CoreTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }
}
