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
        /// What each starter is: the script's path, the shell's command, or the program's path.
        let detail: [String: String]
    }
    private var readings: [Reading] = []
    private var known: Set<Int32> = []
    /// Each shell's command line, read once per shell (shells live long; their children don't).
    private var shellArgs: [Int32: [String]] = [:]
    private var newestPid: Int32?
    /// macOS hands out pids up to this, then starts again from the bottom.
    static let pidMax: Int32 = 99_999
    private var ticks: [(at: Date, t: CoreLoad.Ticks)] = []

    public init(window: TimeInterval = 300) {
        self.window = window
    }

    /// One process sample, and the CPU counters summed over every core at the same moment.
    public func record(_ samples: [ProcessSample], ticks t: [CoreLoad.Ticks],
                       parent: (Int32) -> Int32? = ProcessDetail.parent,
                       arguments: (Int32) -> [String] = RecentLoad.commandLine, at now: Date) {
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
            // A real wrap only happens near the top, to a low pid. Anything else below the newest
            // (a process ps missed last time) would otherwise count as ~100 000 starts.
            if h > Self.pidMax - 20_000, let n = wrapped.filter({ $0 < 20_000 }).max() {
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
        var startedBy: [String: Int] = [:], detail: [String: String] = [:]
        if !known.isEmpty {
            let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            for s in samples where !known.contains(s.pid) {
                let who = starter(of: s, byPid: byPid, parent: parent, arguments: arguments)
                startedBy[who.name, default: 0] += 1
                if !who.detail.isEmpty { detail[who.name] = who.detail }
            }
        }
        known = Set(samples.map(\.pid))
        shellArgs = shellArgs.filter { known.contains($0.key) }
        readings.append(Reading(at: now, families: fam, started: started, startedBy: startedBy, detail: detail))
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

    static let shells: Set<String> = ["bash", "zsh", "sh", "-zsh", "-bash", "dash", "fish"]

    /// The script a shell runs, from its command line: "bash /path/ccusage-panel.sh 10" is
    /// ccusage-panel.sh. Nil for an interactive shell or one running a -c command string.
    public static func script(_ args: [String]) -> String? {
        for a in args.dropFirst() {
            if a == "-c" { return nil }
            if a.hasPrefix("-") { continue }
            let name = (a as NSString).lastPathComponent
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// The command after a shell's -c, cut short: "sleep 1; ccusage …".
    public static func command(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "-c"), i + 1 < args.count else { return nil }
        let c = args[(i + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? nil : (c.count > 80 ? String(c.prefix(80)) + "…" : c)
    }

    /// A process's arguments. The kernel will not give another user's (root's) to an app, so
    /// for those ask ps, which may; split on spaces, which is good enough for a script path.
    public static func commandLine(_ pid: Int32) -> [String] {
        let a = ProcessDetail.arguments(pid)
        if !a.isEmpty { return a }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-ww", "-o", "args=", "-p", String(pid)]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Who started `s`: up through shells and timers to the first real program, or the
    /// script a shell on the way runs, since a looping script is what someone can stop.
    /// The detail says what exactly: the script's path, the shell's command, the program.
    func starter(of s: ProcessSample, byPid: [Int32: ProcessSample], parent: (Int32) -> Int32?,
                 arguments: (Int32) -> [String]) -> (name: String, detail: String) {
        var cur = s
        var command: String?
        for _ in 0..<8 {
            guard let pp = cur.ppid > 0 ? cur.ppid : parent(cur.pid), pp > 1, let up = byPid[pp] else { break }
            cur = up
            if Self.shells.contains(cur.name) {
                if shellArgs[cur.pid] == nil { shellArgs[cur.pid] = arguments(cur.pid) }
                let args = shellArgs[cur.pid] ?? []
                if let name = Self.script(args) {
                    let path = args.dropFirst().first { !$0.hasPrefix("-") } ?? name
                    return (name, path)
                }
                if command == nil, let c = Self.command(args) { command = "\(cur.name) -c \(c)" }
            }
            if !Self.passThrough.contains(cur.name) { break }
        }
        if Self.passThrough.contains(cur.name), let command {
            // Nothing named above the shell (launchd started it): the command is the best name.
            return (command, command)
        }
        return (LoadFamily.of(cur).name, command ?? cur.path)
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
        public let startedBy: [Starter]

        /// One starter among the new processes the samples caught.
        public struct Starter: Equatable, Sendable, Identifiable {
            public var id: String { name }
            public let name: String
            /// Of the new processes the samples caught, how many this one started.
            public let caught: Int
            /// The script's path, the shell's command, or the program's path.
            public let detail: String
            /// Its share of the caught starts, 0 to 1.
            public let share: Double
        }

        public var startsPerSecond: Double { span > 0 ? Double(started) / span : 0 }

        public enum Level: Int, Comparable, Sendable {
            case normal, someWhatSlow, slow
            public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        }

        /// How slow it will feel: the worst of how busy the CPUs are, how much of that is the
        /// kernel, and how fast processes are starting.
        public var level: Level {
            let busy = busyShare ?? 0, sys = systemShare ?? 0, starts = startsPerSecond
            if busy >= 0.6 || sys >= 0.2 || starts >= 100 { return .slow }
            if busy >= 0.3 || sys >= 0.1 || starts >= 30 { return .someWhatSlow }
            return .normal
        }

        public static func == (a: Report, b: Report) -> Bool {
            a.span == b.span && a.busy == b.busy && a.system == b.system && a.families == b.families
                && a.unseen == b.unseen && a.started == b.started && a.startedBy == b.startedBy
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
        var by: [String: Int] = [:], detail: [String: String] = [:]
        for r in readings.dropFirst() {
            by.merge(r.startedBy, uniquingKeysWith: +)
            detail.merge(r.detail) { _, new in new }
        }
        let caught = Double(max(by.values.reduce(0, +), 1))
        let started = readings.dropFirst().reduce(0) { $0 + $1.started }
        let top = by.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5)
            .map { Report.Starter(name: $0.key, caught: $0.value, detail: detail[$0.key] ?? "", share: Double($0.value) / caught) }
        return Report(span: span, busy: busy, system: system, families: families, unseen: unseen, capacity: capacity,
                      started: started, startedBy: top)
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

/// Swapping over the same few minutes: memory written out to disk and read back. Each page
/// read back stalls whatever needed it, so a busy swap makes the whole Mac stutter even when
/// the CPU is not full.
public struct SwapActivity: Equatable, Sendable {
    /// Swap traffic in and out, bytes a second, averaged over the minutes.
    public let rate: Double
    /// Highest memory pressure seen: 0 normal, 1 warning, 2 critical.
    public let pressure: Int

    public init(rate: Double, pressure: Int) {
        self.rate = rate
        self.pressure = pressure
    }

    /// From the memory timeline's minutes since `since` (the CPU window's start).
    public static func of(_ points: [MemoryHistory.Point]) -> SwapActivity? {
        guard !points.isEmpty else { return nil }
        let rate = points.reduce(0) { $0 + $1.swapIn + $1.swapOut } / Double(points.count)
        return SwapActivity(rate: rate, pressure: points.map(\.pressure).max() ?? 0)
    }

    /// 20 MB/s of swap is several thousand stalls a second; 5 MB/s is felt as hitches.
    public var level: RecentLoad.Report.Level {
        if rate >= 20_000_000 || pressure >= 2 { return .slow }
        if rate >= 5_000_000 || pressure >= 1 { return .someWhatSlow }
        return .normal
    }
}
