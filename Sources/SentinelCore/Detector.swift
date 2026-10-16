import Foundation

/// A process that has stayed hot for the whole window.
public struct BadActor: Equatable, Sendable {
    public let sample: ProcessSample
    /// When it first went over the threshold in this episode.
    public let hotSince: Date
}

/// Decides when a hot process becomes a bad actor.
///
/// A process is a bad actor once it has been at or above `threshold` on every sample for
/// `window`. One sample below the threshold ends the episode, so a build that spikes and
/// settles never alerts, while a stuck daemon does. Each episode is reported once; the
/// process must cool down and heat up again to be reported again.
public final class Detector {
    public var threshold: Double
    public var window: TimeInterval

    private var hotSince: [Int32: Date] = [:]
    private var reported: Set<Int32> = []

    public init(threshold: Double = 80, window: TimeInterval = 120) {
        self.threshold = threshold
        self.window = window
    }

    /// Feeds one sample set; returns the processes that became bad actors at this sample.
    public func update(_ samples: [ProcessSample], at now: Date) -> [BadActor] {
        var seen: Set<Int32> = []
        var fresh: [BadActor] = []
        for s in samples {
            seen.insert(s.pid)
            guard s.cpu >= threshold else {
                hotSince[s.pid] = nil
                reported.remove(s.pid)
                continue
            }
            let since = hotSince[s.pid] ?? now
            hotSince[s.pid] = since
            if now.timeIntervalSince(since) >= window, !reported.contains(s.pid) {
                reported.insert(s.pid)
                fresh.append(BadActor(sample: s, hotSince: since))
            }
        }
        // A pid that vanished is forgotten, so a reused pid starts a fresh episode.
        for pid in hotSince.keys where !seen.contains(pid) { hotSince[pid] = nil }
        reported.formIntersection(seen)
        return fresh
    }

    /// How long a pid has been hot, for the menu. nil when it is not hot.
    public func hotDuration(of pid: Int32, at now: Date) -> TimeInterval? {
        hotSince[pid].map { now.timeIntervalSince($0) }
    }
}
