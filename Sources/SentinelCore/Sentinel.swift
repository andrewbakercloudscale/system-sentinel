import Foundation

/// What one tick decided, for the UI to show or notify.
public enum SentinelEvent: Equatable, Sendable {
    /// Hot for the whole window, policy alert: ask the owner.
    case alert(ProcessSample)
    /// Auto-killed under its policy.
    case autoKilled(ProcessSample, KillOutcome)
    /// Policy says auto-kill, but it was not done (root, protected, or rate limited); alerting instead.
    case autoKillWithheld(ProcessSample, reason: String)
}

/// The engine: sample, detect, apply policy. The app calls `tick()` on a timer.
public final class Sentinel {
    public let detector: Detector
    public let policies: PolicyStore
    public let history: History
    public let limiter: RateLimiter
    public private(set) var latest: [ProcessSample] = []

    private let sampler: () throws -> [ProcessSample]
    private let killer: (ProcessSample) -> KillOutcome

    public init(
        detector: Detector = Detector(),
        policies: PolicyStore,
        history: History,
        limiter: RateLimiter = RateLimiter(),
        sampler: @escaping () throws -> [ProcessSample] = ProcessSampler.sample,
        killer: @escaping (ProcessSample) -> KillOutcome = { Killer.kill($0) }
    ) {
        self.detector = detector
        self.policies = policies
        self.history = history
        self.limiter = limiter
        self.sampler = sampler
        self.killer = killer
    }

    /// The top `n` processes by CPU from the latest sample.
    public func top(_ n: Int = 8) -> [ProcessSample] {
        Array(latest.sorted { $0.cpu > $1.cpu }.prefix(n))
    }

    /// Total CPU across all processes, in percent of one core.
    public var totalCPU: Double { latest.reduce(0) { $0 + $1.cpu } }

    @discardableResult
    public func tick(at now: Date = Date()) throws -> [SentinelEvent] {
        latest = try sampler()
        var events: [SentinelEvent] = []
        for actor in detector.update(latest, at: now) {
            let s = actor.sample
            if Safety.isProtected(s) { continue }
            switch policies.policy(for: s.path, at: now) {
            case .ignore:
                continue
            case .alert:
                history.record(.flagged, s, at: now)
                events.append(.alert(s))
            case .autoKill:
                if !Safety.canAutoKill(s) {
                    let why = s.isRoot ? "runs as root, needs the admin password" : "not owned by this user"
                    history.record(.flagged, s, detail: "auto-kill withheld: \(why)", at: now)
                    events.append(.autoKillWithheld(s, reason: why))
                } else if !limiter.allow(s.path, at: now) {
                    let why = "killed \(limiter.limit) times in the last hour and back again"
                    history.record(.rateLimited, s, detail: why, at: now)
                    events.append(.autoKillWithheld(s, reason: why))
                } else {
                    let outcome = killer(s)
                    let ok = outcome == .terminated || outcome == .forceKilled || outcome == .alreadyGone
                    history.record(ok ? .autoKilled : .killFailed, s, detail: "\(outcome)", at: now)
                    events.append(.autoKilled(s, outcome))
                }
            }
        }
        return events
    }

    /// A manual kill from the menu or a notification.
    public func kill(_ s: ProcessSample, at now: Date = Date()) -> KillOutcome {
        let outcome = killer(s)
        let ok = outcome == .terminated || outcome == .forceKilled || outcome == .alreadyGone
        history.record(ok ? .killed : .killFailed, s, detail: "\(outcome)", at: now)
        return outcome
    }
}
