import Foundation

/// Data each app moved, per minute, over the last hour: from the 10-second nettop readings,
/// so it covers the time before the Network tab was opened.
public struct AppDataHistory: Equatable, Sendable {
    public enum Way: String, Sendable { case download, upload }

    public struct Minute: Equatable, Sendable {
        public let start: Date
        /// App key to bytes received and sent in this minute.
        public var down: [String: UInt64] = [:]
        public var up: [String: UInt64] = [:]
    }

    /// One bar segment: an app's bytes in one minute.
    public struct Slice: Equatable, Sendable, Identifiable {
        public let start: Date
        public let key: String
        public let name: String
        public let bytes: UInt64
        public var id: String { "\(start.timeIntervalSince1970)|\(key)" }
    }

    public private(set) var minutes: [Minute] = []
    /// App key to its display name, the latest seen.
    public private(set) var names: [String: String] = [:]
    public let keep: TimeInterval

    public init(keep: TimeInterval = 3600) { self.keep = keep }

    /// Adds one reading's bytes since the previous one, by app key.
    public mutating func add(_ bytes: [String: (name: String, down: UInt64, up: UInt64)], at now: Date) {
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        if minutes.last?.start != start { minutes.append(Minute(start: start)) }
        var m = minutes.removeLast()
        for (k, v) in bytes where v.down + v.up > 0 {
            names[k] = v.name
            m.down[k, default: 0] += v.down
            m.up[k, default: 0] += v.up
        }
        minutes.append(m)
        minutes.removeAll { now.timeIntervalSince($0.start) >= keep }
        let live = Set(minutes.flatMap { Array($0.down.keys) + Array($0.up.keys) })
        names = names.filter { live.contains($0.key) }
    }

    /// Each app's total over the window, one way.
    public func totals(_ way: Way) -> [String: UInt64] {
        var t: [String: UInt64] = [:]
        for m in minutes { for (k, b) in (way == .download ? m.down : m.up) { t[k, default: 0] += b } }
        return t
    }

    /// The `n` apps that moved the most, one way, biggest first.
    public func top(_ n: Int, _ way: Way) -> [String] {
        totals(way).filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map(\.key)
    }

    /// Bars for a chart: the top `n` apps per minute, everything else as "Other".
    public func slices(_ n: Int, _ way: Way) -> [Slice] {
        let keys = top(n, way)
        let shown = Set(keys)
        var out: [Slice] = []
        for m in minutes {
            let by = way == .download ? m.down : m.up
            for k in keys { if let b = by[k], b > 0 { out.append(Slice(start: m.start, key: k, name: names[k] ?? k, bytes: b)) } }
            let rest = by.filter { !shown.contains($0.key) }.values.reduce(0, +)
            if rest > 0 { out.append(Slice(start: m.start, key: "other", name: "Other", bytes: rest)) }
        }
        return out
    }
}
