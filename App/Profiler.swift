import Foundation

/// Per-phase CPU cost of each tick, for checking the PRD §8 budgets.
/// Run the app binary with `FLATLINE_PROFILE=1`; every 60 ticks it prints the
/// average thread CPU time per phase to stderr. Thread CPU time ignores time
/// spent preempted, so results hold up on a busy machine.
@MainActor
enum Profiler {
    static let enabled = ProcessInfo.processInfo.environment["FLATLINE_PROFILE"] != nil
    private static var totals: [String: UInt64] = [:]
    private static var order: [String] = []
    private static var ticks = 0

    static func measure<T>(_ name: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = body()
        let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        if totals[name] == nil { order.append(name) }
        totals[name, default: 0] += elapsed
        return result
    }

    static func endTick() {
        guard enabled else { return }
        ticks += 1
        guard ticks % 60 == 0 else { return }
        let line = order.map { "\($0)=\(totals[$0, default: 0] / UInt64(ticks) / 1000)µs" }.joined(separator: " ")
        FileHandle.standardError.write(Data("[\(ticks)] avg/tick \(line)\n".utf8))
    }
}
