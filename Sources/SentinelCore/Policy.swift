import Foundation

/// What to do when a process becomes a bad actor.
public enum Policy: Codable, Equatable, Sendable {
    /// Notify; the owner decides. The default for anything not configured.
    case alert
    /// Terminate it, then tell the owner.
    case autoKill
    /// Say nothing until the date, or ever when nil.
    case ignore(until: Date?)
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
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(policies) {
            try? data.write(to: url, options: .atomic)
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
