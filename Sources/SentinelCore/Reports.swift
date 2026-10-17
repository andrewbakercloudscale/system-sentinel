import Foundation

/// One app's energy use: Activity Monitor's Energy Impact and idle wakeups, summed over its
/// processes.
public struct EnergyRow: Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    /// Energy Impact now (roughly: 100 is one busy core, plus the cost of wakeups and GPU).
    public let power: Double
    /// Idle wakeups per second.
    public let wakeups: Double
    public let pids: [Int32]
    public var id: String { key }

    public init(key: String, name: String, power: Double, wakeups: Double, pids: [Int32]) {
        self.key = key
        self.name = name
        self.power = power
        self.wakeups = wakeups
        self.pids = pids
    }

    /// Folds per-process readings into one row per app, heaviest first.
    public static func group(_ samples: [EnergySample], processes: [ProcessSample],
                             key: (String) -> String, name: (String) -> String) -> [EnergyRow] {
        let paths = Dictionary(processes.map { ($0.pid, $0.path) }, uniquingKeysWith: { a, _ in a })
        var rows: [String: (power: Double, wakeups: Double, pids: [Int32])] = [:]
        for s in samples {
            guard let path = paths[s.pid] else { continue }
            let k = key(path)
            var r = rows[k] ?? (0, 0, [])
            r.power += s.power
            r.wakeups += s.wakeups
            r.pids.append(s.pid)
            rows[k] = r
        }
        return rows.map { EnergyRow(key: $0.key, name: name($0.key), power: $0.value.power, wakeups: $0.value.wakeups, pids: $0.value.pids.sorted()) }
            .filter { $0.power > 0 || $0.wakeups > 0 }
            .sorted { $0.power > $1.power }
    }
}

public enum BatteryMath {
    /// What the screen, memory and idle chip draw anyway: not attributable to any app.
    public static let baseline = 2.5

    /// An app's estimated share of the draw: its part of all Energy Impact, applied to the
    /// draw above the baseline.
    public static func appWatts(share: Double, totalWatts: Double) -> Double {
        max(totalWatts - baseline, 0) * min(max(share, 0), 1)
    }

    /// Extra minutes on battery if `appWatts` were not being drawn.
    public static func minutesGained(energyLeft: Double, watts: Double, appWatts: Double) -> Double {
        guard watts > 0, watts - appWatts > 0.5 else { return 0 }
        return (energyLeft / (watts - appWatts) - energyLeft / watts) * 60
    }

    /// Minutes of battery an app costs per hour of use: the share of an hour's charge it takes.
    public static func minutesPerHour(appWatts: Double, watts: Double) -> Double {
        guard watts > 0 else { return 0 }
        return appWatts / watts * 60
    }
}

extension DailyUsage {
    /// The usual machine total, in percent of one core: the mean over hours with at least
    /// ten minutes sampled, leaving out the current and previous hour so "now" is compared
    /// with the past rather than with itself.
    public func typicalTotal(at now: Date, hours: Int = 24 * 7) -> Double? {
        let totals = totalHourly(at: now, hours: hours).dropLast(2)
        let cov = coverageHourly(at: now, hours: hours).dropLast(2)
        let used = zip(totals, cov).filter { $0.1 >= 600 }.map(\.0)
        return used.count >= 6 ? used.reduce(0, +) / Double(used.count) : nil
    }
}

extension Insights {
    /// Battery, energy and sleep observations, added to the CPU ones.
    static func power(_ i: InsightInput, at now: Date) -> [Insight] {
        var out: [Insight] = []
        let byPID = Dictionary(i.samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func rel(_ pids: [Int32], about: String? = nil) -> [Insight.Related] {
            pids.compactMap { byPID[$0] }.sorted { $0.cpu > $1.cpu }.prefix(4)
                .map { Insight.Related(sample: $0, about: about ?? ProcessGuide.note(for: $0.name)?.headline, parent: i.parents[$0.pid]) }
        }
        let totalPower = i.energy.reduce(0) { $0 + $1.power }

        if let b = i.battery, b.present {
            // What the heaviest app costs on battery, in minutes.
            if b.onBattery, let w = b.watts, totalPower > 0, let top = i.energy.first, top.power / totalPower >= 0.2 {
                let appW = BatteryMath.appWatts(share: top.power / totalPower, totalWatts: w)
                let perHour = BatteryMath.minutesPerHour(appWatts: appW, watts: w)
                if appW >= 1, perHour >= 5 {
                    var x = Insight(id: "drain-\(top.key)", tone: perHour >= 20 ? .warning : .info, symbol: "battery.25percent",
                                    title: "\(top.name) costs about \(Int(perHour)) minutes of battery an hour",
                                    detail: String(format: "It is %.0f%% of all energy use right now, roughly %.1f W of the Mac's %.1f W.", top.power / totalPower * 100, appW, w))
                    if let e = b.energyLeft {
                        let gain = BatteryMath.minutesGained(energyLeft: e, watts: w, appWatts: appW)
                        if gain >= 10 { x.why = "At this rate, quitting it would add about \(Insights.duration(gain * 60)) to what is left. Estimated from its share of Energy Impact, after setting aside about \(String(format: "%.1f", BatteryMath.baseline)) W the screen and idle chip draw anyway." }
                    }
                    x.related = rel(top.pids)
                    x.steps = ["Quit it, or close the windows or tabs you are not using.",
                               "Check its own settings for background refresh, animations or sync you can turn off.",
                               "The Battery tab ranks every app by energy."]
                    out.append(x)
                }
            }
            // Low Power Mode.
            if b.onBattery, !b.lowPowerMode, b.percent <= 30 {
                var x = Insight(id: "lpm", tone: b.percent <= 15 ? .warning : .info, symbol: "leaf",
                                title: "\(b.percent)% left: Low Power Mode would stretch it",
                                detail: "It lowers the chip's clock and pauses background work, usually adding 10 to 30% more time.")
                x.steps = ["System Settings > Battery > Low Power Mode: Only on Battery.", "Lower screen brightness: the display is often the biggest single draw."]
                out.append(x)
            }
            // macOS background jobs that are better left for when the Mac is plugged in.
            let deferrable: [String: String] = ["backupd": "Time Machine", "mds_stores": "Spotlight", "mdworker_shared": "Spotlight",
                                                "mediaanalysisd": "Photos analysis", "photoanalysisd": "Photos analysis",
                                                "softwareupdated": "Software Update", "bird": "iCloud Drive", "cloudd": "iCloud"]
            if b.onBattery {
                let busy = i.samples.filter { deferrable[$0.name] != nil && $0.cpu >= 20 }
                if !busy.isEmpty {
                    let names = Array(Set(busy.compactMap { deferrable[$0.name] })).sorted()
                    var x = Insight(id: "bg-battery", tone: .info, symbol: "battery.100percent.bolt",
                                    title: "\(names.joined(separator: " and ")) running on battery",
                                    detail: "Background work that finishes sooner, and costs nothing, when the Mac is plugged in.")
                    x.related = rel(busy.map(\.pid))
                    x.steps = ["Plug in and leave it: these finish on their own.",
                               "Time Machine: System Settings > General > Time Machine > Options > Back up on battery power, off."]
                    out.append(x)
                }
            }
            // Health.
            if let c = b.condition, c != "Normal" {
                var x = Insight(id: "health", tone: .warning, symbol: "battery.0percent",
                                title: "macOS says: \(c)",
                                detail: "The battery \(b.health.map { "holds \(Int($0))% of its original charge" } ?? "is wearing")\(b.cycleCount.map { " after \($0) cycles" } ?? "").")
                x.why = "macOS shows Check Battery or Service Recommended when the battery holds noticeably less than new or reports a fault. It is safe to keep using; expect shorter runtime."
                x.steps = ["System Settings > Battery > Battery Health (the i button) for Apple's view.",
                           "Keep Optimised Battery Charging on so it sits at 80% when plugged in for long.",
                           "Apple replaces batteries under 80% within warranty or AppleCare."]
                out.append(x)
            } else if let h = b.health, h < 80 {
                out.append(Insight(id: "health", tone: .info, symbol: "battery.50percent",
                                   title: "Battery holds \(Int(h))% of its original charge",
                                   detail: "Below 80% Apple considers it consumed. Runtime is shorter than new."))
            }
        }

        // Sleep blockers held for over an hour.
        let long = i.blockers.filter { b in b.since.map { now.timeIntervalSince($0) >= 3600 } ?? false }
        if !long.isEmpty {
            let who = Array(Set(long.map { $0.onBehalfOf ?? $0.name })).sorted()
            let longest = long.compactMap(\.since).min().map { now.timeIntervalSince($0) } ?? 0
            var x = Insight(id: "blockers", tone: .warning, symbol: "moon.zzz.fill",
                            title: "\(long.count) \(long.count == 1 ? "thing is" : "things are") keeping your Mac awake",
                            detail: "\(who.joined(separator: ", ")) \(who.count == 1 ? "stops" : "stop") it sleeping, the longest for \(Insights.duration(longest)). An awake Mac drains its battery in hours instead of days.")
            x.why = "Apps ask macOS not to sleep while they work (a download, a call, a build). caffeinate does the same for command-line tools, and the request lasts until the tool exits: a forgotten terminal or an agent session left open keeps the Mac awake indefinitely, lid open, screen off."
            // The blockers themselves, so Kill is one click: killing caffeinate frees the Mac.
            x.related = long.prefix(6).compactMap { b in
                byPID[b.pid].map { s in
                    let held = b.since.map { Insights.duration(now.timeIntervalSince($0)) } ?? ""
                    return Insight.Related(sample: s, about: "\(b.kind.meaning)\(b.onBehalfOf.map { " for \($0)" } ?? "") for \(held)",
                                           parent: b.onBehalfOfPID.map { p in byPID[p].map { "\($0.displayName) (pid \(p))" } ?? "pid \(p)" } ?? i.parents[s.pid])
                }
            }
            x.steps = ["Finish or close the sessions named above if you are not using them.",
                       "Kill a caffeinate process to let the Mac sleep; the tool it served keeps running.",
                       "The Battery tab lists every sleep blocker and how long it has been held."]
            out.append(x)
        }

        // Idle wakeups.
        if let w = i.energy.filter({ $0.wakeups >= 150 }).max(by: { $0.wakeups < $1.wakeups }) {
            var x = Insight(id: "wakeups-\(w.key)", tone: w.wakeups >= 500 ? .warning : .info, symbol: "alarm.fill",
                            title: "\(w.name) wakes the CPU \(Int(w.wakeups)) times a second",
                            detail: "Each wakeup stops the chip resting. Hundreds a second cost battery even at low CPU.")
            x.why = "Idle wakeups are timers firing: polling, animations, busy loops waiting for something. Activity Monitor's Energy tab counts them too. Under about 50 a second is normal for an active app."
            x.related = rel(w.pids)
            x.steps = ["Quit it when you are not using it.", "Look for animated content, live dashboards or polling plug-ins inside it.", "Update it: excessive wakeups are a common bug that vendors fix."]
            out.append(x)
        }

        // Compared with the usual.
        if let usual = i.typicalTotal, usual > 0, i.recordedMinutes >= 30, i.total60m >= 50, i.total60m >= 2 * usual {
            out.append(Insight(id: "vsusual", tone: .info, symbol: "chart.bar.doc.horizontal",
                               title: String(format: "This hour is %.1fx your usual", i.total60m / usual),
                               detail: "Averaging \(fmtCores(i.total60m)) against a typical \(fmtCores(usual)) over the last week."))
        }
        return out
    }
}

/// The day so far in a few sentences, for the Battery tab and the daily notification.
public enum DaySummary {
    public static func lines(daily: [DailyUsage.Summary], sampled: TimeInterval, totalHourly: [Double], hourStarts: [Date],
                             power: BatterySummary?, blockers: [SleepBlocker], cores: Double, at now: Date) -> [String] {
        var out: [String] = []
        let total = daily.reduce(0) { $0 + $1.coreSeconds }
        if sampled >= 600, total > 0 {
            out.append("Watched for \(Insights.duration(sampled)); your Mac averaged \(Insights.fmtCores(total / sampled * 100)) of \(Int(cores)) cores.")
            let top = daily.prefix(3).map { "\($0.name) \(Int($0.coreSeconds / total * 100))%" }
            out.append("Most CPU time: \(top.joined(separator: ", ")).")
        }
        if let (i, peak) = totalHourly.enumerated().max(by: { $0.element < $1.element }), peak > 0, hourStarts.indices.contains(i) {
            let day = Calendar.current.isDate(hourStarts[i], inSameDayAs: now) ? "" : "yesterday "
            out.append("Busiest hour: \(day)\(hourStarts[i].formatted(date: .omitted, time: .shortened)) at \(Insights.fmtCores(peak)).")
        }
        if let p = power, p.minutes >= 10 {
            if p.batteryMinutes >= 10 {
                var s = "On battery for \(Insights.duration(Double(p.batteryMinutes) * 60))"
                if let w = p.averageBatteryWatts { s += String(format: ", drawing %.1f W on average", w) }
                if let d = p.drainPerHour { s += String(format: ", using %.0f%% an hour", d) }
                out.append(s + ".")
            } else if let w = p.averageWatts {
                out.append(String(format: "Plugged in all day, drawing %.1f W on average", w) + (p.peakWatts.map { String(format: ", peak %.0f W.", $0) } ?? "."))
            }
        }
        let awake = blockers.filter { b in b.since.map { now.timeIntervalSince($0) >= 3600 } ?? false }
        if !awake.isEmpty {
            out.append("\(awake.count) sleep \(awake.count == 1 ? "blocker has" : "blockers have") kept the Mac awake for over an hour.")
        }
        return out
    }
}

/// The last 7 days: who used the CPU, the busiest day, battery and actions taken.
public struct WeeklyReport: Equatable, Sendable {
    public struct App: Equatable, Sendable {
        public let name: String
        /// Core-hours: one core flat out for an hour is 1.
        public let coreHours: Double
        public let share: Double
    }

    public let apps: [App]
    public let coreHours: Double
    public let hoursWatched: Double
    public let busiestDay: Date?
    public let busiestDayCoreHours: Double
    public let batteryHours: Double
    public let averageWatts: Double?
    public let flagged: Int
    public let killed: Int

    public static func build(usage: DailyUsage, power: [PowerHistory.Point], events: [HistoryEntry],
                             group: ((String) -> String)? = nil, name: ((String) -> String)? = nil,
                             at now: Date, calendar: Calendar = .current) -> WeeklyReport {
        let hours = 24 * 7
        let summaries = usage.summaries(at: now, hours: hours, group: group, name: name)
        let total = summaries.reduce(0) { $0 + $1.coreSeconds }
        let apps = summaries.prefix(5).map { App(name: $0.name, coreHours: $0.coreSeconds / 3600, share: total > 0 ? $0.coreSeconds / total * 100 : 0) }
        var perDay: [Date: Double] = [:]
        let starts = DailyUsage.hourStarts(at: now, hours: hours)
        for (h, (pct, cov)) in zip(starts, zip(usage.totalHourly(at: now, hours: hours), usage.coverageHourly(at: now, hours: hours))) {
            perDay[calendar.startOfDay(for: Date(timeIntervalSince1970: Double(h))), default: 0] += pct / 100 * cov / 3600
        }
        let busiest = perDay.filter { $0.value > 0 }.max { $0.value < $1.value }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let recent = events.filter { $0.date > weekAgo }
        let pts = power.filter { Double($0.t) > weekAgo.timeIntervalSince1970 }
        return WeeklyReport(
            apps: apps, coreHours: total / 3600, hoursWatched: usage.sampled(at: now, hours: hours) / 3600,
            busiestDay: busiest?.key, busiestDayCoreHours: busiest?.value ?? 0,
            batteryHours: Double(pts.filter(\.onBattery).count) / 60,
            averageWatts: pts.isEmpty ? nil : pts.reduce(0) { $0 + $1.watts } / Double(pts.count),
            flagged: recent.filter { $0.kind == .flagged }.count,
            killed: recent.filter { [.killed, .autoKilled].contains($0.kind) }.count)
    }

    /// For the weekly notification.
    public var text: String {
        var parts: [String] = []
        if let top = apps.first { parts.append(String(format: "%@ used the most CPU (%.0f%%).", top.name, top.share)) }
        parts.append(String(format: "%.1f core-hours over %.0f hours watched.", coreHours, hoursWatched))
        if batteryHours >= 0.5 { parts.append(String(format: "%.1f h on battery", batteryHours) + (averageWatts.map { String(format: ", %.1f W average.", $0) } ?? ".")) }
        if flagged + killed > 0 { parts.append("\(flagged) flagged, \(killed) killed.") }
        return parts.joined(separator: " ")
    }
}
