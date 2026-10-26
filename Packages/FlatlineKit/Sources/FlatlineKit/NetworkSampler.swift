import Darwin
import SystemConfiguration

public struct NetworkRates: Sendable, Equatable {
    public var bytesInPerSecond: Double = 0
    public var bytesOutPerSecond: Double = 0

    public init(bytesInPerSecond: Double = 0, bytesOutPerSecond: Double = 0) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

/// Reads 64-bit per-interface byte counters. (The 32-bit `getifaddrs`
/// counters wrap at 4 GiB.)
///
/// Listing every interface (`NET_RT_IFLIST2`) costs 0.5–3.5 ms because the
/// kernel serializes all of them, including dozens of `utun`, `llw` and `anpi`
/// interfaces. So the list is only rebuilt when the system's interface count
/// changes (or every `discoveryInterval` as a backstop); each tick reads just
/// the `en*` interfaces through `ifmibdata`, at under a microsecond each.
public final class NetworkSampler {
    private struct Counters {
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    public static let discoveryInterval: Duration = .seconds(300)

    private var previous: [UInt16: Counters] = [:]
    private var lastSample: ContinuousClock.Instant?
    private var lastDiscovery: ContinuousClock.Instant?
    private var candidates: [UInt16] = []
    private var interfaceCount: Int32 = -1
    private var names: [UInt16: String] = [:]
    private var listBuffer: [UInt8] = []

    /// Bytes counted since launch or the last `resetSession()`.
    public private(set) var sessionIn: UInt64 = 0
    public private(set) var sessionOut: UInt64 = 0

    public init() {}

    public func resetSession() {
        sessionIn = 0
        sessionOut = 0
    }

    /// Physical `en*` interfaces only: loopback, VPN tunnels (which would
    /// double-count traffic), AWDL and bridges are skipped.
    public static func shouldCount(name: String, flags: Int32) -> Bool {
        flags & IFF_UP != 0 && flags & IFF_LOOPBACK == 0 && name.hasPrefix("en")
    }

    /// Rates since the previous call. The first call returns zeros.
    public func sample(now: ContinuousClock.Instant = .now) -> NetworkRates {
        let count = Self.systemInterfaceCount()
        if count != interfaceCount || lastDiscovery.map({ now - $0 >= Self.discoveryInterval }) ?? true {
            discoverInterfaces()
            interfaceCount = count
            lastDiscovery = now
        }
        let current = readCounters()
        defer {
            previous = current
            lastSample = now
        }
        guard let lastSample else { return NetworkRates() }

        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        for (index, counters) in current {
            // New interfaces and counter resets contribute nothing this tick.
            guard let old = previous[index] else { continue }
            if counters.bytesIn >= old.bytesIn { deltaIn += counters.bytesIn - old.bytesIn }
            if counters.bytesOut >= old.bytesOut { deltaOut += counters.bytesOut - old.bytesOut }
        }
        sessionIn += deltaIn
        sessionOut += deltaOut

        let elapsed = (now - lastSample) / .seconds(1)
        guard elapsed > 0 else { return NetworkRates() }
        return NetworkRates(bytesInPerSecond: Double(deltaIn) / elapsed, bytesOutPerSecond: Double(deltaOut) / elapsed)
    }

    private func readCounters() -> [UInt16: Counters] {
        var result: [UInt16: Counters] = [:]
        for index in candidates {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else {
                // The interface went away; rescan on the next tick.
                lastDiscovery = nil
                continue
            }
            let flags = Int32(truncatingIfNeeded: data.ifmd_flags)
            guard Self.shouldCount(name: names[index] ?? "", flags: flags) else { continue }
            result[index] = Counters(bytesIn: data.ifmd_data.ifi_ibytes, bytesOut: data.ifmd_data.ifi_obytes)
        }
        return result
    }

    private static func systemInterfaceCount() -> Int32 {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, u_int(mib.count), &count, &size, nil, 0) == 0 ? count : -1
    }

    /// Refreshes the indices of `en*` interfaces, up or not (link state is
    /// checked every tick).
    private func discoverInterfaces() {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return }
        // Leave room for interfaces that appear between the two calls.
        if listBuffer.count < length { listBuffer = [UInt8](repeating: 0, count: length + 1024) }
        guard sysctl(&mib, u_int(mib.count), &listBuffer, &length, nil, 0) == 0 else { return }

        // Indices can be reused by a different interface after a removal.
        names.removeAll(keepingCapacity: true)
        var found: [UInt16] = []
        listBuffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard header.ifm_type == RTM_IFINFO2 else { continue }
                let name = name(for: header.ifm_index)
                if name.hasPrefix("en") { found.append(header.ifm_index) }
            }
        }
        candidates = found
    }

    private func name(for index: UInt16) -> String {
        if let cached = names[index] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let name = if_indextoname(UInt32(index), &buffer) != nil
            ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            : ""
        names[index] = name
        return name
    }
}

public struct NetworkInterfaceInfo: Sendable, Equatable {
    public var name: String
    public var ipv4: String?
}

public enum NetworkInfo {
    /// The interface macOS routes IPv4 traffic through by default, with its address.
    public static func primary() -> NetworkInterfaceInfo? {
        guard let store = SCDynamicStoreCreate(nil, "flatline" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String else { return nil }
        return NetworkInterfaceInfo(name: name, ipv4: ipv4Address(of: name))
    }

    private static func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
        }
        return nil
    }
}
