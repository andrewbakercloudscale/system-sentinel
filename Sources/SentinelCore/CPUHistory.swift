import Foundation

/// CPU over time per process, for the 1, 15 and 60 minute columns and the sparklines.
///
/// Averages are energy-like: a process that ran hot for 6 minutes out of 60 shows a tenth
/// of that in the 60 minute column, so the columns answer "what has been chewing my CPU",
/// not "how hot is it when it runs". The denominator is capped at how long the app has
/// been recording, so a freshly started app does not deflate every number.
///
/// Only samples above `floor` are stored. Idle processes cost nothing, which keeps an hour
/// of history for 700 processes at a few hundred kilobytes.
public final class CPUHistory {
    public let retention: TimeInterval
    public let interval: TimeInterval
    public let floor: Double

    private var series: [Int32: [(Date, Double)]] = [:]
    private var totals: [(Date, Double)] = []
    private var started: Date?

    public init(retention: TimeInterval = 3600, interval: TimeInterval = 5, floor: Double = 0.1) {
        self.retention = retention
        self.interval = interval
        self.floor = floor
    }

    public func record(_ samples: [ProcessSample], at now: Date) {
        if started == nil { started = now }
        let cutoff = now.addingTimeInterval(-retention)
        var total = 0.0
        var live: Set<Int32> = []
        for s in samples {
            live.insert(s.pid)
            total += s.cpu
            guard s.cpu >= floor else { continue }
            series[s.pid, default: []].append((now, s.cpu))
        }
        totals.append((now, total))
        totals.removeAll { $0.0 < cutoff }
        for (pid, points) in series {
            let kept = points.filter { $0.0 >= cutoff }
            // A dead pid is dropped, so a reused pid does not inherit its history.
            series[pid] = (kept.isEmpty || !live.contains(pid)) ? nil : kept
        }
    }

    /// Mean CPU of `pid` over the last `window` seconds, treating unrecorded samples as 0.
    public func average(_ pid: Int32, over window: TimeInterval, at now: Date) -> Double {
        let span = effectiveSpan(window, now)
        guard span > 0, let points = series[pid] else { return 0 }
        let since = now.addingTimeInterval(-window)
        let sum = points.reduce(0.0) { $0 + ($1.0 > since ? $1.1 : 0) }
        return sum * interval / span
    }

    /// Mean total CPU across all processes over the window.
    public func totalAverage(over window: TimeInterval, at now: Date) -> Double {
        let since = now.addingTimeInterval(-window)
        let pts = totals.filter { $0.0 > since }
        guard !pts.isEmpty else { return 0 }
        return pts.reduce(0.0) { $0 + $1.1 } / Double(pts.count)
    }

    /// The last `buckets` buckets over `window`, each the mean of its samples, for a sparkline.
    public func sparkline(_ pid: Int32?, over window: TimeInterval, buckets: Int, at now: Date) -> [Double] {
        let points = pid.map { series[$0] ?? [] } ?? totals
        let width = window / Double(buckets)
        let perBucket = max(width / interval, 1)
        var sums = [Double](repeating: 0, count: buckets)
        let start = now.addingTimeInterval(-window)
        for (t, v) in points where t > start {
            let i = min(Int(t.timeIntervalSince(start) / width), buckets - 1)
            sums[i] += v
        }
        return sums.map { $0 / perBucket }
    }

    /// How much history there is, so the UI can say "15 min (4 min so far)".
    public func recorded(at now: Date) -> TimeInterval {
        started.map { now.timeIntervalSince($0) + interval } ?? 0
    }

    private func effectiveSpan(_ window: TimeInterval, _ now: Date) -> TimeInterval {
        min(window, recorded(at: now))
    }
}

/// Which app a process belongs to, for icons and the grouped view.
public enum AppIdentity {
    /// The OUTERMOST .app bundle in the path, so Chrome's renderer helpers, nested three
    /// bundles deep, belong to Google Chrome.app. nil for a bare binary (/usr/libexec/...).
    public static func bundlePath(of path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    /// The name to group and show under: the app's name, else the binary's.
    public static func appName(of path: String) -> String {
        if let b = bundlePath(of: path) {
            return ((b as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return (path as NSString).lastPathComponent
    }

    /// The grouping key: the bundle when there is one, else the executable.
    public static func groupKey(of path: String) -> String {
        bundlePath(of: path) ?? path
    }

    /// A system binary rather than something the owner installed.
    public static func isSystem(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
            || !path.hasPrefix("/")
    }
}
