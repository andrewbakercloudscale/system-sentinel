import Foundation

/// What a process is held up by right now, from numbers already measured. Only said of a
/// process doing something: an idle one waits on nothing worth naming.
public enum WaitReason: String, Equatable, Sendable {
    case cpu, disk, memory, network

    public var label: String {
        switch self {
        case .cpu: return "Busy on CPU"
        case .disk: return "Waiting on disk"
        case .memory: return "Waiting on memory"
        case .network: return "Waiting on network"
        }
    }

    /// `state` is the `ps` state; "U" means stuck in the kernel waiting for disk or paging,
    /// which is paging when memory is tight. Rates are bytes per second.
    public static func of(cpu: Double, state: String, diskPerSec: Double, netPerSec: Double, memoryTight: Bool) -> WaitReason? {
        if state.hasPrefix("U") { return memoryTight ? .memory : .disk }
        if cpu >= 50 { return .cpu }
        if diskPerSec >= 5_000_000 { return .disk }
        if netPerSec >= 500_000 { return .network }
        if cpu >= 5 { return .cpu }
        return nil
    }
}

/// An app that stopped responding: the spinning wheel, or System Sentinel's own window
/// freezing. `reason` says what was going on at the time.
public struct Hang: Equatable, Sendable, Codable {
    public let app: String
    public let start: Date
    public let seconds: Double
    public let reason: String
    /// System Sentinel's own window, rather than another app.
    public let own: Bool

    public init(app: String, start: Date, seconds: Double, reason: String, own: Bool = false) {
        self.app = app; self.start = start; self.seconds = seconds; self.reason = reason; self.own = own
    }

    /// One line for a bug report or the clipboard.
    public var line: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(f.string(from: start))  \(app)  \(String(format: "%.1f", seconds)) s  \(reason)"
    }
}

/// Turns "these apps are not responding now", read every few seconds, into hangs with a
/// start and a length. The reason is taken when the hang starts, while the cause is live.
public final class HangTracker {
    public struct Open: Equatable, Sendable {
        public let name: String
        public let since: Date
        public let reason: String
        public var announced = false
    }
    public private(set) var open: [Int32: Open] = [:]
    /// Shorter ones are left out: a wheel for a second is normal.
    public let minimum: TimeInterval

    public init(minimum: TimeInterval = 2) { self.minimum = minimum }

    /// `hung` maps pid to app name. Returns the hangs that ended since the last call.
    public func update(hung: [Int32: String], at now: Date, reason: (Int32) -> String) -> [Hang] {
        for (pid, name) in hung where open[pid] == nil {
            open[pid] = Open(name: name, since: now, reason: reason(pid))
        }
        var ended: [Hang] = []
        for (pid, o) in open where hung[pid] == nil {
            open[pid] = nil
            let length = now.timeIntervalSince(o.since)
            if length >= minimum { ended.append(Hang(app: o.name, start: o.since, seconds: length, reason: o.reason)) }
        }
        return ended.sorted { $0.start < $1.start }
    }

    /// Hangs that have lasted `after` seconds and were not yet announced, marked announced.
    public func due(after: TimeInterval, at now: Date) -> [(pid: Int32, open: Open)] {
        var out: [(pid: Int32, open: Open)] = []
        for (pid, o) in open where !o.announced && now.timeIntervalSince(o.since) >= after {
            open[pid]?.announced = true
            out.append((pid, o))
        }
        return out
    }
}
