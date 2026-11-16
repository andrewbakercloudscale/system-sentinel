import Foundation

/// "Why is the Mac slow right now": the last few minutes of CPU, added up by family rather
/// than by process, beside what the CPU counters say the Mac really did.
///
/// The process list ranks one pid at a time, so it hides two kinds of load that make a Mac
/// feel slow: many small processes of one kind (40 runs of a status panel's helper, each a
/// few seconds at 120%), and work that is in no process row at all (the kernel, and
/// processes that start and exit between two samples). Families answer the first; the gap
/// between the CPU counters and the sum of every row answers the second.
public final class RecentLoad {
    public let window: TimeInterval

    private struct Reading {
        let at: Date
        let families: [String: (cpu: Double, pids: Set<Int32>, names: [String: Double])]
        /// Processes started since the reading before: the advance of the highest pid, which
        /// counts the ones that came and went between two samples too.
        let started: Int
        /// The new processes this sample caught, by the family of whoever started them.
        let startedBy: [String: Int]
    }
    private var readings: [Reading] = []
    private var known: Set<Int32> = []
    private var newestPid: Int32?
    /// macOS hands out pids up to this, then starts again from the bottom.
    static let pidMax: Int32 = 99_999
    private var ticks: [(at: Date, t: CoreLoad.Ticks)] = []

    public init(window: TimeInterval = 300) {
        self.window = window
    }

    /// One process sample, and the CPU counters summed over every core at the same moment.
    public func record(_ samples: [ProcessSample], ticks t: [CoreLoad.Ticks],
                       parent: (Int32) -> Int32? = ProcessDetail.parent, at now: Date) {
        var fam: [String: (cpu: Double, pids: Set<Int32>, names: [String: Double])] = [:]
        for s in samples where s.cpu > 0 {
            let k = LoadFamily.of(s).name
            var f = fam[k] ?? (0, [], [:])
            f.cpu += s.cpu
            f.pids.insert(s.pid)
            f.names[s.displayName, default: 0] += s.cpu
            fam[k] = f
        }
        // Started: pids are handed out in order, so the advance of the newest pid is how many
        // processes began, caught by a sample or not. Only new pids count: an old process
        // with a high pid (left from before the last wrap at 99999) would hide the advance.
        let fresh = known.isEmpty ? [] : samples.map(\.pid).filter { !known.contains($0) }
        var started = 0
        if let h = newestPid, !fresh.isEmpty {
            let after = fresh.filter { $0 > h }, wrapped = fresh.filter { $0 < h }
            if let n = wrapped.max() {
                started = Int(Self.pidMax - h) + Int(n)
                newestPid = n
            } else if let n = after.max() {
                started = Int(n - h)
                newestPid = n
            }
        } else if newestPid == nil {
            // The first new process sets where counting starts.
            newestPid = fresh.max()
        }
        var startedBy: [String: Int] = [:]
        if !known.isEmpty {
            let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            for s in samples where !known.contains(s.pid) {
                startedBy[Self.starter(of: s, byPid: byPid, parent: parent), default: 0] += 1
            }
        }
        known = Set(samples.map(\.pid))
        readings.append(Reading(at: now, families: fam, started: started, startedBy: startedBy))
        if !t.isEmpty {
            let sum = t.reduce(CoreLoad.Ticks(user: 0, system: 0, idle: 0, nice: 0)) {
                CoreLoad.Ticks(user: $0.user + $1.user, system: $0.system + $1.system, idle: $0.idle + $1.idle, nice: $0.nice + $1.nice)
            }
            ticks.append((now, sum))
        }
        let cutoff = now.addingTimeInterval(-window)
        if let i = readings.firstIndex(where: { $0.at >= cutoff }), i > 0 { readings.removeFirst(i) }
        // One counter reading older than the window is kept, as the start of the span.
        if let i = ticks.firstIndex(where: { $0.at >= cutoff }), i > 1 { ticks.removeFirst(i - 1) }
    }

    /// Shells and timers only pass work on; the family is whoever is above them.
    static let passThrough: Set<String> = ["bash", "zsh", "sh", "-zsh", "-bash", "login", "sleep", "env", "caffeinate", "xargs", "timeout"]

    /// The family of the program that started `s`: up through shells and launchd's children
    /// to the first program that is not a shell, or `s` itself.
    static func starter(of s: ProcessSample, byPid: [Int32: ProcessSample], parent: (Int32) -> Int32?) -> String {
        var cur = s
        for _ in 0..<8 {
            guard let pp = cur.ppid > 0 ? cur.ppid : parent(cur.pid), pp > 1, let up = byPid[pp] else { break }
            cur = up
            if !passThrough.contains(cur.name) { break }
        }
        return LoadFamily.of(cur).name
    }

    public struct Family: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        /// Mean CPU over the window, 100 = one core.
        public let cpu: Double
        /// Distinct processes seen; more than are running now when they come and go.
        public let processes: Int
        /// The busiest members, by name.
        public let examples: [String]
        public let note: String?
    }

    public struct Report: Equatable, Sendable {
        /// What the window covers, in seconds.
        public let span: TimeInterval
        /// Busy and kernel time from the CPU counters, 100 = one core. Nil without counters.
        public let busy: Double?
        public let system: Double?
        public let families: [Family]
        /// Busy time no process row accounts for: the kernel and short-lived processes.
        public let unseen: Double?
        public let capacity: Double
        /// Processes started over the span, and the biggest starters among those a sample caught.
        public let started: Int
        public let startedBy: [(family: String, count: Int)]

        public var startsPerSecond: Double { span > 0 ? Double(started) / span : 0 }

        public static func == (a: Report, b: Report) -> Bool {
            a.span == b.span && a.busy == b.busy && a.system == b.system && a.families == b.families
                && a.unseen == b.unseen && a.started == b.started && a.startedBy.map(\.family) == b.startedBy.map(\.family)
        }

        /// Share of the whole Mac in use, 0 to 1.
        public var busyShare: Double? { busy.map { capacity > 0 ? $0 / capacity : 0 } }
        public var systemShare: Double? { system.map { capacity > 0 ? $0 / capacity : 0 } }
    }

    public func report(cores: Int, at now: Date = Date()) -> Report {
        let capacity = Double(max(cores, 1)) * 100
        let n = Double(max(readings.count, 1))
        var cpu: [String: Double] = [:], pids: [String: Set<Int32>] = [:], names: [String: [String: Double]] = [:]
        for r in readings {
            for (k, f) in r.families {
                cpu[k, default: 0] += f.cpu
                pids[k, default: []].formUnion(f.pids)
                names[k, default: [:]].merge(f.names, uniquingKeysWith: +)
            }
        }
        let families = cpu.map { k, c in
            Family(name: k, cpu: c / n, processes: pids[k]?.count ?? 0,
                   examples: (names[k] ?? [:]).sorted { $0.value > $1.value }.prefix(3).map(\.key),
                   note: LoadFamily.note(k))
        }
        .filter { $0.cpu >= 1 }
        .sorted { $0.cpu > $1.cpu }
        let span = readings.first.map { now.timeIntervalSince($0.at) } ?? 0

        var busy: Double?, system: Double?
        if let a = ticks.first?.t, let b = ticks.last?.t, ticks.count > 1 {
            func d(_ p: UInt64, _ q: UInt64) -> Double { q >= p ? Double(q - p) : 0 }
            let u = d(a.user, b.user) + d(a.nice, b.nice), s = d(a.system, b.system)
            let total = u + s + d(a.idle, b.idle)
            if total > 0 {
                busy = (u + s) / total * capacity
                system = s / total * capacity
            }
        }
        let seen = cpu.values.reduce(0, +) / n
        let unseen = busy.map { max($0 - seen, 0) }
        var by: [String: Int] = [:]
        for r in readings.dropFirst() { by.merge(r.startedBy, uniquingKeysWith: +) }
        let started = readings.dropFirst().reduce(0) { $0 + $1.started }
        return Report(span: span, busy: busy, system: system, families: families, unseen: unseen, capacity: capacity,
                      started: started, startedBy: by.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) })
    }
}

/// Which family a process belongs to, for adding small processes up into one figure.
public enum LoadFamily {
    public static let claude = "Claude Code and its helpers"
    public static let updates = "Software updates and background downloads"
    public static let indexing = "Spotlight, Photos and Siri indexing"
    public static let apple = "iCloud and Apple background services"
    public static let screen = "Screen drawing (WindowServer)"
    public static let kernel = "kernel_task"
    public static let security = "Company security software"

    static let updateNames: Set<String> = ["softwareupdated", "softwareupdate", "mobileassetd", "nsurlsessiond", "installd",
                                           "system_installd", "storedownloadd", "UpdateBrainService", "SoftwareUpdateNotificationManager"]
    static let indexNames: Set<String> = ["mds", "mds_stores", "corespotlightd", "spotlightknowledged", "knowledgeconstructiond",
                                          "mediaanalysisd", "photoanalysisd", "suggestd", "siriknowledged"]
    static let appleNames: Set<String> = ["cloudd", "bird", "triald", "triald_system", "accountsd", "fileproviderd", "nsurlstoraged",
                                          "deleted", "apsd", "CommCenter"]

    public static func of(_ s: ProcessSample) -> (name: String, app: Bool) {
        let name = s.name, path = s.path
        if name == "WindowServer" { return (screen, false) }
        if name == "kernel_task" { return (kernel, false) }
        if Safety.isCompanyAgent(s) { return (security, false) }
        let lower = path.lowercased()
        if name == "claude" || name.hasPrefix("claude-") || lower.contains("ccusage") || lower.contains("/.claude/")
            || lower.contains("/claude/versions/") || lower.contains("claude-burst") {
            return (claude, false)
        }
        if updateNames.contains(name) || name.hasPrefix("com.apple.StreamingUnzipService") || name.hasPrefix("com.apple.MobileSoftwareUpdate") {
            return (updates, false)
        }
        if indexNames.contains(name) || name.hasPrefix("mdworker") { return (indexing, false) }
        if appleNames.contains(name) { return (apple, false) }
        return (AppIdentity.appName(of: path), true)
    }

    public static func note(_ family: String) -> String? {
        switch family {
        case claude: "Claude Code sessions plus the panels and hooks around them. Each ccusage run re-reads every transcript, a few seconds at full speed, so many open panels add up."
        case updates: "macOS or an app is downloading or unpacking an update. It stops once the download is done; installing the update ends it."
        case indexing: "Reading new and changed files and photos so search and Photos can find them. It settles once it catches up, sooner on power."
        case apple: "iCloud sync, Apple experiments and storage clean-up. Usually short bursts."
        case screen: "Draws every window. Busy with many windows, external displays, transparency or a page animating; closing windows and tabs helps."
        case kernel: "The kernel. Busy when the Mac is hot (it takes CPU away on purpose to cool down) or a driver or disk is working hard."
        case security: "Your company's security or device management software. Left alone; ask IT if it stays busy."
        default: nil
        }
    }
}
