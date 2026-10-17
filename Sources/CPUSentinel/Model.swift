import AppKit
import ServiceManagement
import SentinelCore
import SwiftUI
import UserNotifications

/// Holds the engine, runs it on a timer, and turns its events into notifications.
@MainActor
final class Model: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var top: [ProcessSample] = []
    @Published var insights: [Insight] = []
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var totalCPU: Double = 0
    @Published var flagged: Set<Int32> = []
    @Published var lastError: String?
    @Published var lastAction: String?
    /// Kills in progress, so their buttons can say so: a polite stop waits up to 5 s.
    @Published var killing: Set<Int32> = []
    /// The result of the last kill, shown as a banner over the page.
    @Published var toast: Toast?
    /// Programs relaunched under a new pid soon after a kill, by path, so their row can say
    /// "restarted" instead of looking as if the kill did nothing.
    @Published var restarted: [String: Int32] = [:]
    /// Recent kills, by path, watched for a minute for a relaunch.
    private var recentKills: [String: (sample: ProcessSample, at: Date)] = [:]
    /// Battery and power, refreshed every tick. nil on a Mac without a battery.
    @Published var battery: BatteryStatus?
    /// Load per core since the last tick, split into efficiency and performance cores.
    @Published var coreLoad: CoreLoad?
    /// Processes keeping the Mac awake, refreshed with the energy readings.
    @Published var blockers: [SleepBlocker] = []
    /// Energy Impact and wakeups by app, from the latest `top` reading.
    @Published var energy: [EnergyRow] = []
    @Published var backgroundItems: [BackgroundItem] = []
    @Published var memory: MemoryStatus?
    /// Graphics chip busy share, 0 to 100.
    @Published var gpu: Double?
    /// Sleep over the last 24 hours, from the power log; refreshed every 15 minutes.
    @Published var sleepReport: SleepReport?
    /// Network and disk by app, from the latest 30 second reading.
    @Published var io: [IORow] = []
    /// What recent kills and quits changed, newest first.
    @Published var impacts: [Impact] = []
    let healthLog: HealthLog
    private let ioTracker = IOTracker()
    private var lastSleepRead: Date?
    private var typicalCache: (at: Date, values: [String: Double])?
    private var reportedBlockers: Set<String> = []
    let powerHistory: PowerHistory
    /// Energy Impact per app, hourly for 7 days, stored the same way as CPU.
    let energyUsage: DailyUsage
    private let coreSampler = CoreSampler()
    private let wakeups = WakeupTracker()
    private var lastEnergy: Date?
    private var energyRunning = false
    /// Kills run in Terminal, where only the process exiting tells us it worked.
    private var watching: [Int32: (sample: ProcessSample, until: Date)] = [:]

    struct Toast: Equatable {
        let id = UUID()
        let ok: Bool
        let title: String
        let detail: String?
    }

    let sentinel: Sentinel
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    private var timer: Timer?
    /// Processes named in a pending notification, so its Kill button acts on the right one.
    private var pending: [String: ProcessSample] = [:]
    private var startTimes: [Int32: Date] = [:]

    @AppStorage("threshold") var threshold: Double = 80 { didSet { sentinel.detector.threshold = threshold } }
    @AppStorage("windowSeconds") var windowSeconds: Double = 120 { didSet { sentinel.detector.window = windowSeconds } }
    @AppStorage("weeklyReport") var weeklyReport = true
    /// What the menu bar shows beside the icon: none, load, watts or battery.
    @AppStorage("menuBarShows") var menuBarShows = "none"
    @AppStorage("alertBlockers") var alertBlockers = true
    /// Heat and power alerts: hot (thermal serious or worse), or over `heatWatts` for `heatMinutes`.
    @AppStorage("alertHeat") var alertHeat = true
    @AppStorage("heatWatts") var heatWatts: Double = 25
    @AppStorage("heatMinutes") var heatMinutes: Double = 3
    private var heatWatch = HeatWatch()
    @AppStorage("blockerHours") var blockerHours: Double = 2
    @AppStorage("lastWeeklyReport") private var lastWeeklyReport: Double = 0

    static let supportDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CPUSentinel", isDirectory: true)

    /// Set by `--snapshot`: render screens to PNG without writing any of the owner's data.
    static let snapshotDir: String? = argument("--snapshot")
    /// `--after <seconds>`: how long to sample before rendering. Longer fills the last-hour chart
    /// and sparklines; the README screenshots use several minutes.
    static let snapshotDelay: Double = argument("--after").flatMap(Double.init) ?? 22
    /// `--expand <n>`: open only the first n insights in snapshots (default: all of them).
    static let snapshotExpand: Int = argument("--expand").flatMap(Int.init) ?? .max

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    override init() {
        sentinel = Sentinel(
            policies: PolicyStore(fileURL: Model.supportDir.appendingPathComponent("policies.json")),
            history: History(fileURL: Model.snapshotDir == nil ? Model.supportDir.appendingPathComponent("history.jsonl") : nil,
                             seed: Model.snapshotDir == nil ? nil : Model.supportDir.appendingPathComponent("history.jsonl")),
            dailyUsage: DailyUsage(fileURL: Model.supportDir.appendingPathComponent("usage-24h.json"),
                                   readOnly: Model.snapshotDir != nil),
            // A larger file than the hourly one, so it is written every 5 minutes, not every minute.
            recentUsage: DailyUsage(fileURL: Model.supportDir.appendingPathComponent("usage-6h.json"),
                                    retainHours: 6, bucket: 60, saveEvery: 300, readOnly: Model.snapshotDir != nil))
        powerHistory = PowerHistory(fileURL: Model.supportDir.appendingPathComponent("power-7d.json"), readOnly: Model.snapshotDir != nil)
        // Energy is read every 30 s, so a tick may stand for up to 45 s.
        energyUsage = DailyUsage(fileURL: Model.supportDir.appendingPathComponent("energy-7d.json"), maxStep: 45,
                                 saveEvery: 300, readOnly: Model.snapshotDir != nil)
        healthLog = HealthLog(fileURL: Model.supportDir.appendingPathComponent("battery-health.json"), readOnly: Model.snapshotDir != nil)
        super.init()
        sentinel.onBattery = { [weak self] in MainActor.assumeIsolated { self?.battery?.onBattery ?? false } }
        sentinel.batteryPercent = { [weak self] in MainActor.assumeIsolated { self?.battery?.percent } }
        backgroundItems = BackgroundItems.scan()
        sentinel.detector.threshold = threshold
        sentinel.detector.window = windowSeconds
        setUpNotifications()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let dir = Model.snapshotDir {
            DispatchQueue.main.asyncAfter(deadline: .now() + Model.snapshotDelay) { Snapshot.run(self, into: dir) }
        }
    }

    /// Load as a share of the whole machine: 100 means every core busy.
    var machineLoad: Double { totalCPU / max(cores, 1) }

    var level: Level {
        if !flagged.isEmpty { return .alert }
        return machineLoad >= 60 ? .busy : .normal
    }

    enum Level { case normal, busy, alert }

    func tick() {
        do {
            let events = try sentinel.tick()
            top = sentinel.top(30)
            totalCPU = sentinel.totalCPU
            let live = Set(sentinel.latest.map(\.pid))
            flagged.formIntersection(live)
            startTimes = startTimes.filter { live.contains($0.key) }
            // A flagged process that has cooled down is no longer flagged.
            flagged = flagged.filter { sentinel.detector.hotDuration(of: $0, at: Date()) != nil }
            lastError = nil
            for e in events { handle(e) }
            checkKills()
            readPower()
            thermal = ProcessInfo.processInfo.thermalState
            insights = Insights.generate(insightInput())
        } catch {
            lastError = "Could not read processes: \(error)"
        }
    }

    // MARK: Power

    private func readPower() {
        let now = Date()
        battery = PowerReader.read()
        if let b = battery {
            powerHistory.record(b, at: now)
            healthLog.record(b, at: now)
        }
        coreLoad = coreSampler.sample() ?? coreLoad
        memory = MemoryStatus.read()
        gpu = GPUReader.utilization()
        checkHeat(now)
        checkWeeklyReport(now)
        if lastSleepRead.map({ now.timeIntervalSince($0) >= 900 }) ?? true {
            lastSleepRead = now
            Task.detached {
                let events = SleepLog.parse(SleepLog.read(), since: now.addingTimeInterval(-86_400))
                let report = SleepLog.report(events, until: now)
                await MainActor.run { self.sleepReport = report }
            }
        }
        // `top` takes about a second; run it off the main thread every 30 s.
        guard !energyRunning, lastEnergy.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        energyRunning = true
        lastEnergy = now
        let pids = sentinel.latest.map(\.pid)
        Task.detached {
            let readings = EnergySampler.sample()
            let blockers = SleepBlockers.read()
            let net = IOSampler.network()
            var counters: [Int32: IOCounters] = [:]
            for pid in pids {
                let d = IOSampler.disk(pid)
                let n = net[pid]
                guard d != nil || n != nil else { continue }
                counters[pid] = IOCounters(netIn: n?.0 ?? 0, netOut: n?.1 ?? 0, diskRead: d?.0 ?? 0, diskWrite: d?.1 ?? 0)
            }
            let done = counters
            await MainActor.run { self.finishEnergy(readings, blockers, done) }
        }
    }

    private func finishEnergy(_ readings: [Int32: (power: Double, idleWakeups: Int)], _ blockers: [SleepBlocker], _ counters: [Int32: IOCounters]) {
        energyRunning = false
        let now = Date()
        io = IORow.group(ioTracker.update(counters, at: now), processes: sentinel.latest, key: Model.appKey, name: Model.appName)
        notifyOverdueBlockers(blockers, at: now)
        let samples = wakeups.update(readings, at: now)
        energy = EnergyRow.group(samples, processes: sentinel.latest, key: Model.appKey, name: Model.appName)
        self.blockers = blockers
        // Stored as samples whose "cpu" is the Energy Impact, so the CPU store's code serves.
        let paths = Dictionary(sentinel.latest.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        energyUsage.record(samples.compactMap { e in
            paths[e.pid].map { ProcessSample(pid: e.pid, uid: $0.uid, cpu: e.power, path: $0.path) }
        }, at: now)
    }

    /// Energy Impact by app over the last `hours`.
    func energySummaries(hours: Int) -> [DailyUsage.Summary] {
        energyUsage.summaries(at: Date(), hours: hours, group: Model.appKey, name: Model.appName)
    }

    func weekly() -> WeeklyReport {
        WeeklyReport.build(usage: sentinel.dailyUsage, power: powerHistory.points, events: sentinel.history.entries,
                           group: Model.appKey, name: Model.appName, at: Date())
    }

    func daySummary() -> [String] {
        let now = Date()
        let usage = sentinel.dailyUsage
        return DaySummary.lines(daily: usage.summaries(at: now, group: Model.appKey, name: Model.appName),
                                sampled: usage.sampled(at: now), totalHourly: usage.totalHourly(at: now),
                                hourStarts: DailyUsage.hourStarts(at: now, hours: 24).map { Date(timeIntervalSince1970: Double($0)) },
                                power: BatterySummary.from(powerHistory.since(now.addingTimeInterval(-86_400))),
                                blockers: blockers, cores: cores, at: now)
    }

    /// Monday from 9:00, once a week, with at least a day of data.
    private func checkWeeklyReport(_ now: Date) {
        guard weeklyReport, Model.snapshotDir == nil, now.timeIntervalSince1970 - lastWeeklyReport >= 6 * 86_400 else { return }
        let c = Calendar.current.dateComponents([.weekday, .hour], from: now)
        guard c.weekday == 2, (c.hour ?? 0) >= 9, sentinel.dailyUsage.sampled(at: now, hours: 24 * 7) >= 86_400 else { return }
        lastWeeklyReport = now.timeIntervalSince1970
        let content = UNMutableNotificationContent()
        content.title = "Your Mac's week"
        content.body = weekly().text
        content.categoryIdentifier = "info"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "weekly-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil))
    }

    func sample(pid: Int32) -> ProcessSample? { sentinel.latest.first { $0.pid == pid } }

    /// One notification per sleep assertion held longer than the setting allows.
    private func notifyOverdueBlockers(_ blockers: [SleepBlocker], at now: Date) {
        guard alertBlockers, Model.snapshotDir == nil else { return }
        let due = SleepBlockers.overdue(blockers, reported: reportedBlockers, threshold: blockerHours * 3600, at: now)
        guard let first = due.first else { return }
        for b in due { reportedBlockers.insert(SleepBlockers.reportKey(b)) }
        let content = UNMutableNotificationContent()
        if due.count == 1 {
            let held = first.since.map { Self.duration(now.timeIntervalSince($0)) } ?? ""
            content.title = "\(first.name) has kept your Mac awake for \(held)"
            content.body = (first.onBehalfOf.map { "On behalf of \($0). " } ?? "") + "\(first.kind.meaning). The Energy tab can stop it."
        } else {
            // One notification for many, so a pile of old ones does not flood the screen.
            let names = Array(Set(due.map { $0.onBehalfOf.map { "\($0) (caffeinate)" } ?? $0.name })).sorted()
            content.title = "\(due.count) things have kept your Mac awake for over \(Int(blockerHours))h"
            content.body = names.prefix(4).joined(separator: ", ") + ". The Energy tab can stop them."
        }
        content.categoryIdentifier = "info"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "blocker-\(SleepBlockers.reportKey(first))", content: content, trigger: nil))
    }

    /// Pops up a notification naming the culprit when the Mac runs hot or draws a lot of power.
    private func checkHeat(_ now: Date) {
        guard alertHeat, Model.snapshotDir == nil else { return }
        heatWatch.thresholdWatts = heatWatts
        heatWatch.minutes = heatMinutes
        guard let reason = heatWatch.update(watts: battery?.watts, thermal: ProcessInfo.processInfo.thermalState.rawValue, at: now) else { return }
        // The culprit: the top energy user, else the busiest process over the last minute.
        var culprit = heatCulprit(now)
        // Respect Ignore rules: still warn, without naming it.
        if let c = culprit, case .ignore = sentinel.policies.policy(for: c.path, at: now).resolved(at: now, onBattery: battery?.onBattery ?? false, percent: battery?.percent) {
            culprit = nil
        }
        let title: String
        var body: String
        switch reason {
        case .heat(let state):
            title = state >= 3 ? "Your Mac is critically hot" : "Your Mac is running hot"
            body = "macOS is slowing the chip to cool down."
        case .power(let w, let m):
            title = String(format: "Drawing %.0f W for %@", w, Self.duration(m * 60))
            body = String(format: "Over your %.0f W alert level", heatWatts)
            if let b = battery, b.onBattery, w > 0, let e = b.energyLeft { body += String(format: ": about %@ of battery left at this rate", Self.duration(e / w * 3600)) }
            body += "."
        }
        guard let s = culprit else {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = "info"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "heat-\(now.timeIntervalSince1970)", content: content, trigger: nil))
            return
        }
        notify(s, title: title, body: body + " Most likely: \(s.displayName), at \(Int(sentinel.cpuHistory.average(s.pid, over: 60, at: now)))% CPU.", actions: true)
    }

    private func heatCulprit(_ now: Date) -> ProcessSample? {
        if let top = energy.first, let pid = top.pids.max(by: { sentinel.cpuHistory.average($0, over: 60, at: now) < sentinel.cpuHistory.average($1, over: 60, at: now) }),
           let s = sample(pid: pid), s.pid != getpid() {
            return s
        }
        return sentinel.latest.filter { $0.pid != getpid() }.max { sentinel.cpuHistory.average($0.pid, over: 60, at: now) < sentinel.cpuHistory.average($1.pid, over: 60, at: now) }
    }

    /// The text beside the menu bar icon, per the setting.
    var menuBarText: String? {
        switch menuBarShows {
        case "load": return "\(Int(machineLoad))%"
        case "watts": return battery?.watts.map { String(format: "%.1f W", $0) }
        case "battery":
            guard let b = battery, b.present else { return nil }
            if b.onBattery, let m = b.minutesLeft { return "\(b.percent)% · \(m / 60):\(String(format: "%02d", m % 60))" }
            return "\(b.percent)%"
        default: return nil
        }
    }

    // MARK: Fixes

    func perform(_ fix: FixAction) {
        switch fix {
        case .quit(let pids, let name):
            quit(pids: pids, name: name)
        case .kill(let pids, let label):
            let targets = pids.compactMap(sample(pid:))
            startImpact(label, pids: pids)
            for s in targets { kill(s) }
            lastAction = "\(label): \(targets.count) stopped"
        case .lowPowerMode:
            Task.detached {
                // osascript, so the admin prompt runs off the main thread.
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", "do shell script \"/usr/bin/pmset -a lowpowermode 1\" with administrator privileges"]
                task.standardError = FileHandle.nullDevice
                let ok = (try? task.run()) != nil && { task.waitUntilExit(); return task.terminationStatus == 0 }()
                await MainActor.run {
                    self.showToast(Toast(ok: ok, title: ok ? "Low Power Mode is on" : "Low Power Mode was not changed",
                                         detail: ok ? nil : "The password prompt was cancelled or refused."))
                    self.tick()
                }
            }
        case .openSettings(let s):
            if let url = URL(string: s.url) { NSWorkspace.shared.open(url) }
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// Quits the app politely so it can save; processes that are not apps are stopped.
    func quit(pids: [Int32], name: String) {
        startImpact(name, pids: pids)
        var apps: [NSRunningApplication] = []
        var loose: [ProcessSample] = []
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil, app.activationPolicy != .prohibited {
                apps.append(app)
            } else if let s = sample(pid: pid), let bundle = AppIdentity.bundlePath(of: s.path),
                      let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == bundle }) {
                apps.append(app)
            } else if let s = sample(pid: pid) {
                loose.append(s)
            }
        }
        var seen = Set<pid_t>()
        for app in apps where seen.insert(app.processIdentifier).inserted { app.terminate() }
        for s in loose { kill(s) }
        showToast(Toast(ok: true, title: "Asked \(name) to quit", detail: "The result, in power and CPU, follows in a minute."))
    }

    /// Notes the draw and CPU now, and a minute later says what changed.
    func startImpact(_ name: String, pids: [Int32]) {
        let now = Date()
        let wattsBefore = powerHistory.since(now.addingTimeInterval(-120)).last?.watts ?? battery?.watts
        let cpuBefore = sentinel.cpuHistory.totalAverage(over: 60, at: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            let later = Date()
            let after = self.powerHistory.since(later.addingTimeInterval(-30))
            let wattsAfter = after.isEmpty ? self.battery?.watts : after.reduce(0) { $0 + $1.watts } / Double(after.count)
            let impact = Impact(name: name, at: now, wattsBefore: wattsBefore, wattsAfter: wattsAfter,
                                cpuBefore: cpuBefore, cpuAfter: self.sentinel.cpuHistory.totalAverage(over: 30, at: later),
                                energyLeft: self.battery?.onBattery == true ? self.battery?.energyLeft : nil)
            self.impacts.insert(impact, at: 0)
            if self.impacts.count > 20 { self.impacts.removeLast() }
            self.showToast(Toast(ok: impact.helped, title: impact.helped ? "Stopping \(name) helped" : "Stopping \(name) made little difference",
                                 detail: impact.summary.prefix(1).uppercased() + impact.summary.dropFirst() + "."))
        }
    }

    // MARK: Report

    func reportDocument() -> ReportDocument {
        var hw = [CChar](repeating: 0, count: 64)
        var size = hw.count
        sysctlbyname("hw.model", &hw, &size, nil, 0)
        return ReportDocument.build(machine: "\(String(cString: hw)), \(Int(cores)) cores, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                                    weekly: weekly(), today: daySummary(), battery: battery,
                                    projection: HealthLog.projection(healthLog.entries), sleep: sleepReport, memory: memory, at: Date())
    }

    // MARK: Explain

    /// Opens ChatGPT with a prompt describing this process and this Mac, asking why it is
    /// busy and how to bring it down. Nothing is sent until the owner presses Enter there.
    func explain(_ s: ProcessSample) {
        guard var c = URLComponents(string: "https://chatgpt.com/") else { return }
        c.queryItems = [URLQueryItem(name: "q", value: explainPrompt(s))]
        if let url = c.url { NSWorkspace.shared.open(url) }
        lastAction = "Opened ChatGPT about \(s.displayName)"
    }

    /// ChatGPT about an insight: the finding, the processes involved, and this Mac.
    func explain(_ insight: Insight) {
        let procs = insight.related.map { r in
            "- \(r.sample.name) (pid \(r.sample.pid)): \(Int(r.sample.cpu))% CPU now, 15 min average \(Int(average(r.sample, 900)))%\(r.parent.map { ", started by \($0)" } ?? ""), path \(r.sample.path)"
        }.joined(separator: "\n")
        let prompt = """
        My Mac's CPU monitor reports: "\(insight.title). \(insight.detail)"
        Explain in plain terms what is going on, how to confirm the cause, and step by step how to fix or reduce it on macOS. Say what is safe to stop.

        Processes involved:
        \(procs.isEmpty ? "(none listed)" : procs)

        \(machineSummary())
        """
        open(prompt)
        lastAction = "Opened ChatGPT about: \(insight.title)"
    }

    private func open(_ prompt: String) {
        guard var c = URLComponents(string: "https://chatgpt.com/") else { return }
        c.queryItems = [URLQueryItem(name: "q", value: prompt)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    private func machineSummary() -> String {
        var hw = [CChar](repeating: 0, count: 64)
        var size = hw.count
        sysctlbyname("hw.model", &hw, &size, nil, 0)
        let displays = NSScreen.screens.map { screen -> String in
            let px = screen.convertRectToBacking(screen.frame).size
            return "\(Int(px.width))x\(Int(px.height)) @ \(screen.maximumFramesPerSecond) Hz"
        }
        let others = sentinel.latest.filter { $0.cpu >= 3 }.sorted { $0.cpu > $1.cpu }.prefix(10)
            .map { "\($0.name) \(Int($0.cpu))%" }.joined(separator: ", ")
        return """
        Mac: \(String(cString: hw)), \(Int(cores)) cores, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Thermal state: \(["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)])
        Displays: \(displays.joined(separator: "; "))
        Busiest processes right now: \(others.isEmpty ? "none" : others)
        """
    }

    func explainPrompt(_ s: ProcessSample) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var hw = [CChar](repeating: 0, count: 64)
        var size = hw.count
        sysctlbyname("hw.model", &hw, &size, nil, 0)
        let displays = NSScreen.screens.map { screen -> String in
            let px = screen.convertRectToBacking(screen.frame).size
            return "\(Int(px.width))x\(Int(px.height)) @ \(screen.maximumFramesPerSecond) Hz"
        }
        let others = sentinel.latest.filter { $0.pid != s.pid && $0.cpu >= 3 }.sorted { $0.cpu > $1.cpu }.prefix(10)
            .map { "\($0.name) \(Int($0.cpu))%" }.joined(separator: ", ")
        let note = ProcessGuide.note(for: s.name).map { "\nWhat I know: \($0.headline). \($0.detail)" } ?? ""
        return """
        On my Mac the process "\(s.name)" is using a lot of CPU. Explain what it does, the most likely reasons it is this busy on my machine, and step by step how to bring its CPU use down. Tell me whether it is safe to quit or kill, and what I would lose.

        Process: \(s.name)
        Path: \(s.path)
        Runs as: \(s.isRoot ? "root" : "my user")
        CPU now: \(Int(s.cpu))% (100% = one core)
        Average CPU: 1 min \(Int(average(s, 60)))%, 15 min \(Int(average(s, 900)))%, 1 hour \(Int(average(s, 3600)))%
        Memory: \(Fmt.memory(s.rssKB))
        \(started(s) ?? "")\(note)

        Mac: \(String(cString: hw)), \(Int(cores)) cores, macOS \(os)
        Thermal state: \(["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)])
        Displays: \(displays.joined(separator: "; "))
        Other busy processes right now: \(others.isEmpty ? "none" : others)
        """
    }

    // MARK: Figures for the screens

    /// Machine load (100 = every core) averaged over `window` seconds.
    func machineAverage(_ window: TimeInterval) -> Double {
        sentinel.cpuHistory.totalAverage(over: window, at: Date()) / max(cores, 1)
    }

    func average(_ s: ProcessSample, _ window: TimeInterval) -> Double {
        sentinel.cpuHistory.average(s.pid, over: window, at: Date())
    }

    func sparkline(_ s: ProcessSample, minutes: Double = 15, buckets: Int = 30) -> [Double] {
        sentinel.cpuHistory.sparkline(s.pid, over: minutes * 60, buckets: buckets, at: Date())
    }

    var recordedMinutes: Double { sentinel.cpuHistory.recorded(at: Date()) / 60 }

    static func appKey(_ path: String) -> String { AppIdentity.groupKey(of: path) }

    static func appName(_ key: String) -> String {
        if key.contains("Google Chrome Helper (Renderer)") { return "Chrome tabs" }
        return AppIdentity.bundlePath(of: key) != nil ? AppIdentity.appName(of: key) : (key as NSString).lastPathComponent
    }

    private func insightInput() -> InsightInput {
        let now = Date()
        let hist = sentinel.cpuHistory
        let usage = sentinel.dailyUsage
        var avg15: [Int32: Double] = [:]
        for s in sentinel.latest where s.cpu >= 20 { avg15[s.pid] = hist.average(s.pid, over: 900, at: now) }
        var input = InsightInput(
            cores: cores, samples: sentinel.latest,
            total1m: hist.totalAverage(over: 60, at: now), total15m: hist.totalAverage(over: 900, at: now),
            total60m: hist.totalAverage(over: 3600, at: now), avg15m: avg15,
            recordedMinutes: hist.recorded(at: now) / 60,
            daily: usage.summaries(at: now, group: Model.appKey, name: Model.appName),
            dailySampled: usage.sampled(at: now),
            totalHourly: usage.totalHourly(at: now),
            hourStarts: DailyUsage.hourStarts(at: now, hours: 24).map { Date(timeIntervalSince1970: Double($0)) },
            events: sentinel.history.entries,
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            parents: parentNames())
        input.battery = battery
        input.blockers = blockers
        input.energy = energy
        input.typicalTotal = sentinel.dailyUsage.typicalTotal(at: now)
        input.memory = memory
        input.sleep = sleepReport
        input.charge = ChargeHabits.from(powerHistory.since(now.addingTimeInterval(-7 * 86_400)))
        input.healthProjection = HealthLog.projection(healthLog.entries)
        input.unusual = unusualApps(now)
        return input
    }

    /// Apps far above their own week, from the 15 minute averages.
    private func unusualApps(_ now: Date) -> [UnusualApp] {
        if typicalCache.map({ now.timeIntervalSince($0.at) >= 300 }) ?? true {
            typicalCache = (now, sentinel.dailyUsage.typicalByGroup(at: now, group: Model.appKey))
        }
        guard let typical = typicalCache?.values, !typical.isEmpty, recordedMinutes >= 15 else { return [] }
        var current: [String: (name: String, cpu: Double, pids: [Int32])] = [:]
        for s in sentinel.latest where s.cpu >= 1 {
            let k = Model.appKey(s.path)
            var c = current[k] ?? (Model.appName(k), 0, [])
            c.cpu += sentinel.cpuHistory.average(s.pid, over: 900, at: now)
            c.pids.append(s.pid)
            current[k] = c
        }
        return Unusual.find(current: current, typical: typical)
    }

    /// Who started each busy process: "screencapture, started by claude".
    private func parentNames() -> [Int32: String] {
        let names = Dictionary(sentinel.latest.map { ($0.pid, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var out: [Int32: String] = [:]
        for s in sentinel.latest where s.cpu >= 0.5 {
            guard let pp = ProcessSampler.parentPID(of: s.pid), pp > 1, let n = names[pp] else { continue }
            out[s.pid] = "\(n) (pid \(pp))"
        }
        return out
    }

    func hotFor(_ s: ProcessSample) -> String? {
        guard let d = sentinel.detector.hotDuration(of: s.pid, at: Date()), d >= 10 else { return nil }
        return Self.duration(d)
    }

    /// "started 09:14 (2h 5m ago)", or the date for anything older than today. Cached per
    /// pid: a pid's start time never changes, and a reused pid is a new entry anyway since
    /// dead pids are dropped.
    func started(_ s: ProcessSample) -> String? {
        if startTimes[s.pid] == nil { startTimes[s.pid] = ProcessSampler.startTime(of: s.pid) }
        guard let t = startTimes[s.pid] else { return nil }
        let when = Calendar.current.isDateInToday(t)
            ? t.formatted(date: .omitted, time: .shortened)
            : t.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let ago = Date().timeIntervalSince(t)
        let age = ago >= 86_400 ? "\(Int(ago / 86_400))d \(Int(ago.truncatingRemainder(dividingBy: 86_400) / 3600))h" : Self.duration(ago)
        return "started \(when) (\(age) ago)"
    }

    /// "up 22d 2h", short enough for a row subtitle.
    func uptime(_ s: ProcessSample) -> String? {
        if startTimes[s.pid] == nil { startTimes[s.pid] = ProcessSampler.startTime(of: s.pid) }
        guard let t = startTimes[s.pid] else { return nil }
        let ago = Date().timeIntervalSince(t)
        return ago >= 86_400 ? "up \(Int(ago / 86_400))d \(Int(ago.truncatingRemainder(dividingBy: 86_400) / 3600))h" : "up \(Self.duration(ago))"
    }

    static func duration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return m > 0 ? "\(m)m" : "\(Int(d))s"
    }

    // MARK: Actions

    func kill(_ s: ProcessSample) {
        guard !killing.contains(s.pid) else { return }
        killing.insert(s.pid)
        // The kill blocks (grace period, admin prompt), so it runs off the main thread; the
        // history write stays on it, where every other read and write of the engine happens.
        Task.detached {
            let outcome = Killer.kill(s)
            await MainActor.run {
                let ok = outcome == .terminated || outcome == .forceKilled || outcome == .alreadyGone
                self.sentinel.history.record(ok ? .killed : .killFailed, s, detail: "\(outcome)")
                self.flagged.remove(s.pid)
                self.finishKill(s, ok: ok, outcome: outcome)
            }
        }
    }

    /// Force kill: SIGKILL at once, through the admin prompt for root and macOS processes.
    func forceKill(_ s: ProcessSample) {
        guard !killing.contains(s.pid) else { return }
        killing.insert(s.pid)
        Task.detached {
            let outcome = Killer.forceKill(s)
            await MainActor.run {
                let ok = outcome == .forceKilled || outcome == .alreadyGone
                self.sentinel.history.record(ok ? .killed : .killFailed, s, detail: "force: \(outcome)")
                self.flagged.remove(s.pid)
                self.finishKill(s, ok: ok, outcome: outcome)
            }
        }
    }

    /// Clears the busy button, refreshes, says what happened, and starts watching for the
    /// case that makes a kill look like it did nothing: the program launched again at once.
    private func finishKill(_ s: ProcessSample, ok: Bool, outcome: KillOutcome) {
        killing.remove(s.pid)
        lastAction = "\(s.displayName): \(Self.describe(outcome))"
        if ok, !s.isChromeRenderer { recentKills[s.path] = (s, Date()) }
        if ok, s.cpu >= 20 || (battery?.onBattery ?? false) { startImpact(s.displayName, pids: [s.pid]) }
        showToast(Toast(ok: ok, title: "\(s.displayName) \(Self.describe(outcome))", detail: ok ? nil : Self.advice(outcome)))
        tick()
    }

    private static func advice(_ o: KillOutcome) -> String? {
        if case .failed(let why) = o, why.contains("SIGTERM") || why.contains("SIGKILL") {
            return "It is still running. Right-click it and choose Force kill, or use Force kill in the insight on the Overview."
        }
        return nil
    }

    /// Each tick: Terminal kills that have now exited, and killed programs that came back.
    private func checkKills() {
        let now = Date()
        for (pid, w) in watching {
            if !Killer.isAlive(pid) {
                watching[pid] = nil
                killing.remove(pid)
                sentinel.history.record(.killed, w.sample, detail: "sudo shell")
                recentKills[w.sample.path] = (w.sample, now)
                showToast(Toast(ok: true, title: "\(w.sample.displayName) stopped", detail: nil))
            } else if now > w.until {
                watching[pid] = nil
                killing.remove(pid)
                showToast(Toast(ok: false, title: "\(w.sample.displayName) is still running",
                                detail: "The Terminal kill has not taken effect after a minute. Check the Terminal window for a password prompt or an error."))
            }
        }
        for (path, k) in recentKills {
            if now.timeIntervalSince(k.at) > 60 {
                recentKills[path] = nil
                continue
            }
            guard restarted[path] == nil,
                  let again = sentinel.latest.first(where: { $0.path == path && $0.pid != k.sample.pid }) else { continue }
            restarted[path] = again.pid
            let parent = ProcessSampler.parentPID(of: again.pid)
            let byLaunchd = parent == 1
            let by = byLaunchd ? "macOS (launchd)" : parent.flatMap { p in sentinel.latest.first { $0.pid == p }.map { "\($0.displayName) (pid \(p))" } } ?? "another process"
            showToast(Toast(ok: true, title: "\(k.sample.displayName) was killed, then relaunched as pid \(again.pid)",
                            detail: "Restarted by \(by). Killing it again will not help\(byLaunchd ? ": macOS keeps this service running and the new copy usually settles down." : "; stop whatever keeps launching it.")"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.restarted[path] = nil }
        }
    }

    func showToast(_ t: Toast) {
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + (t.detail == nil ? 4 : 9)) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    /// The deliberate override for a protected process: the admin password prompt.
    func killProtected(_ s: ProcessSample) {
        guard !killing.contains(s.pid) else { return }
        killing.insert(s.pid)
        Task.detached {
            let outcome = Killer.killProtectedAsAdmin(s)
            await MainActor.run {
                let ok = outcome == .terminated || outcome == .alreadyGone
                self.sentinel.history.record(ok ? .killed : .killFailed, s, detail: "as admin: \(outcome)")
                self.finishKill(s, ok: ok, outcome: outcome)
            }
        }
    }

    /// Opens Terminal with the sudo kill typed and run, so the password goes to sudo itself.
    func openSudoShell(_ s: ProcessSample, force: Bool = false) {
        let command = force ? Killer.forceSudoCommand(for: s) : Killer.sudoCommand(for: s)
        let cmd = command.replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            lastError = code == -1743
                ? "Allow CPU Sentinel to control Terminal in System Settings > Privacy & Security > Automation."
                : "Could not open Terminal: \(error[NSAppleScript.errorMessage] ?? error)"
        } else {
            lastAction = "Terminal: \(command)"
            killing.insert(s.pid)
            watching[s.pid] = (s, Date().addingTimeInterval(60))
        }
    }

    func setPolicy(_ p: Policy, for s: ProcessSample) {
        sentinel.policies.set(p, for: s.path)
        if case .ignore = p { flagged.remove(s.pid) }
        objectWillChange.send()
    }

    func policy(for s: ProcessSample) -> Policy { sentinel.policies.policy(for: s.path) }

    static func describe(_ o: KillOutcome) -> String {
        switch o {
        case .terminated: return "stopped"
        case .forceKilled: return "force-killed (ignored the polite stop)"
        case .alreadyGone: return "had already exited"
        case .refused(let why): return "refused: \(why)"
        case .failed(let why): return "failed: \(why)"
        }
    }

    // MARK: Notifications

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let kill = UNNotificationAction(identifier: "kill", title: "Kill", options: [.destructive])
        let hour = UNNotificationAction(identifier: "ignore1h", title: "Ignore for 1 hour")
        let always = UNNotificationAction(identifier: "ignoreAlways", title: "Always ignore")
        let auto = UNNotificationAction(identifier: "autoKill", title: "Always auto-kill", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "badActor", actions: [kill, hour, always, auto], intentIdentifiers: []),
            UNNotificationCategory(identifier: "info", actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func handle(_ e: SentinelEvent) {
        switch e {
        case .alert(let s):
            flagged.insert(s.pid)
            notify(s, title: "\(s.displayName) is using \(Int(s.cpu))% CPU",
                   body: "Over \(Int(threshold))% for \(Self.duration(windowSeconds)). \(s.isRoot ? "Runs as root: Kill asks for your password." : "")",
                   actions: true)
        case .autoKillWithheld(let s, let reason):
            flagged.insert(s.pid)
            notify(s, title: "\(s.displayName) is using \(Int(s.cpu))% CPU",
                   body: "Not auto-killed: \(reason).", actions: true)
        case .autoKilled(let s, let outcome):
            notify(s, title: "Auto-killed \(s.displayName)",
                   body: "It was using \(Int(s.cpu))% CPU. \(Self.describe(outcome)).", actions: false)
        }
    }

    private func notify(_ s: ProcessSample, title: String, body: String, actions: Bool) {
        let id = "\(s.pid)-\(Date().timeIntervalSince1970)"
        pending[id] = s
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = actions && Safety.canKillManually(s) ? "badActor" : "info"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { done() }
            guard let s = self.pending.removeValue(forKey: id) else { return }
            switch action {
            case "kill": self.kill(s)
            case "ignore1h": self.setPolicy(.ignore(until: Date().addingTimeInterval(3600)), for: s)
            case "ignoreAlways": self.setPolicy(.ignore(until: nil), for: s)
            case "autoKill":
                self.setPolicy(.autoKill, for: s)
                self.kill(s)
            default: break
            }
        }
    }

    /// Show banners even while the menu is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        done([.banner, .sound])
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
