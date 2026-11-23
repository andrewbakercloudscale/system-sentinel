import Foundation

/// Data each app moved, per minute, over the last hour: from the 10-second nettop readings,
/// so it covers the time before the Network tab was opened.
public struct AppDataHistory: Equatable, Sendable {
    public enum Way: String, Sendable { case download, upload, both }
    /// Where the other end was: the internet, or this Mac and private networks (loopback,
    /// virtual machines, the home or office network, VPN addresses).
    public enum Scope: String, Sendable { case internet, local, all }

    public struct Minute: Equatable, Sendable {
        public let start: Date
        /// App key to bytes received and sent in this minute.
        public var down: [String: UInt64] = [:]
        public var up: [String: UInt64] = [:]
        /// The part of `down` and `up` that stayed on this Mac or a private network.
        public var localDown: [String: UInt64] = [:]
        public var localUp: [String: UInt64] = [:]
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
    /// `local` is the part of each app's bytes whose other end was local.
    public mutating func add(_ bytes: [String: (name: String, down: UInt64, up: UInt64)],
                             local: [String: (down: UInt64, up: UInt64)] = [:], at now: Date) {
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        if minutes.last?.start != start { minutes.append(Minute(start: start)) }
        var m = minutes.removeLast()
        for (k, v) in bytes where v.down + v.up > 0 {
            names[k] = v.name
            m.down[k, default: 0] += v.down
            m.up[k, default: 0] += v.up
            if let l = local[k] {
                m.localDown[k, default: 0] += min(l.down, v.down)
                m.localUp[k, default: 0] += min(l.up, v.up)
            }
        }
        minutes.append(m)
        minutes.removeAll { now.timeIntervalSince($0.start) >= keep }
        let live = Set(minutes.flatMap { Array($0.down.keys) + Array($0.up.keys) })
        names = names.filter { live.contains($0.key) }
    }

    /// One minute's bytes by app: received, sent, or both; internet, local or all.
    static func bytes(_ m: Minute, _ way: Way, _ scope: Scope = .all) -> [String: UInt64] {
        func pick(_ all: [String: UInt64], _ local: [String: UInt64]) -> [String: UInt64] {
            switch scope {
            case .all: return all
            case .local: return local
            case .internet: return all.reduce(into: [:]) { r, e in r[e.key] = e.value - min(e.value, local[e.key] ?? 0) }
            }
        }
        let d = pick(m.down, m.localDown), u = pick(m.up, m.localUp)
        switch way {
        case .download: return d
        case .upload: return u
        case .both: return d.merging(u, uniquingKeysWith: +)
        }
    }

    /// Each app's total over the window.
    public func totals(_ way: Way, _ scope: Scope = .all) -> [String: UInt64] {
        var t: [String: UInt64] = [:]
        for m in minutes { for (k, b) in Self.bytes(m, way, scope) { t[k, default: 0] += b } }
        return t
    }

    /// The `n` apps that moved the most, biggest first.
    public func top(_ n: Int, _ way: Way, _ scope: Scope = .all) -> [String] {
        totals(way, scope).filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map(\.key)
    }

    /// Bars for a chart: the top `n` apps per minute, everything else as "Other".
    public func slices(_ n: Int, _ way: Way, _ scope: Scope = .all) -> [Slice] {
        let keys = top(n, way, scope)
        let shown = Set(keys)
        var out: [Slice] = []
        for m in minutes {
            let by = Self.bytes(m, way, scope)
            for k in keys { if let b = by[k], b > 0 { out.append(Slice(start: m.start, key: k, name: names[k] ?? k, bytes: b)) } }
            let rest = by.filter { !shown.contains($0.key) }.values.reduce(0, +)
            if rest > 0 { out.append(Slice(start: m.start, key: "other", name: "Other", bytes: rest)) }
        }
        return out
    }
}
