import Foundation

/// Thin wrappers over `sysctlbyname` for the handful of values flatline reads.
enum Sysctl {
    /// Reads a 32- or 64-bit integer sysctl.
    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size:
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        case MemoryLayout<Int64>.size:
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        default:
            return nil
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Reads a fixed-size struct sysctl such as `vm.swapusage` or `kern.boottime`.
    static func value<T: BitwiseCopyable>(_ name: String, as type: T.Type, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let ok = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) == 0 }
        return ok ? value : nil
    }
}

/// A sysctl name resolved to its numeric MIB once, for values read every tick;
/// `sysctlbyname` repeats that lookup on each call.
final class SysctlMIB {
    private var mib: [Int32]

    init?(_ name: String) {
        var mib = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
        var count = mib.count
        guard sysctlnametomib(name, &mib, &count) == 0 else { return nil }
        self.mib = Array(mib.prefix(count))
    }

    func value<T: BitwiseCopyable>(initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let count = u_int(mib.count)
        let ok = withUnsafeMutableBytes(of: &value) { sysctl(&mib, count, $0.baseAddress, &size, nil, 0) == 0 }
        return ok ? value : nil
    }
}

public enum SystemInfo {
    /// Wall-clock boot time (includes time spent asleep, unlike `systemUptime`).
    public static let bootDate: Date? = {
        guard let tv = Sysctl.value("kern.boottime", as: timeval.self, initial: timeval()) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }()

    /// 1-, 5- and 15-minute load averages.
    public static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }
}
