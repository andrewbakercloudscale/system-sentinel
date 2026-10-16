import Foundation

/// CPU use per executable over the last 7 days, in hourly buckets, saved to disk.
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
        /// Hour start (seconds since 1970, a multiple of 3600) to core-seconds in that hour.
        public var hours: [Int: Double]
        /// Hour start to the highest single sample in that hour, in percent.
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
        /// When the peak was seen (the start of its hour).
        public let peakHour: Date?
        /// One value per hour of the range, oldest first: mean percent in that hour
        /// (0 where nothing was sampled).
        public let hourly: [Double]
    }

    private struct Stored: Codable {
        var entries: [String: Entry]
        var coverage: [Int: Double]
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Hour start to seconds actually sampled in that hour.
    public private(set) var coverage: [Int: Double] = [:]

    public let floor: Double
    /// The longest gap a tick may stand for: a Mac waking from sleep must not count the
    /// whole night as sampled.
    public let maxStep: TimeInterval
    /// Hours kept on disk.
    public let retainHours: Int
    private let fileURL: URL?
    private let readOnly: Bool
    private var lastTick: Date?
    private var lastSave: Date?
    private var lastPrunedHour: Int?

    public init(fileURL: URL?, floor: Double = 0.1, maxStep: TimeInterval = 15, retainHours: Int = 24 * 7, readOnly: Bool = false) {
        self.fileURL = fileURL
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

    public static func hour(_ d: Date) -> Int { Int(d.timeIntervalSince1970) / 3600 * 3600 }

    /// The hour starts of the last `hours` hours, oldest first, ending with the current one.
    public static func hourStarts(at now: Date, hours: Int) -> [Int] {
        (0..<hours).map { hour(now) - (hours - 1 - $0) * 3600 }
    }

    /// Adds one tick. The first tick after launch only sets the clock.
    public func record(_ samples: [ProcessSample], at now: Date) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let step = min(max(now.timeIntervalSince(last), 0), maxStep)
        guard step > 0 else { return }
        let h = Self.hour(now)
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
        if lastSave.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            save()
            lastSave = now
        }
    }

    /// Seconds sampled in the last `hours` hours.
    public func sampled(at now: Date, hours: Int = 24) -> TimeInterval {
        Self.hourStarts(at: now, hours: hours).reduce(0) { $0 + (coverage[$1] ?? 0) }
    }

    /// Seconds sampled in each of the last `hours` hours, oldest first.
    public func coverageHourly(at now: Date, hours: Int = 24) -> [Double] {
        Self.hourStarts(at: now, hours: hours).map { coverage[$0] ?? 0 }
    }

    /// Every process seen in the last `hours` hours, heaviest first. `group` folds rows
    /// together, for example by `AppIdentity.groupKey`, naming each group with `name`.
    public func summaries(at now: Date, hours: Int = 24, group: ((String) -> String)? = nil, name: ((String) -> String)? = nil) -> [Summary] {
        let starts = Self.hourStarts(at: now, hours: hours)
        let total = sampled(at: now, hours: hours)
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

    /// Total CPU per hour across everything, oldest first, in percent of one core.
    public func totalHourly(at now: Date, hours: Int = 24) -> [Double] {
        Self.hourStarts(at: now, hours: hours).map { h in
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
        let since = Self.hour(now) - (retainHours - 1) * 3600
        coverage = coverage.filter { $0.key >= since }
        for (key, var e) in entries {
            e.hours = e.hours.filter { $0.key >= since }
            e.peaks = e.peaks.filter { $0.key >= since }
            entries[key] = e.hours.isEmpty ? nil : e
        }
    }
}
