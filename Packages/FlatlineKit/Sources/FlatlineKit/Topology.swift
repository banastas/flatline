import Foundation
import IOKit

/// A group of cores at the same performance level, e.g. the P or E cluster.
public struct CoreCluster: Sendable, Hashable, Identifiable {
    /// Perf-level index; 0 is the fastest.
    public let id: Int
    /// "Performance", "Efficiency", …
    public let name: String
    /// First letter of `name`, matching IORegistry's `cluster-type`.
    public let letter: String
    /// Logical CPU ids in this cluster.
    public let cores: [Int]

    public init(id: Int, name: String, letter: String, cores: [Int]) {
        self.id = id
        self.name = name
        self.letter = letter
        self.cores = cores
    }
}

public struct CPUTopology: Sendable {
    public let chipName: String
    public let logicalCPUCount: Int
    /// Ordered fastest first.
    public let clusters: [CoreCluster]
    /// `clusterOfCore[cpu]` is an index into `clusters`.
    public let clusterOfCore: [Int]

    public init(chipName: String, clusters: [CoreCluster]) {
        let count = clusters.reduce(0) { $0 + $1.cores.count }
        var clusterOfCore = [Int](repeating: 0, count: count)
        for (index, cluster) in clusters.enumerated() {
            for core in cluster.cores where core < count { clusterOfCore[core] = index }
        }
        self.chipName = chipName
        self.logicalCPUCount = count
        self.clusters = clusters
        self.clusterOfCore = clusterOfCore
    }

    /// Reads the running machine's layout from sysctl and IORegistry.
    public static func current() -> CPUTopology {
        let chip = Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon"
        let cpuCount = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let levels = max(1, Sysctl.int("hw.nperflevels") ?? 1)

        var names: [String] = []
        var counts: [Int] = []
        for level in 0..<levels {
            names.append(Sysctl.string("hw.perflevel\(level).name") ?? "Level \(level)")
            counts.append(Sysctl.int("hw.perflevel\(level).logicalcpu") ?? (levels == 1 ? cpuCount : 0))
        }
        let letters = names.map { String($0.prefix(1)).uppercased() }

        var clusterOf = [Int](repeating: -1, count: cpuCount)
        for (cpu, type) in ioRegistryClusterTypes() where cpu < cpuCount {
            if let level = letters.firstIndex(of: type) { clusterOf[cpu] = level }
        }

        // Fallback: Apple Silicon numbers the slowest cluster first.
        if clusterOf.contains(-1) {
            var cpu = 0
            for level in (0..<levels).reversed() {
                for _ in 0..<counts[level] where cpu < cpuCount {
                    clusterOf[cpu] = level
                    cpu += 1
                }
            }
            while cpu < cpuCount {
                clusterOf[cpu] = 0
                cpu += 1
            }
        }

        let clusters = (0..<levels).map { level in
            CoreCluster(
                id: level,
                name: names[level],
                letter: letters[level],
                cores: clusterOf.indices.filter { clusterOf[$0] == level }
            )
        }
        return CPUTopology(chipName: chip, clusters: clusters.filter { !$0.cores.isEmpty })
    }

    /// `(logical-cpu-id, cluster-type)` for each `cpuN` node under `IOPlatformDevice`.
    static func ioRegistryClusterTypes() -> [(Int, String)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPlatformDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [(Int, String)] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let type = property(service, "cluster-type"),
                  let id = property(service, "logical-cpu-id") else { continue }

            let letter: String? = switch type {
            case let data as Data: data.first.map { String(UnicodeScalar($0)) }
            case let string as String: string.first.map(String.init)
            default: nil
            }
            let cpu: Int? = switch id {
            case let number as NSNumber: number.intValue
            case let data as Data where data.count >= 4: Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            default: nil
            }
            if let letter, let cpu { result.append((cpu, letter.uppercased())) }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
