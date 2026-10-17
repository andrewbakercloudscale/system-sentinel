import Foundation

/// CPU use per executable in time buckets, saved to disk: hourly for the last 7 days, and
/// a second instance in one-minute buckets for the last 6 hours (the 30 min to 6 hour views).
///
/// Unlike `CPUHistory` (per pid, one hour, memory only) this is keyed by path, so a process
/// that restarts, or the dozen Chrome renderers that share one binary, add up under one
/// entry, and it survives quitting the app.
///
/// The unit is core-seconds: 100% for one minute is 60. Averages are core-seconds over the
/// seconds actually sampled, so hours the app was not running neither count as idle nor
/// deflate the figure.
public final class DailyUsage {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        /// Bucket start (seconds since 1970, a multiple of `bucket`) to core-seconds in it.
        /// Called hours because the first store was hourly; the stored format keeps the name.
        public var hours: [Int: Double]
        /// Bucket start to the highest single sample in it, in percent.
        public var peaks: [Int: Double]
    }

    /// One row of a usage view.
    public struct Summary: Equatable, Sendable {
        public let key: String
        public let name: String
        public let coreSeconds: Double
        /// Mean CPU in percent (100 is one core) over the time sampled.
        public let average: Double
        public let peak: Double
        /// When the peak was seen (the start of its bucket).
        public let peakHour: Date?
        /// One value per bucket of the range, oldest first: mean percent in that bucket
        /// (0 where nothing was sampled).
        public let hourly: [Double]
    }

    private struct Stored: Codable {
        var entries: [String: Entry]
        var coverage: [Int: Double]
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Bucket start to seconds actually sampled in it.
    public private(set) var coverage: [Int: Double] = [:]

    public let floor: Double
    /// The longest gap a tick may stand for: a Mac waking from sleep must not count the
    /// whole night as sampled.
    public let maxStep: TimeInterval
    /// Hours kept on disk.
    public let retainHours: Int
    /// Seconds per bucket: 3600 for the 7 day store, 60 for the 6 hour one.
    public let bucket: Int
    /// How often a running app writes the file.
    public let saveEvery: TimeInterval
    private let fileURL: URL?
    private let readOnly: Bool
    private var lastTick: Date?
    private var lastSave: Date?
    private var lastPrunedHour: Int?

    public init(fileURL: URL?, floor: Double = 0.1, maxStep: TimeInterval = 15, retainHours: Int = 24 * 7,
                bucket: Int = 3600, saveEvery: TimeInterval = 60, readOnly: Bool = false) {
        self.fileURL = fileURL
        self.bucket = bucket
        self.saveEvery = saveEvery
        self.floor = floor
        self.maxStep = maxStep
        self.retainHours = retainHours
        self.readOnly = readOnly
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            entries = stored.entries
            coverage = stored.coverage
        }
    }

    /// Removes buckets holding an impossible sample (a `top` glitch once read syslogd at 167
    /// million), so one bad reading cannot take over a week of history. Returns how many.
    @discardableResult
    public func dropOutliers(above limit: Double) -> Int {
        var n = 0
        for (key, var e) in entries {
            for (t, peak) in e.peaks where peak > limit {
                e.peaks[t] = nil
                e.hours[t] = nil
                n += 1
            }
            entries[key] = e.hours.isEmpty ? nil : e
        }
        return n
    }

    public static func hour(_ d: Date) -> Int { Int(d.timeIntervalSince1970) / 3600 * 3600 }

    /// The hour starts of the last `hours` hours, oldest first, ending with the current one.
    public static func hourStarts(at now: Date, hours: Int) -> [Int] {
        (0..<hours).map { hour(now) - (hours - 1 - $0) * 3600 }
    }

    public func start(_ d: Date) -> Int { Int(d.timeIntervalSince1970) / bucket * bucket }

    /// The starts of the last `count` buckets, oldest first, ending with the current one.
    public func starts(at now: Date, count: Int) -> [Int] {
        (0..<count).map { start(now) - (count - 1 - $0) * bucket }
    }

    private func count(_ hours: Int) -> Int { max(hours * 3600 / bucket, 1) }

    /// Adds one tick. The first tick after launch only sets the clock.
    public func record(_ samples: [ProcessSample], at now: Date) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let step = min(max(now.timeIntervalSince(last), 0), maxStep)
        guard step > 0 else { return }
        let h = start(now)
        coverage[h, default: 0] += step
        for s in samples where s.cpu >= floor {
            let key = Self.key(for: s)
            var e = entries[key] ?? Entry(name: Self.label(for: s), hours: [:], peaks: [:])
            e.hours[h, default: 0] += s.cpu / 100 * step
            e.peaks[h] = max(e.peaks[h] ?? 0, s.cpu)
            entries[key] = e
        }
        if lastPrunedHour != h {
            prune(now)
            lastPrunedHour = h
        }
        if lastSave.map({ now.timeIntervalSince($0) >= saveEvery }) ?? true {
            save()
            lastSave = now
        }
    }

    /// Seconds sampled in the last `hours` hours.
    public func sampled(at now: Date, hours: Int = 24) -> TimeInterval { sampled(at: now, buckets: count(hours)) }

    public func sampled(at now: Date, buckets: Int) -> TimeInterval {
        starts(at: now, count: buckets).reduce(0) { $0 + (coverage[$1] ?? 0) }
    }

    /// Seconds sampled in each of the last `hours` hours, oldest first.
    public func coverageHourly(at now: Date, hours: Int = 24) -> [Double] { coverage(at: now, buckets: count(hours)) }

    /// Seconds sampled in each of the last `buckets` buckets, oldest first.
    public func coverage(at now: Date, buckets: Int) -> [Double] {
        starts(at: now, count: buckets).map { coverage[$0] ?? 0 }
    }

    /// Every process seen in the last `hours` hours, heaviest first. `group` folds rows
    /// together, for example by `AppIdentity.groupKey`, naming each group with `name`.
    public func summaries(at now: Date, hours: Int = 24, group: ((String) -> String)? = nil, name: ((String) -> String)? = nil) -> [Summary] {
        summaries(at: now, buckets: count(hours), group: group, name: name)
    }

    public func summaries(at now: Date, buckets: Int, group: ((String) -> String)? = nil, name: ((String) -> String)? = nil) -> [Summary] {
        let starts = starts(at: now, count: buckets)
        let total = sampled(at: now, buckets: buckets)
        var folded: [String: (name: String, hours: [Int: Double], peak: Double, peakHour: Int?)] = [:]
        for (key, e) in entries {
            let g = group?(key) ?? key
            var f = folded[g] ?? (name: name?(g) ?? e.name, hours: [:], peak: 0, peakHour: nil)
            for h in starts {
                if let v = e.hours[h] { f.hours[h, default: 0] += v }
                if let p = e.peaks[h], p > f.peak { f.peak = p; f.peakHour = h }
            }
            folded[g] = f
        }
        return folded.compactMap { key, f in
            let cs = f.hours.values.reduce(0, +)
            guard cs > 0 else { return nil }
            let hourly = starts.map { h -> Double in
                let c = coverage[h] ?? 0
                return c > 0 ? (f.hours[h] ?? 0) / c * 100 : 0
            }
            return Summary(key: key, name: f.name, coreSeconds: cs,
                           average: total > 0 ? cs / total * 100 : 0, peak: f.peak,
                           peakHour: f.peakHour.map { Date(timeIntervalSince1970: Double($0)) }, hourly: hourly)
        }
        .sorted { $0.coreSeconds > $1.coreSeconds }
    }

    /// CPU recorded in whole buckets lying between `from` and `to`: core-seconds and the
    /// seconds sampled. Fills in what an in-memory history lost to a relaunch.
    public func total(from: Date, to: Date) -> (coreSeconds: Double, seconds: Double) {
        let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
        var cs = 0.0, secs = 0.0
        for (h, c) in coverage where Double(h) >= lo && Double(h + bucket) <= hi {
            secs += c
            cs += entries.values.reduce(0) { $0 + ($1.hours[h] ?? 0) }
        }
        return (cs, secs)
    }

    /// Total CPU per hour across everything, oldest first, in percent of one core.
    public func totalHourly(at now: Date, hours: Int = 24) -> [Double] {
        starts(at: now, count: count(hours)).map { h in
            let c = coverage[h] ?? 0
            guard c > 0 else { return 0 }
            return entries.values.reduce(0) { $0 + ($1.hours[h] ?? 0) } / c * 100
        }
    }

    public func save() {
        guard !readOnly, let url = fileURL,
              let data = try? JSONEncoder().encode(Stored(entries: entries, coverage: coverage)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func key(for s: ProcessSample) -> String { s.path }

    static func label(for s: ProcessSample) -> String {
        s.isChromeRenderer ? "Chrome tabs (all renderers)" : s.name
    }

    private func prune(_ now: Date) {
        let since = start(now) - retainHours * 3600 + bucket
        coverage = coverage.filter { $0.key >= since }
        for (key, var e) in entries {
            e.hours = e.hours.filter { $0.key >= since }
            e.peaks = e.peaks.filter { $0.key >= since }
            entries[key] = e.hours.isEmpty ? nil : e
        }
    }
}
