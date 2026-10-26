import Foundation
import Testing
@testable import FlatlineKit

@Suite struct FormatTests {
    @Test(arguments: [
        (0.0, "0 B/s"),
        (999, "999 B/s"),
        (1000, "1.0 KB/s"),
        (1234, "1.2 KB/s"),
        (99_960, "100 KB/s"),
        (999_400, "999 KB/s"),
        (999_600, "1.0 MB/s"),
        (12_345_678, "12.3 MB/s"),
    ])
    func rate(bytes: Double, expected: String) {
        #expect(Format.rate(bytes) == expected)
    }

    @Test func rateInBits() {
        #expect(Format.rate(125_000, bits: true) == "1.0 Mb/s")
    }

    @Test func memoryUsesBinaryUnits() {
        #expect(Format.bytes(34_359_738_368) == "32.0 GB")
        #expect(Format.bytes(512 * 1_048_576) == "512 MB")
    }

    @Test func percentClamps() {
        #expect(Format.percent(0.234) == "23%")
        #expect(Format.percent(1.7) == "100%")
        #expect(Format.percent(-1) == "0%")
    }

    @Test func duration() {
        #expect(Format.duration(59) == "0m")
        #expect(Format.duration(4 * 3600 + 12 * 60) == "4h 12m")
        #expect(Format.duration(3 * 86400 + 4 * 3600 + 5) == "3d 4h")
    }
}

@Suite struct CPUMathTests {
    // 2 E cores (0, 1) then 2 P cores (2, 3), like Apple Silicon numbering.
    let topology = CPUTopology(chipName: "Test", clusters: [
        CoreCluster(id: 0, name: "Performance", letter: "P", cores: [2, 3]),
        CoreCluster(id: 1, name: "Efficiency", letter: "E", cores: [0, 1]),
    ])

    func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32) -> CoreTicks {
        CoreTicks(user: user, system: system, idle: idle, nice: 0)
    }

    @Test func perCoreAndClusterLoad() {
        let old = [ticks(0, 0, 0), ticks(0, 0, 0), ticks(0, 0, 0), ticks(0, 0, 0)]
        let new = [ticks(10, 0, 90), ticks(0, 0, 100), ticks(50, 50, 0), ticks(25, 25, 50)]
        let load = CPUSampler.load(from: old, to: new, topology: topology)

        #expect(load.perCore == [0.1, 0, 1, 0.5])
        #expect(load.perCluster[0] == 0.75) // P: (100 + 50) / 200
        #expect(load.perCluster[1] == 0.05) // E: 10 / 200
        #expect(abs(load.total - 0.4) < 1e-9)
        #expect(abs(load.user - 0.2125) < 1e-9)
        #expect(abs(load.system - 0.1875) < 1e-9)
    }

    @Test func countersThatWrapStillGivePositiveDeltas() {
        let old = [ticks(UInt32.max - 9, 0, UInt32.max - 9)]
        let new = [ticks(10, 0, 10)] // +20 user, +20 idle across the wrap
        let single = CPUTopology(chipName: "Test", clusters: [CoreCluster(id: 0, name: "P", letter: "P", cores: [0])])
        #expect(CPUSampler.load(from: old, to: new, topology: single).total == 0.5)
    }
}

@Suite struct RingBufferTests {
    @Test func startsFlatAndKeepsNewest() {
        var buffer = RingBuffer(capacity: 3, fill: 0)
        #expect(buffer.elements == [0, 0, 0])
        for value in 1...4 { buffer.append(value) }
        #expect(buffer.elements == [2, 3, 4])
        #expect(buffer.last == 4)
        #expect(buffer.suffix(2) == [3, 4])
    }
}

@Suite struct NetworkFilterTests {
    @Test func countsOnlyPhysicalEthernetLikeInterfaces() {
        let up = Int32(IFF_UP)
        #expect(NetworkSampler.shouldCount(name: "en0", flags: up))
        #expect(!NetworkSampler.shouldCount(name: "en0", flags: 0))
        #expect(!NetworkSampler.shouldCount(name: "lo0", flags: up | Int32(IFF_LOOPBACK)))
        #expect(!NetworkSampler.shouldCount(name: "utun3", flags: up))
        #expect(!NetworkSampler.shouldCount(name: "awdl0", flags: up))
        #expect(!NetworkSampler.shouldCount(name: "bridge0", flags: up))
    }
}

/// These read the real machine, so they only check invariants.
@Suite struct LiveSamplerTests {
    @Test func topologyCoversEveryCore() {
        let topology = CPUTopology.current()
        #expect(topology.logicalCPUCount == ProcessInfo.processInfo.processorCount)
        #expect(topology.clusters.flatMap(\.cores).sorted() == Array(0..<topology.logicalCPUCount))
        #expect(topology.chipName.hasPrefix("Apple"))
    }

    @Test func cpuSamplesAreFractions() throws {
        let sampler = CPUSampler(topology: .current())
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let load = sampler.sample()
        #expect((0...1).contains(load.total))
        #expect(load.perCore.count == sampler.topology.logicalCPUCount)
        #expect(load.perCore.allSatisfy { (0...1).contains($0) })
    }

    @Test func memoryAddsUp() {
        let stats = MemorySampler().sample()
        #expect(stats.physical > 0)
        #expect(stats.used > 0)
        #expect(stats.used + stats.cached <= stats.physical + stats.physical / 20)
    }

    @Test func networkRatesAreNonNegative() {
        let sampler = NetworkSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let rates = sampler.sample()
        #expect(rates.bytesInPerSecond >= 0)
        #expect(rates.bytesOutPerSecond >= 0)
    }
}
