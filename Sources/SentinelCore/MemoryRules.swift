import Foundation

/// "Quit this app when it holds more than N GB while you are not using it": per app, keyed
/// by the Memory tab's grouping key, so a rule outlives the app's pids.
public struct MemoryRule: Codable, Equatable, Sendable {
    public var name: String
    /// Bytes, counted as the Memory tab counts them (with its virtual machine, for a VM host).
    public var limit: UInt64

    public init(name: String, limit: UInt64) {
        self.name = name
        self.limit = limit
    }

    public var label: String { "auto-quit over \(limit >> 30) GB" }

    /// The limits offered: 2, 4, 8 and 16 GB.
    public static let choices: [UInt64] = [2, 4, 8, 16].map { UInt64($0) << 30 }
}

public final class MemoryRuleStore {
    public private(set) var rules: [String: MemoryRule]
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: MemoryRule].self, from: data) {
            rules = decoded
        } else {
            rules = [:]
        }
    }

    /// nil removes the rule.
    public func set(_ rule: MemoryRule?, for key: String) {
        rules[key] = rule
        guard let url = fileURL, let data = try? JSONEncoder().encode(rules) else { return }
        Diagnostics.write(data, to: url, what: "memory rules")
    }
}

/// Decides when a memory rule fires: over its limit on every reading for `window`, never
/// while it is the app in front, and at most once per `cooldown`, so an app that is
/// reopened and grows again is not quit in a loop.
public final class MemoryRuleWatch {
    public struct Reading: Equatable, Sendable {
        public let key: String
        public let bytes: UInt64
        public let frontmost: Bool
        public init(key: String, bytes: UInt64, frontmost: Bool) {
            self.key = key
            self.bytes = bytes
            self.frontmost = frontmost
        }
    }

    public let window: TimeInterval
    public let cooldown: TimeInterval
    private var overSince: [String: Date] = [:]
    private var fired: [String: Date] = [:]

    public init(window: TimeInterval = 300, cooldown: TimeInterval = 1800) {
        self.window = window
        self.cooldown = cooldown
    }

    /// The keys to quit now.
    public func update(_ readings: [Reading], rules: [String: MemoryRule], at now: Date) -> [String] {
        var due: [String] = []
        var seen: Set<String> = []
        for r in readings {
            guard let rule = rules[r.key] else { continue }
            seen.insert(r.key)
            guard r.bytes > rule.limit, !r.frontmost else {
                overSince[r.key] = nil
                continue
            }
            let since = overSince[r.key] ?? now
            overSince[r.key] = since
            guard now.timeIntervalSince(since) >= window else { continue }
            if let last = fired[r.key], now.timeIntervalSince(last) < cooldown { continue }
            fired[r.key] = now
            overSince[r.key] = nil
            due.append(r.key)
        }
        for k in overSince.keys where !seen.contains(k) { overSince[k] = nil }
        return due
    }
}

extension MemoryAnalysis {
    /// One app's change in memory held outside RAM over a stretch of the timeline.
    public struct Moved: Equatable, Sendable {
        public let key: String
        public let name: String
        /// Positive: more went out to compression or swap. Negative: it came back into RAM
        /// (or the app quit).
        public let delta: Int64
    }

    /// Which of the largest apps had memory moved out of RAM, or back, between the last
    /// reading before `from` and the last one before `to`. macOS counts swap for the whole
    /// Mac only, so this is the closest per-app view: compressed and swapped together.
    public static func moved(_ points: [MemoryHistory.Point], from: Int, to: Int, minimum: UInt64 = 64 << 20) -> [Moved] {
        let withApps = points.filter { !$0.apps.isEmpty }
        guard let before = withApps.last(where: { $0.t < from }) ?? withApps.first,
              let after = withApps.last(where: { $0.t < to }), after.t > before.t else { return [] }
        let was = Dictionary(before.apps.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Dictionary(after.apps.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Moved] = []
        for key in Set(was.keys).union(now.keys) {
            // An app that dropped out of the top list is unknown, not zero: skip it.
            guard let b = was[key], let a = now[key], let ob = b.outOfRAM, let oa = a.outOfRAM else { continue }
            let d = Int64(oa) - Int64(ob)
            if d.magnitude >= minimum { out.append(Moved(key: key, name: a.name, delta: d)) }
        }
        return out.sorted { $0.delta.magnitude > $1.delta.magnitude }
    }
}
