import Foundation

/// What to do when a process becomes a bad actor.
public enum Policy: Codable, Equatable, Sendable {
    /// Notify; the owner decides. The default for anything not configured.
    case alert
    /// Terminate it, then tell the owner.
    case autoKill
    /// Auto-kill while the Mac runs on battery; alert when plugged in.
    case autoKillOnBattery
    /// Auto-kill on battery below this charge; alert otherwise.
    case autoKillBelow(percent: Int)
    /// Ignore between these hours (24 h clock, `to` exclusive, may wrap past midnight); alert otherwise.
    case ignoreDuring(from: Int, to: Int)
    /// Say nothing until the date, or ever when nil.
    case ignore(until: Date?)
}

extension Policy {
    /// What the policy means at this moment.
    public func resolved(at now: Date, onBattery: Bool, percent: Int?, calendar: Calendar = .current) -> Policy {
        switch self {
        case .autoKillOnBattery:
            return onBattery ? .autoKill : .alert
        case .autoKillBelow(let p):
            return onBattery && (percent ?? 100) < p ? .autoKill : .alert
        case .ignoreDuring(let from, let to):
            let h = calendar.component(.hour, from: now)
            let inside = from <= to ? (h >= from && h < to) : (h >= from || h < to)
            return inside ? .ignore(until: nil) : .alert
        default:
            return self
        }
    }

    public var label: String {
        switch self {
        case .alert: return "alert"
        case .autoKill: return "auto-kill"
        case .autoKillOnBattery: return "auto-kill on battery"
        case .autoKillBelow(let p): return "auto-kill under \(p)% battery"
        case .ignoreDuring(let a, let b): return String(format: "ignored %02d:00–%02d:00", a, b)
        case .ignore(let until?): return "ignored until \(until.formatted(date: .omitted, time: .shortened))"
        case .ignore(nil): return "always ignored"
        }
    }

    public var killsSometimes: Bool {
        switch self {
        case .autoKill, .autoKillOnBattery, .autoKillBelow: return true
        default: return false
        }
    }
}

/// Per-process policies, keyed by executable path so a choice outlives the pid.
///
/// Chrome renderers share one executable path, so a policy for one tab applies to every
/// tab. That is deliberate: there is no stable identity for a tab outside Chrome.
public final class PolicyStore {
    public private(set) var policies: [String: Policy]
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Policy].self, from: data) {
            policies = decoded
        } else {
            policies = [:]
        }
    }

    /// The policy in force now; an expired ignore reads as alert.
    public func policy(for path: String, at now: Date = Date()) -> Policy {
        switch policies[path] {
        case .none: return .alert
        case .ignore(let until?) where until <= now: return .alert
        case let p?: return p
        }
    }

    public func set(_ policy: Policy, for path: String) {
        policies[path] = policy == .alert ? nil : policy
        save()
    }

    private func save() {
        guard let url = fileURL else { return }
        if let data = try? JSONEncoder().encode(policies) {
            Diagnostics.write(data, to: url, what: "rules")
        }
    }
}

/// At most `limit` auto-kills of one executable per `period`.
///
/// A process that keeps coming back after being killed needs a person, not a loop: past
/// the limit the app alerts instead of killing.
public final class RateLimiter {
    public let limit: Int
    public let period: TimeInterval
    private var events: [String: [Date]] = [:]

    public init(limit: Int = 3, period: TimeInterval = 3600) {
        self.limit = limit
        self.period = period
    }

    /// Records an attempt if allowed and returns true; returns false when over the limit.
    public func allow(_ key: String, at now: Date) -> Bool {
        let recent = (events[key] ?? []).filter { now.timeIntervalSince($0) < period }
        guard recent.count < limit else {
            events[key] = recent
            return false
        }
        events[key] = recent + [now]
        return true
    }
}
