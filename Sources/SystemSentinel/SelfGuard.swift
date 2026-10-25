import Foundation
import SentinelCore

/// System Sentinel must never be the app hogging the Mac. Our own CPU (this process and the
/// commands it ran) is measured every tick; automatic background jobs go through `when`, which
/// holds them while the last minute was over budget. Jobs you start with a button run at once.
@MainActor
enum SelfGuard {
    private(set) static var budget = CPUBudget(limit: 10, window: 60)
    private static var waiting: [String: Int] = [:]

    /// Run at launch: everything we do loses to the apps you are using when the Mac is busy.
    static func start() {
        setpriority(PRIO_PROCESS, 0, 5)
    }

    /// CPU seconds used so far by this process and the commands it has finished running.
    nonisolated static func cpuSeconds() -> Double {
        func secs(_ who: Int32) -> Double {
            var u = rusage()
            getrusage(who, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        return secs(RUSAGE_SELF) + secs(RUSAGE_CHILDREN)
    }

    static func record(at now: Date = Date()) { budget.record(seconds: cpuSeconds(), at: now) }

    /// Percent of one core over the last minute.
    static var usage: Double? { budget.usage(at: Date()) }

    /// Runs `job` now, or once the last minute is back under budget (checked each minute,
    /// for up to 15 minutes, then it runs anyway so nothing is starved for good).
    static func when(_ name: String, _ job: @escaping @MainActor () -> Void) {
        let tries = waiting[name] ?? 0
        if !budget.over(at: Date()) || tries >= 15 {
            if tries > 0 { waiting[name] = nil }
            job()
            return
        }
        if tries == 0 {
            Diagnostics.report("self", "Held back \(name): System Sentinel used \(CPUScale.text(usage ?? 0)) of the Mac in the last minute (limit \(CPUScale.text(budget.limit)))")
        }
        waiting[name] = tries + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { when(name, job) }
    }
}
