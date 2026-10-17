import Foundation

/// Memory and swap, minute by minute, for the last 7 days, with the apps holding the most.
public final class MemoryHistory {
    public struct App: Codable, Equatable, Sendable {
        /// Grouping key (an app bundle or a program path) and its display name.
        public var key: String
        public var name: String
        public var bytes: UInt64

        public init(key: String, name: String, bytes: UInt64) {
            self.key = key
            self.name = name
            self.bytes = bytes
        }
    }

    public struct Point: Codable, Equatable, Sendable {
        /// Minute start, seconds since 1970.
        public var t: Int
        /// Bytes used (app, wired and compressed), averaged over the minute.
        public var used: UInt64
        public var compressed: UInt64
        /// Swap in use at the minute's last reading.
        public var swap: UInt64
        /// The worst pressure seen in the minute (`MemoryStatus.Pressure.rawValue`).
        public var pressure: Int
        /// Bytes a second read back from swap and written to it, averaged over the minute.
        public var swapIn: Double
        public var swapOut: Double
        /// The largest apps at the minute's last reading.
        public var apps: [App]
        public var n: Int

        public init(t: Int, used: UInt64, compressed: UInt64, swap: UInt64, pressure: Int,
                    swapIn: Double = 0, swapOut: Double = 0, apps: [App] = [], n: Int = 1) {
            self.t = t
            self.used = used
            self.compressed = compressed
            self.swap = swap
            self.pressure = pressure
            self.swapIn = swapIn
            self.swapOut = swapOut
            self.apps = apps
            self.n = n
        }

        public var date: Date { Date(timeIntervalSince1970: Double(t)) }
    }

    public private(set) var points: [Point] = []
    private let fileURL: URL?
    private let readOnly: Bool
    private let retain: TimeInterval
    private var lastSave: Date?
    private var lastCounters: (ins: UInt64, outs: UInt64, at: Date)?
    /// Apps kept per minute: enough for the top of the list and for spotting growth.
    public static let appsKept = 5

    public init(fileURL: URL?, retain: TimeInterval = 7 * 86_400, readOnly: Bool = false) {
        self.fileURL = fileURL
        self.retain = retain
        self.readOnly = readOnly
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode([Point].self, from: data) {
            points = p
        }
    }

    public func record(_ m: MemoryStatus, apps: [App], at now: Date) {
        // Swap traffic from the running counters; a gap (sleep) or a reset gives no rate.
        var swapIn = 0.0, swapOut = 0.0
        if let l = lastCounters, m.swapIns >= l.ins, m.swapOuts >= l.outs {
            let dt = now.timeIntervalSince(l.at)
            if dt >= 1, dt <= 120 {
                swapIn = Double(m.swapIns - l.ins) / dt
                swapOut = Double(m.swapOuts - l.outs) / dt
            }
        }
        lastCounters = (m.swapIns, m.swapOuts, now)
        let top = Array(apps.sorted { $0.bytes > $1.bytes }.prefix(Self.appsKept))

        let minute = Int(now.timeIntervalSince1970) / 60 * 60
        if var last = points.last, last.t == minute {
            let n = Double(last.n)
            last.used = UInt64((Double(last.used) * n + Double(m.used)) / (n + 1))
            last.compressed = UInt64((Double(last.compressed) * n + Double(m.compressed)) / (n + 1))
            last.swapIn = (last.swapIn * n + swapIn) / (n + 1)
            last.swapOut = (last.swapOut * n + swapOut) / (n + 1)
            last.swap = m.swapUsed
            last.pressure = max(last.pressure, m.pressure.rawValue)
            last.apps = top
            last.n += 1
            points[points.count - 1] = last
        } else {
            points.append(Point(t: minute, used: m.used, compressed: m.compressed, swap: m.swapUsed,
                                pressure: m.pressure.rawValue, swapIn: swapIn, swapOut: swapOut, apps: top))
            let cutoff = minute - Int(retain)
            if let i = points.firstIndex(where: { $0.t >= cutoff }), i > 0 { points.removeFirst(i) }
        }
        if lastSave.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
            save()
            lastSave = now
        }
    }

    public func since(_ date: Date) -> [Point] {
        let t = Int(date.timeIntervalSince1970)
        return points.filter { $0.t >= t }
    }

    public func save() {
        guard !readOnly, let url = fileURL, let data = try? JSONEncoder().encode(points) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// What the memory timeline says: swap growth, thrashing, idle swap, time under pressure and
/// apps that keep growing. Pure, so it is tested with made-up timelines.
public enum MemoryAnalysis {
    /// Below this, swap is noise: macOS keeps a little there even on an idle Mac.
    public static let swapNoise: UInt64 = 512 << 20
    /// Reading back from swap this fast, for minutes on end, is what a slow Mac feels like.
    public static let thrashRate: Double = 4 * 1_048_576

    public struct Summary: Equatable, Sendable {
        public var peakSwap: UInt64
        public var peakSwapAt: Date?
        public var peakUsed: UInt64
        /// Minutes under warning and critical pressure.
        public var warningMinutes: Int
        public var criticalMinutes: Int
        /// When the current stretch of swap began; nil when there is none, or it is older than the records.
        public var swapSince: Date?
        /// Swap was already in use at the first record.
        public var swapBeforeRecords: Bool
        public var minutes: Int
    }

    public static func summary(_ points: [MemoryHistory.Point]) -> Summary {
        let peak = points.max { $0.swap < $1.swap }
        var since: Date?
        var before = false
        if let last = points.last, last.swap >= swapNoise {
            if let i = points.lastIndex(where: { $0.swap < swapNoise }) {
                since = points.indices.contains(i + 1) ? points[i + 1].date : nil
            } else {
                before = true
            }
        }
        return Summary(peakSwap: peak?.swap ?? 0, peakSwapAt: peak.flatMap { $0.swap > 0 ? $0.date : nil },
                       peakUsed: points.map(\.used).max() ?? 0,
                       warningMinutes: points.filter { $0.pressure == MemoryStatus.Pressure.warning.rawValue }.count,
                       criticalMinutes: points.filter { $0.pressure >= MemoryStatus.Pressure.critical.rawValue }.count,
                       swapSince: since, swapBeforeRecords: before, minutes: points.count)
    }

    /// Swap at about `date`: the last reading at or before it, if no more than 10 minutes older.
    public static func swap(at date: Date, in points: [MemoryHistory.Point]) -> UInt64? {
        let t = Int(date.timeIntervalSince1970)
        guard let p = points.last(where: { $0.t <= t }), t - p.t <= 600 else { return nil }
        return p.swap
    }

    /// An app whose memory has climbed steadily: possibly a leak, possibly tabs piling up.
    public struct Growth: Equatable, Sendable {
        public var key: String
        public var name: String
        public var from: UInt64
        public var to: UInt64
        public var over: TimeInterval
    }

    /// Apps that grew by at least `minGrowth` and half again over the window, and are still
    /// near their high (a peak that has come back down is not a climb).
    public static func growing(_ points: [MemoryHistory.Point], window: TimeInterval = 3 * 3600, at now: Date,
                               minGrowth: UInt64 = 1 << 30) -> [Growth] {
        let start = Int(now.timeIntervalSince1970 - window)
        let recent = points.filter { $0.t >= start }
        var series: [String: [(t: Int, bytes: UInt64, name: String)]] = [:]
        for p in recent {
            for a in p.apps { series[a.key, default: []].append((p.t, a.bytes, a.name)) }
        }
        var out: [Growth] = []
        for (key, s) in series where s.count >= 20 {
            let span = s[s.count - 1].t - s[0].t
            guard span >= 1800 else { continue }
            // Averages of the first and last tenth, so one spike does not count as growth.
            let k = max(s.count / 10, 2)
            let first = s.prefix(k).reduce(0.0) { $0 + Double($1.bytes) } / Double(k)
            let last = s.suffix(k).reduce(0.0) { $0 + Double($1.bytes) } / Double(k)
            let peak = Double(s.map(\.bytes).max() ?? 0)
            guard last - first >= Double(minGrowth), last >= first * 1.5, last >= peak * 0.85 else { continue }
            out.append(Growth(key: key, name: s[s.count - 1].name, from: UInt64(first), to: UInt64(last), over: Double(span)))
        }
        return out.sorted { $0.to - $0.from > $1.to - $1.from }
    }

    /// Average swap traffic over the last `seconds`, in bytes a second, from minutes with readings.
    public static func traffic(_ points: [MemoryHistory.Point], seconds: TimeInterval, at now: Date) -> (into: Double, outOf: Double, minutes: Int) {
        let start = Int(now.timeIntervalSince1970 - seconds)
        let recent = points.filter { $0.t >= start }
        guard !recent.isEmpty else { return (0, 0, 0) }
        let n = Double(recent.count)
        return (recent.reduce(0) { $0 + $1.swapOut } / n, recent.reduce(0) { $0 + $1.swapIn } / n, recent.count)
    }

    /// The app most often at the top while memory was under pressure.
    public static func usualSuspect(_ points: [MemoryHistory.Point]) -> String? {
        var count: [String: Int] = [:]
        for p in points where p.pressure >= MemoryStatus.Pressure.warning.rawValue {
            if let a = p.apps.first { count[a.name, default: 0] += 1 }
        }
        return count.max { $0.value < $1.value }?.key
    }

    public static func insights(points: [MemoryHistory.Point], current m: MemoryStatus, uptime: TimeInterval?,
                                at now: Date) -> [Insight] {
        var out: [Insight] = []
        let gb = ReportDocument.bytes
        let mbs: (Double) -> String = { String(format: "%.1f MB/s", $0 / 1_048_576) }

        // Thrashing: memory read back from disk minute after minute.
        let last10 = traffic(points, seconds: 600, at: now)
        if last10.minutes >= 5, last10.outOf >= thrashRate {
            var x = Insight(id: "mem-thrash", tone: .critical, symbol: "arrow.triangle.2.circlepath",
                            title: "Swapping hard: \(mbs(last10.outOf)) back from disk",
                            detail: "For the last \(last10.minutes) minutes macOS has been reading memory back from the swap file as fast as it writes it out. This is what makes a Mac stutter.")
            x.why = "Swap only hurts when it is in use. Memory written to disk and left there costs nothing; memory that apps keep needing back has to be read from the SSD, which is hundreds of times slower than RAM. When that happens continuously (thrashing), every app waits."
            x.steps = ["Quit the largest app you are not using right now (see Largest apps on this tab).",
                       "Close browser tabs and windows you do not need.",
                       "If it keeps happening, this Mac needs more memory than it has for what you run at once."]
            out.append(x)
        }

        // Swap growing fast.
        let hourAgo = swap(at: now.addingTimeInterval(-3600), in: points)
        if let before = hourAgo, m.swapUsed > before, m.swapUsed - before >= 1 << 30 {
            let grew = m.swapUsed - before
            var x = Insight(id: "mem-swapgrow", tone: .warning, symbol: "chart.line.uptrend.xyaxis",
                            title: "Swap grew \(gb(grew)) in the last hour",
                            detail: "From \(gb(before)) to \(gb(m.swapUsed)). Apps are asking for more memory than the Mac has free.")
            if let top = points.last?.apps.first { x.detail += " Largest now: \(top.name) at \(gb(top.bytes))." }
            x.why = "macOS moves memory to the swap file when apps need more than is free. Steady growth means something keeps asking for more: often a browser with many tabs, a virtual machine, or an app with a memory leak."
            x.steps = ["Check Largest apps and Growing apps on this tab.", "Quit or restart whatever is climbing."]
            out.append(x)
        }

        // Apps climbing steadily.
        for g in growing(points, at: now).prefix(2) {
            var x = Insight(id: "mem-grow-\(g.key)", tone: .warning, symbol: "arrow.up.forward.app.fill",
                            title: "\(g.name) grew from \(gb(g.from)) to \(gb(g.to))",
                            detail: "A steady climb over \(Insights.duration(g.over)), still near its high.")
            x.why = "An app that keeps growing without coming back down is either collecting work (tabs, documents, cached data) or leaking memory: holding on to memory it no longer uses. Quitting and reopening it gives all of it back."
            x.steps = ["Save your work in \(g.name), then quit and reopen it.",
                       "If it climbs again every day, check for an update: leaks are bugs and get fixed."]
            out.append(x)
        }

        // Pressure over the last day.
        let day = points.filter { $0.t >= Int(now.timeIntervalSince1970) - 86_400 }
        let sDay = summary(day)
        let pressured = sDay.warningMinutes + sDay.criticalMinutes
        if pressured >= 30 {
            var x = Insight(id: "mem-pressure24", tone: sDay.criticalMinutes >= 30 ? .critical : .warning, symbol: "gauge.with.dots.needle.67percent",
                            title: "Short of memory for \(Insights.duration(Double(pressured) * 60)) in the last day",
                            detail: "Memory pressure was raised for \(pressured) of \(day.count) minutes recorded.")
            if let who = usualSuspect(day) { x.detail += " \(who) was the largest app most of that time." }
            x.why = "Memory pressure is macOS's own judgement of whether apps are getting the memory they ask for. Raised pressure means it is compressing and swapping to keep up."
            x.steps = ["Keep fewer large apps open at once, starting with the one named above.",
                       "Browsers: fewer tabs, or a tab-suspending extension."]
            out.append(x)
        }

        // Swap left over: big, but idle.
        let last30 = traffic(points, seconds: 1800, at: now)
        if m.swapUsed >= 1 << 30, m.pressure == .normal, last30.minutes >= 10, last30.outOf < 512 * 1024, out.isEmpty {
            var x = Insight(id: "mem-swapidle", tone: .info, symbol: "externaldrive.fill",
                            title: "\(gb(m.swapUsed)) in swap, but it is idle",
                            detail: "Memory pressure is normal and nothing has been read back from swap in the last 30 minutes. It takes disk space, not speed.")
            x.why = "Earlier, apps needed more memory than was free, so macOS moved idle memory to the swap file. Nothing needs it back, so it simply sits there. macOS does not shrink swap while the Mac runs; it empties on restart."
            if let up = uptime, up >= 3 * 86_400 {
                x.detail += " The Mac has been up \(Int(up / 86_400)) days."
                x.steps = ["Nothing urgent. Restart when convenient to clear it."]
            }
            out.append(x)
        } else if m.swapUsed >= 3 << 30, let up = uptime, up >= 3 * 86_400 {
            var x = Insight(id: "mem-uptime", tone: .info, symbol: "restart.circle.fill",
                            title: "Up \(Int(up / 86_400)) days with \(gb(m.swapUsed)) in swap",
                            detail: "Swap only empties when the Mac restarts.")
            x.steps = ["Restart when convenient: it clears swap and memory that apps have leaked."]
            out.append(x)
        }

        if out.isEmpty, m.pressure == .normal, m.swapUsed < swapNoise {
            let headroom = m.total > m.used ? m.total - m.used : 0
            out.append(Insight(id: "mem-ok", tone: .good, symbol: "checkmark.seal.fill",
                               title: "Memory is healthy",
                               detail: "Pressure is normal, \(gb(headroom)) is available and swap is barely used."))
        }
        return out
    }
}
