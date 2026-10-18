import Foundation

/// A resource alarm: fires when a value stays over its limit for long enough, then stays quiet
/// until the value has dropped back under the limit and an hour has passed.
public struct AlarmWatch: Sendable {
    public var overSince: Date?
    public var lastFired: Date?
    /// Fired and not yet back under the limit.
    public var latched = false
    public static let quiet: TimeInterval = 3600

    public init() {}

    /// True when the alarm should go off now.
    public mutating func update(over: Bool, holdFor minutes: Double, at now: Date) -> Bool {
        guard over else {
            overSince = nil
            latched = false
            return false
        }
        let since = overSince ?? now
        overSince = since
        guard !latched, now.timeIntervalSince(since) >= minutes * 60 else { return false }
        if let last = lastFired, now.timeIntervalSince(last) < Self.quiet { return false }
        latched = true
        lastFired = now
        return true
    }
}

/// The resource alarms that can be set in Settings.
public enum ResourceAlarm: String, CaseIterable, Sendable {
    case cpu, swap, pressure, disk

    public var title: String {
        switch self {
        case .cpu: return "Whole Mac busy"
        case .swap: return "Swap used"
        case .pressure: return "Memory pressure"
        case .disk: return "Disk space low"
        }
    }
}
