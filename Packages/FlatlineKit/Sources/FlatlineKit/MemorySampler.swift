import Darwin

public enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

/// Memory in bytes, using Activity Monitor's definitions.
public struct MemoryStats: Sendable, Equatable {
    public var physical: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cached: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var pressure: MemoryPressure = .normal
    /// The value Activity Monitor graphs as "Memory Pressure", 0...1.
    public var pressureFraction: Double = 0

    public init() {}

    public var used: UInt64 { app + wired + compressed }
    public var free: UInt64 { physical > used + cached ? physical - used - cached : 0 }
    public var usedFraction: Double { physical > 0 ? min(1, Double(used) / Double(physical)) : 0 }
}

public final class MemorySampler {
    private let host = mach_host_self()
    private let pageSize = UInt64(Sysctl.int("hw.pagesize") ?? 16_384)
    private let physical = UInt64(Sysctl.int("hw.memsize") ?? 0)

    public init() {}

    deinit {
        mach_port_deallocate(task_self_trap(), host)
    }

    public func sample() -> MemoryStats {
        var stats = MemoryStats()
        stats.physical = physical

        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let anonymous = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            stats.app = (anonymous > purgeable ? anonymous - purgeable : 0) * pageSize
            stats.wired = UInt64(vm.wire_count) * pageSize
            stats.compressed = UInt64(vm.compressor_page_count) * pageSize
            stats.cached = (UInt64(vm.external_page_count) + purgeable) * pageSize
        }

        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self, initial: xsw_usage()) {
            stats.swapUsed = swap.xsu_used
            stats.swapTotal = swap.xsu_total
        }

        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level") {
            stats.pressure = MemoryPressure(rawValue: level) ?? .normal
        }
        if let available = Sysctl.int("kern.memorystatus_level") {
            stats.pressureFraction = Double(max(0, min(100, 100 - available))) / 100
        }
        return stats
    }
}
