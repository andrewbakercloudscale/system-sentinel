import Foundation

// MARK: Fix-it actions

/// Something an insight can do for you in one click, rather than describe.
public enum FixAction: Equatable, Sendable, Identifiable {
    /// Quit the app properly (it can save), or stop the process if it is not an app.
    case quit(pids: [Int32], name: String)
    /// Stop these processes, e.g. every forgotten caffeinate.
    case kill(pids: [Int32], label: String)
    /// Turn Low Power Mode on (asks for the admin password).
    case lowPowerMode
    case openSettings(Settings)
    case reveal(path: String)
    /// Storage: empty the Trash (asks first).
    case emptyTrash
    /// Storage: clean these rebuildable places (`StoragePlace` keys), asking first.
    case cleanPlaces(keys: [String])
    /// Storage: move what a scan found to the Trash, asking first.
    case trashFound(StorageAnalysis.Kind, count: Int)
    /// Storage: move what a scan found to a folder you pick, such as an external drive.
    case archiveFound(StorageAnalysis.Kind, count: Int)
    /// Scroll to a card on the current tab and pick its view.
    case review(card: String, label: String)
    case openApp(bundleID: String, name: String)
    case openURL(String, label: String)
    /// Turn Wi-Fi off and on, so macOS rejoins its best known network instead of a phone.
    case leaveHotspot
    /// Opens the WindowServer optimiser: settings that make the screen cheaper to draw, each with an undo.
    case optimiseScreen
    /// Switch to another tab (by its title) and scroll to a card on it.
    case goTo(tab: String, card: String?, label: String)

    public enum Settings: String, Sendable {
        case battery, displays, accessibilityDisplay, screenRecording, timeMachine, loginItems, wifi, network

        public var url: String {
            let base = "x-apple.systempreferences:"
            switch self {
            case .battery: return base + "com.apple.Battery-Settings.extension"
            case .displays: return base + "com.apple.Displays-Settings.extension"
            case .accessibilityDisplay: return base + "com.apple.Accessibility-Settings.extension?Display"
            case .screenRecording: return base + "com.apple.preference.security?Privacy_ScreenCapture"
            case .timeMachine: return base + "com.apple.Time-Machine-Settings.extension"
            case .loginItems: return base + "com.apple.LoginItems-Settings.extension"
            case .wifi: return base + "com.apple.wifi-settings-extension"
            case .network: return base + "com.apple.Network-Settings.extension"
            }
        }

        public var title: String {
            switch self {
            case .battery: return "Battery settings"
            case .displays: return "Display settings"
            case .accessibilityDisplay: return "Reduce transparency"
            case .screenRecording: return "Screen recording access"
            case .timeMachine: return "Time Machine settings"
            case .loginItems: return "Login Items"
            case .wifi: return "Wi-Fi settings"
            case .network: return "Network settings"
            }
        }
    }

    public var title: String {
        switch self {
        case .quit(_, let name): return "Quit \(name)"
        case .kill(_, let label): return label
        case .lowPowerMode: return "Turn on Low Power Mode"
        case .openSettings(let s): return s.title
        case .reveal: return "Show in Finder"
        case .emptyTrash: return "Empty Trash"
        case .cleanPlaces(let keys):
            return keys.count == 1 ? "Clean \(StoragePlace.named(keys[0])?.name ?? keys[0])" : "Clean all \(keys.count)"
        case .trashFound(_, let n): return n == 1 ? "Move it to the Trash" : "Move all \(n) to the Trash"
        case .archiveFound: return "Move to a drive…"
        case .review(_, let label): return label
        case .openApp(_, let name): return "Open \(name)"
        case .openURL(_, let label): return label
        case .leaveHotspot: return "Leave the hotspot"
        case .optimiseScreen: return "Optimise the screen…"
        case .goTo(_, _, let label): return label
        }
    }

    public var symbol: String {
        switch self {
        case .quit: return "xmark.circle.fill"
        case .kill: return "xmark.octagon.fill"
        case .lowPowerMode: return "leaf.fill"
        case .openSettings: return "gearshape.fill"
        case .reveal: return "folder.fill"
        case .emptyTrash: return "trash.slash.fill"
        case .cleanPlaces: return "sparkles"
        case .trashFound: return "trash.fill"
        case .archiveFound: return "externaldrive.fill"
        case .review: return "list.bullet"
        case .openApp: return "arrow.up.forward.app.fill"
        case .openURL: return "safari.fill"
        case .leaveHotspot: return "wifi.exclamationmark"
        case .optimiseScreen: return "wand.and.stars"
        case .goTo: return "arrow.right.circle.fill"
        }
    }

    /// Changes something (red button) rather than only opening a window.
    public var acts: Bool {
        switch self {
        case .quit, .kill, .lowPowerMode, .emptyTrash, .cleanPlaces, .trashFound, .leaveHotspot: return true
        case .openSettings, .reveal, .archiveFound, .review, .openApp, .openURL, .optimiseScreen, .goTo: return false
        }
    }

    public var id: String { title }
}

// MARK: Battery health over time

/// One battery reading a day, kept for years, so wear shows as a trend.
public final class HealthLog {
    public struct Entry: Codable, Equatable, Sendable {
        /// Day start, seconds since 1970.
        public var day: Int
        public var maxCapacity: Int
        public var designCapacity: Int
        public var cycles: Int
        public var health: Double { designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0 }
    }

    public private(set) var entries: [Entry] = []
    private let fileURL: URL?
    private let readOnly: Bool

    public init(fileURL: URL?, readOnly: Bool = false) {
        self.fileURL = fileURL
        self.readOnly = readOnly
        if let url = fileURL, let data = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = e
        }
    }

    /// Records today's reading, replacing an earlier one from the same day.
    public func record(_ b: BatteryStatus, at now: Date, calendar: Calendar = .current) {
        guard let m = b.maxCapacity, let d = b.designCapacity, d > 0 else { return }
        let day = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        let e = Entry(day: day, maxCapacity: m, designCapacity: d, cycles: b.cycleCount ?? 0)
        if entries.last?.day == day {
            guard entries[entries.count - 1] != e else { return }
            entries[entries.count - 1] = e
        } else {
            entries.append(e)
        }
        save()
    }

    func save() {
        guard !readOnly, let url = fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        Diagnostics.write(data, to: url, what: url.lastPathComponent)
    }

    /// When health is expected to cross `threshold` percent, from a straight line through
    /// the readings. nil with under two weeks of readings, or if it is not falling.
    public static func projection(_ entries: [Entry], threshold: Double = 80) -> Date? {
        guard let first = entries.first, let last = entries.last, last.day - first.day >= 14 * 86_400 else { return nil }
        let xs = entries.map { Double($0.day - first.day) / 86_400 }
        let ys = entries.map(\.health)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        guard slope < 0 else { return nil }
        let intercept = my - slope * mx
        let days = (threshold - intercept) / slope
        return Date(timeIntervalSince1970: Double(first.day) + days * 86_400)
    }

    /// Charge cycles per week over the readings of the last `days` days.
    public static func cyclesPerWeek(_ entries: [Entry], at now: Date, days: Int = 30) -> Double? {
        let since = Int(now.timeIntervalSince1970) - days * 86_400
        let recent = entries.filter { $0.day >= since }
        guard let a = recent.first, let b = recent.last, b.day - a.day >= 7 * 86_400 else { return nil }
        return Double(b.cycles - a.cycles) / (Double(b.day - a.day) / (7 * 86_400))
    }
}

/// How the Mac is charged: long stretches at 100% on the charger age a battery fastest.
public struct ChargeHabits: Equatable, Sendable {
    public let pluggedMinutes: Int
    /// Minutes plugged in and at 99% or more.
    public let fullMinutes: Int
    public let batteryMinutes: Int
    public var fullShare: Double { pluggedMinutes > 0 ? Double(fullMinutes) / Double(pluggedMinutes) : 0 }

    public static func from(_ points: [PowerHistory.Point]) -> ChargeHabits {
        let plugged = points.filter { !$0.onBattery }
        return ChargeHabits(pluggedMinutes: plugged.count, fullMinutes: plugged.filter { $0.percent >= 99 }.count,
                            batteryMinutes: points.count - plugged.count)
    }

    /// Worth a tip: mostly plugged in, and mostly full while plugged in.
    public var sitsAtFull: Bool { pluggedMinutes >= 600 && fullShare >= 0.6 }
}

// MARK: Unusual for this app

/// An app working far harder than it usually does.
public struct UnusualApp: Equatable, Sendable {
    public let key: String
    public let name: String
    /// Last 15 minutes, percent of one core.
    public let now: Double
    /// Its usual hourly average over the last week.
    public let usual: Double
    public let pids: [Int32]
    public var ratio: Double { now / max(usual, 1) }
}

extension DailyUsage {
    /// Each app's usual CPU: its mean over every hour with at least ten minutes sampled,
    /// leaving out the current and previous hour. Needs six such hours.
    public func typicalByGroup(at now: Date, hours: Int = 24 * 7, group: (String) -> String) -> [String: Double] {
        let all = starts(at: now, count: hours).dropLast(2)
        let used = all.filter { (coverage[$0] ?? 0) >= 600 }
        guard used.count >= 6 else { return [:] }
        var sums: [String: Double] = [:]
        for (key, e) in entries {
            let g = group(key)
            for h in used { if let cs = e.hours[h] { sums[g, default: 0] += cs / (coverage[h] ?? 1) * 100 } }
        }
        return sums.mapValues { $0 / Double(used.count) }
    }
}

public enum Unusual {
    /// Apps at least `ratio` times their usual and using at least `minimum` percent now.
    /// An app with no history is not unusual, only new.
    public static func find(current: [String: (name: String, cpu: Double, pids: [Int32])], typical: [String: Double],
                            minimum: Double = 30, ratio: Double = 4) -> [UnusualApp] {
        guard !typical.isEmpty else { return [] }
        return current.compactMap { key, c -> UnusualApp? in
            guard c.cpu >= minimum, let usual = typical[key] else { return nil }
            let u = UnusualApp(key: key, name: c.name, now: c.cpu, usual: usual, pids: c.pids)
            return u.ratio >= ratio ? u : nil
        }
        .sorted { $0.ratio > $1.ratio }
    }
}

// MARK: Before and after

/// What a kill or quit changed, measured a minute later.
public struct Impact: Equatable, Sendable {
    public let name: String
    public let at: Date
    public let wattsBefore: Double?
    public let wattsAfter: Double?
    public let cpuBefore: Double
    public let cpuAfter: Double
    /// Extra battery time at the new draw, in minutes, when on battery.
    public let minutesGained: Double?

    public init(name: String, at: Date, wattsBefore: Double?, wattsAfter: Double?, cpuBefore: Double, cpuAfter: Double, energyLeft: Double?) {
        self.name = name
        self.at = at
        self.wattsBefore = wattsBefore
        self.wattsAfter = wattsAfter
        self.cpuBefore = cpuBefore
        self.cpuAfter = cpuAfter
        if let e = energyLeft, let b = wattsBefore, let a = wattsAfter, b > a, a > 0.5 {
            minutesGained = (e / a - e / b) * 60
        } else {
            minutesGained = nil
        }
    }

    /// Made a real difference: at least 1 W or a quarter of a core less.
    public var helped: Bool {
        if let b = wattsBefore, let a = wattsAfter, b - a >= 1 { return true }
        return cpuBefore - cpuAfter >= 25
    }

    public var summary: String {
        var parts: [String] = []
        if let b = wattsBefore, let a = wattsAfter { parts.append(String(format: "power %.1f W → %.1f W", b, a)) }
        parts.append("CPU \(Insights.fmtCores(cpuBefore)) → \(Insights.fmtCores(cpuAfter))")
        var s = parts.joined(separator: ", ")
        if let m = minutesGained, m >= 5 { s += ", about \(Insights.duration(m * 60)) more battery" }
        return s
    }
}

// MARK: Displays

public struct DisplayInfo: Equatable, Sendable {
    public let name: String
    public let builtIn: Bool
    public let width: Int
    public let height: Int
    public let refresh: Int
    /// 0 to 1, built-in display only.
    public let brightness: Double?

    public init(name: String, builtIn: Bool, width: Int, height: Int, refresh: Int, brightness: Double?) {
        self.name = name
        self.builtIn = builtIn
        self.width = width
        self.height = height
        self.refresh = refresh
        self.brightness = brightness
    }
}

public enum DisplayAdvice {
    public static func tips(_ displays: [DisplayInfo], gpu: Double?, onBattery: Bool) -> [String] {
        var out: [String] = []
        if let b = displays.first(where: \.builtIn)?.brightness, b >= 0.75 {
            out.append("The screen is at \(Int(b * 100))% brightness. It is often the biggest single draw: about 50% saves 1 to 2 W\(onBattery ? ", an hour or more of battery" : "").")
        }
        let external = displays.filter { !$0.builtIn }
        if !external.isEmpty {
            out.append("\(external.count) external \(external.count == 1 ? "display" : "displays") connected: the graphics chip drives every pixel\(onBattery ? ", and on battery that adds up" : "").")
        }
        if external.contains(where: { $0.refresh > 60 }) {
            out.append("An external display runs above 60 Hz. Unless you need it for games or video, 60 Hz halves the redraw work.")
        }
        if let g = gpu, g >= 50 {
            out.append("The graphics chip is \(Int(g))% busy: video, games, 3D or many animated windows.")
        }
        return out
    }
}

// MARK: Chrome tabs

public enum TabWeight {
    /// How likely a tab is to cost energy, from its address: 3 video or calls, 2 live apps,
    /// 1 everything else. With the reason, for the list.
    public static func of(url: String) -> (score: Int, reason: String?) {
        let host = (URL(string: url)?.host ?? url).lowercased()
        func any(_ list: [String]) -> Bool { list.contains { host == $0 || host.hasSuffix("." + $0) } }
        if any(["youtube.com", "netflix.com", "twitch.tv", "vimeo.com", "primevideo.com", "disneyplus.com", "tv.apple.com", "hulu.com", "spotify.com", "soundcloud.com"]) {
            return (3, "video or audio")
        }
        if any(["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "whereby.com", "webex.com", "discord.com"]) {
            return (3, "video call")
        }
        if any(["figma.com", "miro.com", "canva.com", "chatgpt.com", "claude.ai", "gemini.google.com", "grafana.net", "datadoghq.com", "app.datadoghq.eu", "newrelic.com", "tradingview.com"]) {
            return (2, "live app")
        }
        if any(["mail.google.com", "outlook.office.com", "outlook.live.com", "slack.com", "app.slack.com", "web.whatsapp.com", "x.com", "twitter.com", "facebook.com", "instagram.com", "linkedin.com"]) {
            return (2, "keeps refreshing")
        }
        return (1, nil)
    }
}

// MARK: Sleep blocker alerts

extension SleepBlockers {
    /// Blockers held for longer than `threshold` that have not been reported yet, keyed so
    /// one assertion is reported once.
    public static func overdue(_ blockers: [SleepBlocker], reported: Set<String>, threshold: TimeInterval, at now: Date) -> [SleepBlocker] {
        blockers.filter { b in
            guard let s = b.since, now.timeIntervalSince(s) >= threshold else { return false }
            return !reported.contains(reportKey(b))
        }
    }

    public static func reportKey(_ b: SleepBlocker) -> String {
        "\(b.pid)-\(b.kind.rawValue)-\(Int(b.since?.timeIntervalSince1970 ?? 0))"
    }
}

// MARK: Report export

/// The weekly report as sections of lines, rendered to Markdown or PDF.
public struct ReportDocument: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public let heading: String
        public let lines: [String]
    }

    public let title: String
    public let subtitle: String
    public let sections: [Section]

    public static func build(machine: String, weekly: WeeklyReport, today: [String], battery: BatteryStatus?,
                             projection: Date?, sleep: SleepReport?, memory: MemoryStatus?, at now: Date) -> ReportDocument {
        var s: [Section] = []
        var week = [String(format: "%.1f core-hours of CPU over %.0f hours watched.", weekly.coreHours, weekly.hoursWatched)]
        if let d = weekly.busiestDay {
            week.append(String(format: "Busiest day: %@ (%.1f core-hours).", d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)), weekly.busiestDayCoreHours))
        }
        if weekly.batteryHours > 0 { week.append(String(format: "%.1f hours on battery.", weekly.batteryHours)) }
        if let w = weekly.averageWatts { week.append(String(format: "Average power draw %.1f W.", w)) }
        week.append("\(weekly.flagged) processes flagged, \(weekly.killed) killed.")
        s.append(Section(heading: "The week", lines: week))
        if !weekly.apps.isEmpty {
            s.append(Section(heading: "Heaviest apps", lines: weekly.apps.enumerated().map {
                String(format: "%d. %@: %.1f core-hours, %.0f%% of all CPU", $0.offset + 1, $0.element.name, $0.element.coreHours, $0.element.share)
            }))
        }
        if !today.isEmpty { s.append(Section(heading: "Today", lines: today)) }
        if let b = battery, b.present {
            var lines: [String] = []
            if let h = b.health { lines.append(String(format: "Holds %.0f%% of its original capacity", h) + (b.cycleCount.map { " after \($0) cycles." } ?? ".")) }
            if let c = b.condition { lines.append("macOS reports: \(c).") }
            if let p = projection { lines.append("At the current rate it reaches 80% around \(p.formatted(.dateTime.month(.wide).year())).") }
            if !lines.isEmpty { s.append(Section(heading: "Battery", lines: lines)) }
        }
        if let r = sleep, r.sleeps > 0 {
            var lines = ["Asleep \(Insights.duration(r.asleep)) across \(r.sleeps) \(r.sleeps == 1 ? "sleep" : "sleeps"), with \(r.darkWakes) dark wakes."]
            if !r.wakeCauses.isEmpty { lines.append("Woken by: " + r.wakeCauses.prefix(3).map { "\($0.cause) (\($0.count))" }.joined(separator: ", ") + ".") }
            if let l = r.lossPerHour { lines.append(String(format: "Lost %.1f%% of charge an hour while asleep on battery.", l)) }
            s.append(Section(heading: "Sleep, last 24 hours", lines: lines))
        }
        if let m = memory {
            s.append(Section(heading: "Memory", lines: [
                "\(m.pressure.label): \(bytes(m.used)) of \(bytes(m.total)) used, \(bytes(m.swapUsed)) in swap.",
            ]))
        }
        return ReportDocument(title: "System Sentinel report",
                              subtitle: "\(machine) · \(now.formatted(date: .long, time: .shortened))", sections: s)
    }

    public var markdown: String {
        var out = "# \(title)\n\n_\(subtitle)_\n"
        for sec in sections {
            out += "\n## \(sec.heading)\n\n"
            let numbered = sec.lines.allSatisfy { $0.first?.isNumber == true }
            out += sec.lines.map { numbered ? $0 : "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    public static func bytes(_ b: UInt64) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }
}

// MARK: Heat and power alerts

/// Decides when to warn that the Mac is running hot or drawing a lot of power: at once
/// when macOS says it is hot (thermal state serious or worse), or when the draw stays
/// above the threshold for a while. Then quiet for `cooldown`, so it never nags.
public struct HeatWatch: Sendable {
    public enum Reason: Equatable, Sendable {
        /// Average watts over the stretch above the threshold.
        case power(watts: Double, minutes: Double)
        /// ProcessInfo.ThermalState raw value: 2 serious, 3 critical.
        case heat(state: Int)
    }

    public var thresholdWatts: Double
    /// How long the draw must stay above the threshold.
    public var minutes: Double
    public var watchHeat: Bool
    public var cooldown: TimeInterval
    private var aboveSince: Date?
    private var wattSum = 0.0
    private var wattCount = 0
    private var lastAlert: Date?
    private var lastThermal = 0

    public init(thresholdWatts: Double = 25, minutes: Double = 3, watchHeat: Bool = true, cooldown: TimeInterval = 1800) {
        self.thresholdWatts = thresholdWatts
        self.minutes = minutes
        self.watchHeat = watchHeat
        self.cooldown = cooldown
    }

    public mutating func update(watts: Double?, thermal: Int, at now: Date) -> Reason? {
        defer { lastThermal = thermal }
        if let w = watts, thresholdWatts > 0, w >= thresholdWatts {
            if aboveSince == nil {
                aboveSince = now
                wattSum = 0
                wattCount = 0
            }
            wattSum += w
            wattCount += 1
        } else {
            aboveSince = nil
        }
        if let t = lastAlert, now.timeIntervalSince(t) < cooldown {
            // Getting hotter still breaks through: serious to critical.
            guard watchHeat, thermal >= 3, lastThermal < 3 else { return nil }
        }
        if watchHeat, thermal >= 2, lastThermal < thermal || lastAlert == nil || now.timeIntervalSince(lastAlert!) >= cooldown {
            lastAlert = now
            aboveSince = nil
            return .heat(state: thermal)
        }
        if let since = aboveSince, now.timeIntervalSince(since) >= minutes * 60 {
            lastAlert = now
            aboveSince = nil
            return .power(watts: wattSum / Double(max(wattCount, 1)), minutes: minutes)
        }
        return nil
    }
}
