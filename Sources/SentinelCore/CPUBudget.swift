import Foundation

/// Keeps System Sentinel from becoming the problem it watches for. Fed our own CPU time
/// (this process and the commands it ran) every few seconds; background jobs ask it before
/// starting and wait while the last minute was over budget.
public struct CPUBudget: Sendable {
    /// Percent of one core, averaged over `window`.
    public let limit: Double
    public let window: TimeInterval
    private var points: [(at: Date, seconds: Double)] = []

    public init(limit: Double = 10, window: TimeInterval = 60) {
        self.limit = limit; self.window = window
    }

    /// `seconds` is the running total of CPU time used so far.
    public mutating func record(seconds: Double, at: Date) {
        points.append((at, seconds))
        let keep = window * 3
        points.removeAll { at.timeIntervalSince($0.at) > keep }
    }

    /// Percent of one core over the last `over` seconds, once there is that much history
    /// (or nearly).
    public func usage(over: TimeInterval? = nil, at now: Date) -> Double? {
        let span = over ?? window
        guard let last = points.last,
              let first = points.first(where: { now.timeIntervalSince($0.at) <= span }) ?? points.first,
              last.at.timeIntervalSince(first.at) >= min(span, 10) else { return nil }
        let wall = last.at.timeIntervalSince(first.at)
        return max(0, last.seconds - first.seconds) / wall * 100
    }

    public func over(at now: Date) -> Bool { (usage(at: now) ?? 0) > limit }
}
