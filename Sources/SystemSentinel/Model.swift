import AppKit
import IOKit
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
    /// Settings changed but not yet saved (Settings, Save or Revert).
    @Published var settingsEdits: SettingsDraft?
    /// Kills in progress, so their buttons can say so: a polite stop waits up to 5 s.
    @Published var killing: Set<Int32> = []
    /// The result of the last kill, shown as a banner over the page.
    @Published var toast: Toast?
    /// Programs relaunched under a new pid soon after a kill, by path, so their row can say
    /// "restarted" instead of looking as if the kill did nothing.
    @Published var restarted: [String: Int32] = [:]
    /// Processes put at background priority (efficiency cores, I/O last), and the names that
    /// always are. See SlowDown.swift.
    @Published var slowed: Set<Int32> = []
    @Published var slowRules: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "slowRules") ?? [])
    /// Recent kills, by path, watched for a minute for a relaunch.
    private var recentKills: [String: (sample: ProcessSample, at: Date)] = [:]
    /// Battery and power, refreshed every tick. nil on a Mac without a battery.
    @Published var battery: BatteryStatus?
    /// The time chips' figures, from the last hour, refreshed every 10 minutes.
    @Published private(set) var powerOutlook: PowerOutlook?
    /// Load per core since the last tick, split into efficiency and performance cores.
    @Published var coreLoad: CoreLoad?
    /// Apps by CPU on each kind of core over the last sample, busiest first.
    @Published var clusterApps: (efficiency: [ClusterApp], performance: [ClusterApp]) = ([], [])
    private var clusterTimes: [Int32: ClusterTime] = [:]
    private var clusterTimesAt: Date?

    struct ClusterApp: Identifiable {
        let key: String
        let name: String
        let sample: ProcessSample
        /// Percent of one core.
        let cpu: Double
        var id: String { key }
    }
    /// Processes keeping the Mac awake, refreshed with the energy readings.
    @Published var blockers: [SleepBlocker] = []
    /// Energy Impact and wakeups by app, from the latest `top` reading.
    @Published var energy: [EnergyRow] = []
    @Published var energyAt: Date?
    @Published var backgroundItems: [BackgroundItem] = []
    @Published var memory: MemoryStatus?
    /// Memory by app, largest first, refreshed every tick.
    @Published var memoryApps: [MemoryApp] = []
    /// Findings from the memory timeline, for the Memory tab.
    @Published var memoryInsights: [Insight] = []
    let memoryHistory: MemoryHistory
    /// "Quit it when it holds more than N GB in the background", per app on the Memory tab.
    let memoryRules = MemoryRuleStore(fileURL: Model.supportDir.appendingPathComponent("memory-rules.json"))
    private let memoryRuleWatch = MemoryRuleWatch()

    struct MemoryApp: Identifiable {
        let key: String
        let name: String
        let bytes: UInt64
        /// Compressed or in swap: footprint minus what is in RAM.
        let outOfRAM: UInt64
        let pids: [Int32]
        /// The largest process, for the icon and the Quit button.
        let sample: ProcessSample
        var id: String { key }
    }
    /// Graphics chip busy share, 0 to 100.
    @Published var gpu: Double?
    /// The graphics chip in full, and its busy share every 5 seconds for the last hour.
    @Published var gpuStatus: GPUReader.Status?
    @Published var gpuHistory: [(at: Date, busy: Double)] = []
    /// Watts by part (CPU, graphics, Neural Engine, memory), and the graphics watts over the last hour.
    @Published var partWatts: PartPower.Watts?
    /// The built-in screen's brightness and backlight current. nil without a built-in screen.
    @Published var screenLight: ScreenLight?
    @Published var gpuWattsHistory: [(at: Date, watts: Double)] = []
    private let partPower = PartPower()
    /// Apps using the graphics chip over the last 5 seconds; `cpu` is their share of the chip.
    @Published var gpuApps: [ClusterApp] = []
    private var gpuTimesAt: Date?
    /// Each process's share of the graphics chip over the last 5 seconds, for the Processes tab.
    @Published var gpuShares: [Int32: Double] = [:]
    /// Each app's share every 5 seconds for the last 5 minutes, with its pids, for the insights.
    private var gpuAppLog: [(at: Date, shares: [String: Double])] = []
    private var gpuAppPIDs: [String: [Int32]] = [:]
    /// Sleep over the last 24 hours, from the power log; refreshed every 15 minutes.
    @Published var sleepReport: SleepReport?
    /// Network and disk by app, from the latest 30 second reading.
    @Published var io: [IORow] = []
    /// What recent kills and quits changed, newest first.
    @Published var impacts: [Impact] = []
    /// Apps that stopped responding, this one included, newest first.
    @Published var hangs: [Hang] = Model.loadHangs()
    let hangTracker = HangTracker()
    /// Disk and network rates per pid from the last energy read, for the wait reasons.
    var ioRates: [Int32: IORate] = [:]
    let healthLog: HealthLog
    let storage: StorageStore
    let permissions = Permissions()
    let checkup: CheckupStore
    let network: NetworkStore
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
        /// Which window shows it: "main" (the menu and its pop-out) or "about".
        var surface = "main"
    }

    let sentinel: Sentinel
    /// The running model, for the app delegate (which SwiftUI creates before the scene's state).
    static weak var current: Model?
    /// Kept alive so SIGTERM saves before quitting.
    static var termSource: DispatchSourceSignal?
    /// A card to scroll to (and its view, after a colon), set by an insight's Review button.
    @Published var focus: String?
    /// A tab to switch to, by title, set by a Go to button; the menu clears it once it has moved.
    @Published var goTab: String?
    /// When each background job last finished, for the Diagnostics card.
    @Published var taskHealth = TaskHealth()
    /// macOS's report of the crash that ended the last run, shown once on the next launch.
    @Published var lastCrash: URL?
    let errorLog = ErrorLog(fileURL: Model.snapshotDir == nil ? Model.supportDir.appendingPathComponent("errors.log") : nil)
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    private var timer: Timer?
    /// Processes named in a pending notification, so its Kill button acts on the right one.
    private var pending: [String: ProcessSample] = [:]
    private var startTimes: [Int32: Date] = [:]

    @AppStorage("threshold") var threshold: Double = 80 { didSet { sentinel.detector.threshold = threshold } }
    @AppStorage("windowSeconds") var windowSeconds: Double = 120 { didSet { sentinel.detector.window = windowSeconds } }
    @AppStorage("weeklyReport") var weeklyReport = true
    /// Days of history kept: 7, 14 or 28 (`HistoryRetention`).
    @AppStorage("historyDays") var historyDays = HistoryRetention.defaultDays { didSet { applyRetention() } }
    /// What the menu bar shows beside the icon: none, load, watts or battery.
    @AppStorage("menuBarShows") var menuBarShows = "none"
    @AppStorage("alertBlockers") var alertBlockers = true
    /// Heat and power alerts: hot (thermal serious or worse), or over `heatWatts` for `heatMinutes`.
    @AppStorage("alertHeat") var alertHeat = true
    @AppStorage("heatWatts") var heatWatts: Double = 25
    @AppStorage("heatMinutes") var heatMinutes: Double = 3
    private var heatWatch = HeatWatch()
    private var lowBattery = LowBatteryWarning()
    @AppStorage("blockerHours") var blockerHours: Double = 2
    @AppStorage("lastWeeklyReport") private var lastWeeklyReport: Double = 0
    /// Updates: a newer release on GitHub, checked 30 s after launch and every 6 hours.
    @AppStorage("autoUpdateCheck") var autoUpdateCheck = true
    @AppStorage("lastUpdateCheck") var lastUpdateCheck: Double = 0
    /// The version already announced in a notification, so each one is announced once.
    @AppStorage("notifiedUpdate") var notifiedUpdate = ""
    @Published var update: Updates.Release?
    /// Commits on GitHub since this version, released or not.
    @Published var changes: Updates.Changes?
    /// Resource alarms: each on/off with its limit, set in Settings.
    @AppStorage("alarmCPU") var alarmCPU = true
    @AppStorage("alarmCPUPercent") var alarmCPUPercent: Double = 85
    @AppStorage("alarmCPUMinutes") var alarmCPUMinutes: Double = 10
    @AppStorage("alarmSwap") var alarmSwap = true
    @AppStorage("alarmSwapGB") var alarmSwapGB: Double = 8
    @AppStorage("alarmPressure") var alarmPressure = true
    @AppStorage("alarmPressureMinutes") var alarmPressureMinutes: Double = 5
    @AppStorage("alarmDisk") var alarmDisk = true
    @AppStorage("dnsWorkHost") var dnsWorkHost = ""
    @AppStorage("hotspotAlerts") var hotspotAlerts = true
    /// Stop ChatGPT's screen helper (SkyComputerUseService) after 15 minutes without ChatGPT in front.
    @AppStorage("stopIdleScreenHelper") var stopIdleScreenHelper = false
    /// Notify when an app has shown the spinning wheel for 10 seconds.
    @AppStorage("alertHangs") var alertHangs = true
    private var chatGPTInFront = Date()
    private var helperStopped: Date?
    @AppStorage("alarmDiskGB") var alarmDiskGB: Double = 20
    var alarmWatches: [ResourceAlarm: AlarmWatch] = [:]
    /// The alarms that went off, newest first.
    @Published var alarmLog: [(alarm: ResourceAlarm, at: Date, text: String)] = []
    @Published var updateState: UpdateState = .idle
    var updateTimer: Timer?

    static let supportDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SystemSentinel", isDirectory: true)

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
        Diagnostics.log = errorLog
        sentinel = Sentinel(
            policies: PolicyStore(fileURL: Model.supportDir.appendingPathComponent("policies.json")),
            history: History(fileURL: Model.snapshotDir == nil ? Model.supportDir.appendingPathComponent("history.jsonl") : nil,
                             seed: Model.snapshotDir == nil ? nil : Model.supportDir.appendingPathComponent("history.jsonl")),
            // Hourly despite the file name, and up to 28 days: written every 5 minutes.
            dailyUsage: DailyUsage(fileURL: Model.supportDir.appendingPathComponent("usage-24h.json"),
                                   saveEvery: 300, readOnly: Model.snapshotDir != nil),
            // A larger file than the hourly one, so it is written every 5 minutes, not every minute.
            recentUsage: DailyUsage(fileURL: Model.supportDir.appendingPathComponent("usage-6h.json"),
                                    retainHours: 6, bucket: 60, saveEvery: 300, readOnly: Model.snapshotDir != nil),
            // nettop, ps, ping and the other commands this app runs count as System Sentinel.
            sampler: { try ProcessSampler.sample(foldingInto: getpid()) })
        powerHistory = PowerHistory(fileURL: Model.supportDir.appendingPathComponent("power-7d.json"), readOnly: Model.snapshotDir != nil)
        // Energy is read every 30 s, so a tick may stand for up to 45 s.
        energyUsage = DailyUsage(fileURL: Model.supportDir.appendingPathComponent("energy-7d.json"), maxStep: 45,
                                 saveEvery: 300, readOnly: Model.snapshotDir != nil)
        energyUsage.dropOutliers(above: EnergySampler.maxImpact)
        memoryHistory = MemoryHistory(fileURL: Model.supportDir.appendingPathComponent("memory-7d.json"), readOnly: Model.snapshotDir != nil)
        healthLog = HealthLog(fileURL: Model.supportDir.appendingPathComponent("battery-health.json"), readOnly: Model.snapshotDir != nil)
        storage = StorageStore(supportDir: Model.supportDir, readOnly: Model.snapshotDir != nil)
        checkup = CheckupStore(readOnly: Model.snapshotDir != nil)
        network = NetworkStore(readOnly: Model.snapshotDir != nil)
        super.init()
        Model.current = self
        storage.toast = { [weak self] in self?.showToast($0) }
        checkup.toast = { [weak self] in self?.showToast($0) }
        storage.ran = { [weak self] in self?.taskHealth.ran($0) }
        checkup.ran = { [weak self] in self?.taskHealth.ran($0) }
        network.processes = { [weak self] in self?.sentinel.latest ?? [] }
        network.ran = { [weak self] in self?.taskHealth.ran($0) }
        sentinel.onBattery = { [weak self] in MainActor.assumeIsolated { self?.battery?.onBattery ?? false } }
        sentinel.batteryPercent = { [weak self] in MainActor.assumeIsolated { self?.battery?.percent } }
        backgroundItems = BackgroundItems.scan()
        sentinel.detector.threshold = threshold
        sentinel.detector.window = windowSeconds
        applyRetention()
        setUpNotifications()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let dir = Model.snapshotDir {
            TweakStore.shared.refresh()
            if let name = Model.argument("--dnsmap") { DNSMapStore.shared.input = name; DNSMapStore.shared.start() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Model.snapshotDelay) { Snapshot.run(self, into: dir) }
        } else {
            watchForCrashes()
            saveOnQuit()
            announceUpdate()
            scheduleUpdateChecks()
        }
    }

    /// Load as a share of the whole machine: 100 means every core busy.
    var machineLoad: Double { totalCPU / max(cores, 1) }

    var level: Level {
        if !flagged.isEmpty { return .alert }
        return machineLoad >= 60 ? .busy : .normal
    }

    enum Level { case normal, busy, alert }

    /// Samples with `ps` off the main thread, then applies it here. Run on the main thread,
    /// `ps` held it for up to a second each tick, so tab clicks hung.
    private var sampling = false
    private var tickAgain = false
    /// `attention()` for the current tick, so every redraw does not redo the symptom checks.
    var attentionCache: (key: Int, value: Attention)?

    func tick() {
        guard !sampling else { tickAgain = true; return }
        sampling = true
        Task.detached {
            let result = Result { try ProcessSampler.sample(foldingInto: getpid()) }
            await MainActor.run {
                self.sampling = false
                self.apply(result)
                if self.tickAgain { self.tickAgain = false; self.tick() }
            }
        }
    }

    private func apply(_ result: Result<[ProcessSample], Error>) {
        Activity.set("updating after a process sample")
        defer { Activity.set(nil) }
        SelfGuard.record()
        do {
            let events = sentinel.tick(with: try result.get())
            attentionCache = nil
            top = sentinel.top(30)
            totalCPU = sentinel.totalCPU
            let live = Set(sentinel.latest.map(\.pid))
            flagged.formIntersection(live)
            slowed.formIntersection(live)
            applySlowRules()
            startTimes = startTimes.filter { live.contains($0.key) }
            // A flagged process that has cooled down is no longer flagged.
            flagged = flagged.filter { sentinel.detector.hotDuration(of: $0, at: Date()) != nil }
            lastError = nil
            taskHealth.ran(.sampling)
            for e in events { handle(e) }
            checkKills()
            stopIdleScreenHelperIfNeeded(Date())
            readPower()
            thermal = ProcessInfo.processInfo.thermalState
            insights = (Insights.generate(insightInput())
                + memoryInsights.filter { $0.id == "mem-thrash" || $0.id.hasPrefix("mem-grow-") }
                + storage.insights.filter { $0.tone >= .warning })
                .map { $0.id == "memory" ? explainQuit($0) : $0 }
        } catch {
            lastError = "Could not read processes: \(error)"
            Diagnostics.report("sampling", lastError!)
        }
    }

    // MARK: Power

    private func readPower() {
        let now = Date()
        battery = PowerReader.read()
        PlugInBlink.shared.active = battery?.needsPlugIn ?? false
        if let b = battery {
            powerHistory.record(b, at: now)
            healthLog.record(b, at: now)
            if powerOutlook.map({ $0.stale(b, at: now) }) ?? true {
                powerOutlook = PowerOutlook.of(b, lastHour: powerHistory.since(now.addingTimeInterval(-3600)), at: now)
            }
        }
        checkLowBattery(now)
        coreLoad = coreSampler.sample() ?? coreLoad
        readClusters(now)
        memory = MemoryStatus.read()
        readMemory(now)
        readGPU(now)
        if let w = partPower?.read(now: now) {
            partWatts = w
            screenLight = Self.readScreenLight()
            if let g = w.gpu {
                gpuWattsHistory.append((now, g))
                gpuWattsHistory.removeAll { now.timeIntervalSince($0.at) > 3600 }
            }
        }
        checkHeat(now)
        checkAlarms(now)
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
        let rates = ioTracker.update(counters, at: now)
        ioRates = Dictionary(rates.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        io = IORow.group(rates, processes: sentinel.latest, key: Model.appKey, name: Model.appName)
        notifyOverdueBlockers(blockers, at: now)
        let samples = wakeups.update(readings, at: now)
        energyAt = now
        taskHealth.ran(.energy, at: now)
        energy = EnergyRow.group(samples, processes: sentinel.latest, key: Model.appKey, name: Model.appName)
        self.blockers = blockers
        // Stored as samples whose "cpu" is the Energy Impact, so the CPU store's code serves.
        let paths = Dictionary(sentinel.latest.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        energyUsage.record(samples.compactMap { e in
            paths[e.pid].map { ProcessSample(pid: e.pid, uid: $0.uid, cpu: e.power, path: $0.path) }
        }, at: now)
    }

    /// Memory by app (footprints where macOS gives them), the timeline and its findings.
    private func readMemory(_ now: Date) {
        guard let m = memory else { return }
        var groups: [String: (bytes: UInt64, away: UInt64, pids: [Int32], top: ProcessSample, topBytes: UInt64)] = [:]
        for s in sentinel.latest {
            let fp = MemoryStatus.footprint(s.pid)
            let b = fp ?? UInt64(s.rssKB) * 1024
            guard b >= 10 << 20 else { continue }
            // Resident counts shared libraries too, so this is a floor, never an overstatement.
            let inRAM = MemoryStatus.resident(s.pid) ?? b
            let away = fp != nil && b > inRAM ? b - inRAM : 0
            let k = Model.appKey(s.path)
            if var g = groups[k] {
                g.bytes += b
                g.away += away
                g.pids.append(s.pid)
                if b > g.topBytes { g.top = s; g.topBytes = b }
                groups[k] = g
            } else {
                groups[k] = (b, away, [s.pid], s, b)
            }
        }
        memoryApps = groups.map { MemoryApp(key: $0.key, name: Model.memoryName($0.key), bytes: $0.value.bytes, outOfRAM: $0.value.away,
                                            pids: $0.value.pids, sample: $0.value.top) }
            .sorted { $0.bytes > $1.bytes }
        // Name the VM after the app running it, when one is.
        if let host = vmHost(), let i = memoryApps.firstIndex(where: { Model.isVM($0.key) }) {
            let v = memoryApps[i]
            memoryApps[i] = MemoryApp(key: v.key, name: "Virtual machine (\(host.name))", bytes: v.bytes, outOfRAM: v.outOfRAM, pids: v.pids, sample: v.sample)
        }
        let apps = memoryApps.map { MemoryHistory.App(key: $0.key, name: $0.name, bytes: $0.bytes, outOfRAM: $0.outOfRAM) }
        memoryHistory.record(m, apps: Array(apps.prefix(MemoryHistory.appsKept)), at: now)
        var found = MemoryAnalysis.insights(points: memoryHistory.since(now.addingTimeInterval(-86_400)), current: m,
                                            uptime: MemoryStatus.uptime(at: now), apps: apps, at: now)
        // Growing apps get a Quit button for the app that is climbing.
        for i in found.indices where found[i].id.hasPrefix("mem-grow-") || found[i].id == "mem-swapowner" {
            let key = found[i].id == "mem-swapowner" ? (memoryApps.max { $0.outOfRAM < $1.outOfRAM }?.key ?? "")
                                                     : String(found[i].id.dropFirst("mem-grow-".count))
            if let m = memoryApps.first(where: { $0.key == key }) {
                let a = Model.isVM(m.key) ? (vmHost() ?? m) : m
                if a.sample.pid != getpid(), Safety.canKillManually(a.sample) {
                    // Out of RAM is mostly swap: a restart frees it and keeps the app.
                    found[i].fixes = found[i].id == "mem-swapowner" && canRestart(a.pids)
                        ? [.restart(pids: a.pids, name: a.name), .quit(pids: a.pids, name: a.name)]
                        : [.quit(pids: a.pids, name: a.name)]
                }
            }
        }
        for i in found.indices where ["mem-thrash", "mem-swapgrow", "mem-pressure24"].contains(found[i].id) {
            found[i] = explainQuit(found[i])
        }
        memoryInsights = found
        applyMemoryRules(now)
    }

    /// The app a memory rule acts on: a virtual machine is quit through the app that runs it.
    func ruleTarget(_ a: MemoryApp) -> MemoryApp { Model.isVM(a.key) ? (vmHost() ?? a) : a }

    /// What a rule counts for an app: its own memory, plus its virtual machine's for a VM host.
    func ruleBytes(_ target: MemoryApp) -> UInt64 {
        let vm = vmHost()?.key == target.key ? (memoryApps.first { Model.isVM($0.key) }?.bytes ?? 0) : 0
        return target.bytes + vm
    }

    func setMemoryRule(_ limit: UInt64?, for a: MemoryApp) {
        let t = ruleTarget(a)
        memoryRules.set(limit.map { MemoryRule(name: t.name, limit: $0) }, for: t.key)
        objectWillChange.send()
    }

    /// Quits, politely, any app over its memory rule for 5 minutes while not in front.
    private func applyMemoryRules(_ now: Date) {
        guard !memoryRules.rules.isEmpty, Model.snapshotDir == nil else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let readings = memoryApps.filter { !Model.isVM($0.key) }.map {
            MemoryRuleWatch.Reading(key: $0.key, bytes: ruleBytes($0), frontmost: front.map($0.pids.contains) ?? false)
        }
        for key in memoryRuleWatch.update(readings, rules: memoryRules.rules, at: now) {
            guard let a = memoryApps.first(where: { $0.key == key }), let rule = memoryRules.rules[key],
                  a.sample.pid != getpid(), Safety.canKillManually(a.sample) else { continue }
            let held = ReportDocument.bytes(ruleBytes(a))
            quit(pids: a.pids, name: a.name)
            sentinel.history.record(.autoKilled, a.sample, detail: "memory rule: held \(held), \(rule.label)", at: now)
            notify(a.sample, title: "Quit \(a.name): it held \(held)",
                   body: "Your rule quits it when it holds over \(rule.limit >> 30) GB in the background. Change it on the Memory tab.", actions: false)
        }
    }

    /// Energy Impact by app over the last `hours`.
    var retentionDays: Int { HistoryRetention.days(historyDays) }

    /// Points every timeline at the kept span. A shorter one trims the oldest as each next records.
    func applyRetention() {
        let days = retentionDays
        memoryHistory.retain = Double(days) * 86_400
        powerHistory.retain = Double(days) * 86_400
        energyUsage.retainHours = days * 24
        sentinel.dailyUsage.retainHours = days * 24
    }

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
        content.threadIdentifier = "reports"
        Snooze.post(UNNotificationRequest(identifier: "weekly-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil))
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
        content.threadIdentifier = "awake"
        Snooze.post(UNNotificationRequest(identifier: "blocker-\(SleepBlockers.reportKey(first))", content: content, trigger: nil))
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
            content.threadIdentifier = "heat"
            // A new heat warning replaces the last rather than piling up.
            Snooze.post(UNNotificationRequest(identifier: "heat", content: content, trigger: nil))
            return
        }
        notify(s, title: title, body: body + " Most likely: \(s.displayName), at \(Fmt.cpu(sentinel.cpuHistory.average(s.pid, over: 60, at: now))) of the Mac's CPU.", actions: true)
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
        // Padded with figure spaces to three digits: a label that changes width makes macOS
        // lay the menu bar out again, and on a full bar with a notch that can hide the icon.
        case "load":
            let n = String(min(Int(machineLoad), 999))
            return String(repeating: "\u{2007}", count: max(0, 3 - n.count)) + n + "%"
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
        case .restart(let pids, let name):
            restart(pids: pids, name: name)
        case .kill(let pids, let label):
            let targets = pids.compactMap(sample(pid:))
            startImpact(label, pids: pids)
            for s in targets { kill(s) }
            lastAction = "\(label): \(targets.count) stopped"
            // A service stopped from Checkup's network finding: check again once it has gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { self.checkup.refreshExposure() }
        case .lowPowerMode:
            let front = frontWindowNumber()
            Task.detached {
                // osascript, so the admin prompt runs off the main thread.
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", "do shell script \"/usr/bin/pmset -a lowpowermode 1\" with administrator privileges"]
                task.standardError = FileHandle.nullDevice
                let ok = (try? task.run()) != nil && { task.waitUntilExit(); return task.terminationStatus == 0 }()
                await MainActor.run {
                    comeBack(to: front)
                    self.showToast(Toast(ok: ok, title: ok ? "Low Power Mode is on" : "Low Power Mode was not changed",
                                         detail: ok ? nil : "The password prompt was cancelled or refused."))
                    self.tick()
                }
            }
        case .openSettings(let s):
            if let url = URL(string: s.url) { NSWorkspace.shared.open(url) }
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .emptyTrash:
            let size = storage.found.places["trash"].map { " Frees about \(ReportDocument.bytes($0))." } ?? ""
            StorageStore.confirm("Empty the Trash?", "Everything in the Trash is deleted for good." + size, button: "Empty Trash") {
                self.storage.emptyTrash()
            }
        case .cleanPlaces(let keys):
            let places = keys.compactMap(StoragePlace.named).filter { $0.clean != nil }
            let bytes = places.reduce(UInt64(0)) { $0 + (storage.found.places[$1.key] ?? 0) }
            let names = places.map(\.name).joined(separator: ", ")
            StorageStore.confirm("Clean \(names)?", "These are rebuilt or downloaded again when needed. Frees about \(ReportDocument.bytes(bytes)).", button: "Clean") {
                places.forEach(self.storage.clean)
            }
        case .trashFound(let kind, _):
            let items = StorageAnalysis.items(kind, in: storage.found, at: Date())
            guard !items.isEmpty else { return }
            let bytes = items.reduce(UInt64(0)) { $0 + $1.bytes }
            let names = items.prefix(4).map(\.name).joined(separator: ", ") + (items.count > 4 ? " and \(items.count - 4) more" : "")
            StorageStore.confirm("Move \(items.count) item\(items.count == 1 ? "" : "s") to the Trash?",
                                    "\(ReportDocument.bytes(bytes)): \(names). You can put them back until the Trash is emptied.", button: "Move to Trash") {
                self.storage.moveToTrash(items, key: "insight-\(kind.rawValue)")
            }
        case .archiveFound(let kind, _):
            let items = StorageAnalysis.items(kind, in: storage.found, at: Date())
            if !items.isEmpty { storage.archive(items, key: "insight-\(kind.rawValue)") }
        case .review(let card, _):
            focus = card
        case .openURL(let url, _):
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .leaveHotspot:
            network.leaveHotspot()
        case .goTo(let tab, let card, _):
            goTab = tab
            if let card { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.focus = card } }
        case .copy(let text, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .optimiseScreen:
            OptimiseWindow.show(self)
        case .openApp(let id, _):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
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
        // A quit nothing can receive (a VM's process, a system service) should say so, not claim success.
        let refused = loose.filter { !Safety.canKillManually($0) }
        if apps.isEmpty, !loose.isEmpty, refused.count == loose.count {
            showToast(Toast(ok: false, title: "\(name) cannot be asked to quit", detail: "Use Force Quit, or quit the app that started it."))
            return
        }
        showToast(Toast(ok: true, title: "Asked \(name) to quit", detail: "The result, in power and CPU, follows in a minute. If it is still here, use Force Quit."))
    }

    /// The running apps behind these pids, the way Quit finds them.
    private func runningApps(_ pids: [Int32]) -> [NSRunningApplication] {
        var out: [NSRunningApplication] = []
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil, app.activationPolicy != .prohibited {
                out.append(app)
            } else if let s = sample(pid: pid), let bundle = AppIdentity.bundlePath(of: s.path),
                      let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == bundle }) {
                out.append(app)
            }
        }
        var seen = Set<pid_t>()
        return out.filter { seen.insert($0.processIdentifier).inserted }
    }

    /// Only a real app with a bundle can be opened again.
    func canRestart(_ pids: [Int32]) -> Bool { runningApps(pids).contains { $0.bundleURL != nil } }

    /// Quits the app the normal way, waits up to 30 s for it to go, opens it again and says
    /// how much swap came back. The only way to free an app's swap short of a restart.
    func restart(pids: [Int32], name: String) {
        let apps = runningApps(pids)
        guard let url = apps.first(where: { $0.activationPolicy == .regular })?.bundleURL ?? apps.first?.bundleURL else {
            quit(pids: pids, name: name)
            return
        }
        let before = MemoryStatus.read()?.swapUsed
        for app in apps { app.terminate() }
        showToast(Toast(ok: true, title: "Restarting \(name)…", detail: "Asked it to quit the normal way; it opens again once it has gone."))
        Task { @MainActor in
            for _ in 0..<60 where apps.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !apps.contains(where: { !$0.isTerminated }) else {
                self.showToast(Toast(ok: false, title: "\(name) did not quit", detail: "It may be asking to save something. Answer it, or use Force Quit, then open it again."))
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            try? await Task.sleep(for: .seconds(5))
            let after = MemoryStatus.read()?.swapUsed
            var detail = "Opened again."
            if let b = before, let a = after {
                detail = b > a ? "Swap went from \(ReportDocument.bytes(b)) to \(ReportDocument.bytes(a)): \(ReportDocument.bytes(b - a)) back."
                               : "Swap is \(ReportDocument.bytes(a)). macOS can take a minute to hand it back."
            }
            self.showToast(Toast(ok: true, title: "Restarted \(name)", detail: detail))
            self.tick()
        }
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
            "- \(r.sample.name) (pid \(r.sample.pid)): \(Int(r.sample.cpu))% of one core now, 15 min average \(Int(average(r.sample, 900)))%\(r.parent.map { ", started by \($0)" } ?? ""), path \(r.sample.path)"
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
        CPU now: \(Int(s.cpu))% of one core (\(Fmt.cpu(s.cpu)) of the Mac)
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
        totalAverage(window, at: Date()) / max(cores, 1)
    }

    /// Total CPU (100 = one core) over `window`: the live history, and before it the saved
    /// per-minute store, so the averages mean something straight after a relaunch.
    func totalAverage(_ window: TimeInterval, at now: Date) -> Double {
        let hist = sentinel.cpuHistory
        let live = min(hist.recorded(at: now), window)
        let saved = live < window
            ? sentinel.recentUsage.total(from: now.addingTimeInterval(-window), to: now.addingTimeInterval(-live))
            : (coreSeconds: 0, seconds: 0)
        let seconds = live + saved.seconds
        guard seconds > 0 else { return 0 }
        return (hist.totalAverage(over: live, at: now) * live + saved.coreSeconds * 100) / seconds
    }

    /// Minutes of the last hour with data, live or saved.
    func coveredMinutes(at now: Date) -> Double {
        let live = min(sentinel.cpuHistory.recorded(at: now), 3600)
        return (live + sentinel.recentUsage.total(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(-live)).seconds) / 60
    }

    func average(_ s: ProcessSample, _ window: TimeInterval) -> Double {
        sentinel.cpuHistory.average(s.pid, over: window, at: Date())
    }

    func sparkline(_ s: ProcessSample, minutes: Double = 15, buckets: Int = 30) -> [Double] {
        sentinel.cpuHistory.sparkline(s.pid, over: minutes * 60, buckets: buckets, at: Date())
    }

    var recordedMinutes: Double { coveredMinutes(at: Date()) }

    static func appKey(_ path: String) -> String { AppIdentity.groupKey(of: path) }

    /// App names for the Memory tab, where a bare Virtualization process needs explaining.
    static func memoryName(_ key: String) -> String {
        key.hasSuffix("com.apple.Virtualization.VirtualMachine") || key.contains("com.apple.Virtualization.VirtualMachine.xpc")
            ? "Virtual machine (Docker, Rancher, UTM…)" : appName(key)
    }

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
            total1m: totalAverage(60, at: now), total15m: totalAverage(900, at: now),
            total60m: totalAverage(3600, at: now), avg15m: avg15,
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
        input.gpuApps = gpuInsightApps()
        input.gpuMinutes = gpuAppLog.first.map { now.timeIntervalSince($0.at) / 60 } ?? 0
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

    /// The first IODisplayParameters in the registry that knows its brightness in nits: the
    /// built-in panel. External screens do not report it.
    static func readScreenLight() -> ScreenLight? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let p = IORegistryEntrySearchCFProperty(root, kIOServicePlane, "IODisplayParameters" as CFString, nil,
                                                      IOOptionBits(kIORegistryIterateRecursively)) as? [String: Any] else { return nil }
        return ScreenLight.parse(p)
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
    @Published var purging = false

    /// Stops a launch agent or daemon and moves its plist to the Trash.
    func removeBackgroundItem(_ item: BackgroundItem) {
        let cmd = BackgroundItems.removeCommand(item, uid: getuid(), trash: NSString(string: "~/.Trash").expandingTildeInPath)
        let front = frontWindowNumber()
        Task.detached {
            let task = Process()
            if item.scope == .user {
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", cmd]
            } else {
                let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            }
            task.standardError = FileHandle.nullDevice
            let ok = (try? task.run()) != nil && { task.waitUntilExit(); return task.terminationStatus == 0 }()
            let gone = !FileManager.default.fileExists(atPath: item.plist)
            await MainActor.run {
                comeBack(to: front)
                self.backgroundItems = BackgroundItems.scan()
                if ok && gone {
                    self.showToast(Toast(ok: true, title: "Removed \(item.name)",
                                         detail: "Stopped, and its file is in the Trash. Put it back from the Trash to undo, then log out and in."))
                } else {
                    self.showToast(Toast(ok: false, title: "\(item.name) was not removed",
                                         detail: item.scope == .user ? "Its file could not be moved." : "The password prompt was cancelled or refused."))
                }
            }
        }
    }

    /// `purge`: drops cached files from memory (admin password). It does not touch app memory
    /// or swap, so the toast reports what it actually changed.
    func purgeCaches() {
        guard !purging else { return }
        purging = true
        let before = MemoryStatus.read()
        let front = frontWindowNumber()
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
            task.standardError = FileHandle.nullDevice
            let ok = (try? task.run()) != nil && { task.waitUntilExit(); return task.terminationStatus == 0 }()
            let after = MemoryStatus.read()
            await MainActor.run {
                comeBack(to: front)
                self.purging = false
                if ok, let b = before, let a = after {
                    let freed = a.free > b.free ? a.free - b.free : 0
                    self.showToast(Toast(ok: true, title: "Freed \(ReportDocument.bytes(freed)) of cached files",
                                         detail: "Free memory went from \(ReportDocument.bytes(b.free)) to \(ReportDocument.bytes(a.free)). Swap is \(ReportDocument.bytes(a.swapUsed)); only quitting apps or restarting lowers it."))
                } else {
                    self.showToast(Toast(ok: false, title: "Nothing was purged", detail: "The password prompt was cancelled or refused."))
                }
                self.tick()
            }
        }
    }

    /// macOS's own Restart dialog, which asks first and lets apps save.
    func askToRestart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"loginwindow\" to «event aevtrrst»"]
        try? task.run()
    }

    /// The largest app that can be quit: what quitting it gives back, why it is that big, and
    /// a Quit for all of its processes rather than one.
    func explainQuit(_ insight: Insight) -> Insight {
        var x = insight
        let quittable = memoryApps.filter { a in
            let t = Model.isVM(a.key) ? (vmHost() ?? a) : a
            return t.sample.pid != getpid() && Safety.canKillManually(t.sample)
        }
        x.related = memoryApps.prefix(4).map { a in
            let inRAM = a.bytes > a.outOfRAM ? a.bytes - a.outOfRAM : 0
            var r = Insight.Related(sample: a.sample, about: "\(a.pids.count > 1 ? "All \(a.pids.count) processes: " : "")\(gb(inRAM)) in RAM, \(gb(a.outOfRAM)) compressed or in swap", parent: nil)
            r.memoryBytes = a.bytes
            r.title = a.name
            if a.pids.count > 1 { r.pids = a.pids }
            return r
        }
        guard let a = quittable.first else { return x }
        let target = Model.isVM(a.key) ? (vmHost() ?? a) : a
        let inRAM = a.bytes > a.outOfRAM ? a.bytes - a.outOfRAM : 0
        let procs = a.pids.count > 1 ? " across \(a.pids.count) processes" : ""
        let running = started(a.pids).map { ", running \(MemoryLargestAge.age($0))" } ?? ""
        x.detail += " Quitting \(target.name) gives back about \(gb(a.bytes))\(procs): \(gb(inRAM)) of RAM and \(gb(a.outOfRAM)) that is compressed or in swap\(running)."
        x.about = "Why \(a.name) is so big: " + memoryAbout(a)
        x.fixes = [.quit(pids: target.pids, name: target.name)]
        return x
    }

    private func gb(_ b: UInt64) -> String { ReportDocument.bytes(b) }

    private func readClusters(_ now: Date) {
        var next: [Int32: ClusterTime] = [:]
        var e: [String: (cpu: Double, top: ProcessSample, topCPU: Double)] = [:], p = e
        let seconds = clusterTimesAt.map { now.timeIntervalSince($0) } ?? 0
        for s in sentinel.latest {
            guard let t = ClusterTime.read(s.pid) else { continue }
            next[s.pid] = t
            guard let before = clusterTimes[s.pid], let u = ClusterTime.usage(from: before, to: t, seconds: seconds) else { continue }
            let k = Model.appKey(s.path)
            for (v, isP) in [(u.efficiency, false), (u.performance, true)] where v > 0 {
                var g = (isP ? p[k] : e[k]) ?? (0, s, 0)
                g.cpu += v
                if v > g.topCPU { g.top = s; g.topCPU = v }
                if isP { p[k] = g } else { e[k] = g }
            }
        }
        clusterTimes = next
        clusterTimesAt = now
        let names = Dictionary(memoryApps.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        let list = { (d: [String: (cpu: Double, top: ProcessSample, topCPU: Double)]) in
            d.map { g in ClusterApp(key: g.key, name: names[g.key] ?? Model.memoryName(g.key), sample: g.value.top, cpu: g.value.cpu) }
                .filter { $0.cpu >= 0.5 }.sorted { $0.cpu > $1.cpu }.prefix(6).map { $0 }
        }
        if seconds > 0 { clusterApps = (list(e), list(p)) }
    }

    private func readGPU(_ now: Date) {
        let before = gpuStatus?.gpuTime ?? [:]
        let seconds = gpuTimesAt.map { now.timeIntervalSince($0) } ?? 0
        guard let s = GPUReader.read() else { gpu = GPUReader.utilization(); return }
        gpuStatus = s
        gpuTimesAt = now
        gpu = s.busy
        gpuHistory.append((now, s.busy))
        gpuHistory.removeAll { now.timeIntervalSince($0.at) > 3600 }
        guard seconds > 0 else { return }
        // Grouped by app, as on the Memory tab: Chrome's GPU helper counts as Chrome.
        let samples = Dictionary(sentinel.latest.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var apps: [String: (share: Double, top: ProcessSample, topShare: Double)] = [:]
        let shares = GPUReader.shares(from: before, to: s.gpuTime, seconds: seconds)
        gpuShares = shares
        var pids: [String: [Int32]] = [:]
        for (pid, v) in shares {
            // A process that started since the last `ps` reading is known by the name it gave the driver.
            let sample = samples[pid] ?? ProcessSample(pid: pid, uid: 0, cpu: 0, path: s.names[pid] ?? "pid \(pid)")
            let k = Model.appKey(sample.path)
            pids[k, default: []].append(pid)
            var g = apps[k] ?? (0, sample, 0)
            g.share += v
            if v > g.topShare { g.top = sample; g.topShare = v }
            apps[k] = g
        }
        gpuAppLog.append((now, apps.mapValues { min($0.share, 100) }))
        gpuAppLog.removeAll { now.timeIntervalSince($0.at) > 300 }
        gpuAppPIDs.merge(pids) { _, new in new }
        let names = Dictionary(memoryApps.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        gpuApps = apps.map { ClusterApp(key: $0.key, name: names[$0.key] ?? Model.memoryName($0.key), sample: $0.value.top, cpu: min($0.value.share, 100)) }
            .filter { $0.cpu >= 0.5 }.sorted { $0.cpu > $1.cpu }.prefix(6).map { $0 }
    }

    /// Apps using the graphics chip, averaged over the last 5 minutes, for the insights.
    /// Ways to make the graphics chip draw less, for the Graphics card.
    func gpuSavings() -> [GPUSaving] {
        GPUSavings.list(apps: gpuInsightApps(), busy: gpuAverage(300) ?? gpuStatus?.busy ?? 0,
                        onBattery: battery?.onBattery ?? false, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        byPID: Dictionary(sentinel.latest.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    func gpuInsightApps() -> [GPUApp] {
        guard !gpuAppLog.isEmpty else { return [] }
        var sum: [String: Double] = [:]
        for e in gpuAppLog { for (k, v) in e.shares { sum[k, default: 0] += v } }
        let front = NSWorkspace.shared.frontmostApplication.flatMap { app in
            sentinel.latest.first { $0.pid == app.processIdentifier }.map { Model.appKey($0.path) }
        }
        let live = Set(sentinel.latest.map(\.pid))
        let names = Dictionary(memoryApps.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        return sum.map { k, v in
            GPUApp(key: k, name: names[k] ?? Model.memoryName(k), share: v / Double(gpuAppLog.count),
                   pids: (gpuAppPIDs[k] ?? []).filter(live.contains), front: k == front)
        }
        .filter { $0.share >= 5 }.sorted { $0.share > $1.share }
    }

    /// Average graphics watts over the last `seconds`.
    func gpuWattsAverage(_ seconds: TimeInterval) -> Double? {
        let now = Date()
        let recent = gpuWattsHistory.filter { now.timeIntervalSince($0.at) <= seconds }
        return recent.isEmpty ? nil : recent.map(\.watts).reduce(0, +) / Double(recent.count)
    }

    /// Average graphics busy share over the last `seconds`.
    func gpuAverage(_ seconds: TimeInterval) -> Double? {
        let now = Date()
        let recent = gpuHistory.filter { now.timeIntervalSince($0.at) <= seconds }
        return recent.isEmpty ? nil : recent.map(\.busy).reduce(0, +) / Double(recent.count)
    }

    func batteryETA() -> BatteryETA? {
        battery.flatMap { BatteryETA.of($0, lastHour: powerHistory.since(Date().addingTimeInterval(-3600))) }
    }

    /// Minutes until the battery is empty: on battery, or plugged into a charger that has not
    /// kept up over the last hour.
    func minutesToEmpty() -> Int? {
        guard let b = battery else { return nil }
        return b.onBattery ? batteryETA()?.minutes : powerOutlook?.minutesLeftOnPower
    }

    /// A notification at 20 minutes of battery left, and again at 5.
    private func checkLowBattery(_ now: Date) {
        guard let b = battery, b.present, Model.snapshotDir == nil else { return }
        let left = minutesToEmpty()
        guard let level = lowBattery.update(minutesLeft: left, draining: b.onBattery || left != nil), let m = left else { return }
        let content = UNMutableNotificationContent()
        content.title = level <= 5 ? "Battery almost empty: \(max(m, 1)) min left" : "Battery low: about \(m) min left"
        let fix = b.onBattery ? "Plug in the charger" : "This charger cannot keep up. Use a bigger one or quit something heavy"
        content.body = "\(b.percent)%, empty around \(BatteryETABanner.clock(m)). " + (level <= 5 ? "Save your work now. \(fix)." : "\(fix).")
        content.sound = .default
        content.categoryIdentifier = "info"
        content.threadIdentifier = "battery"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "low-battery-\(level)", content: content, trigger: nil))
    }

    /// When the oldest of these processes started.
    func started(_ pids: [Int32]) -> Date? {
        pids.compactMap { pid -> Date? in
            if startTimes[pid] == nil { startTimes[pid] = ProcessSampler.startTime(of: pid) }
            return startTimes[pid]
        }.min()
    }

    static let vmHosts = ["Rancher Desktop", "Docker", "Docker Desktop", "OrbStack", "UTM", "Parallels Desktop", "VMware Fusion", "Podman Desktop", "Lima", "colima", "limactl"]

    static func isVM(_ key: String) -> Bool { key.contains("com.apple.Virtualization.VirtualMachine") }

    /// The running app that owns a virtual machine, so the VM row can name it and quit it.
    func vmHost() -> MemoryApp? {
        // Whole names only: "UTM" is inside "TextInputMenuAgent".
        memoryApps.first { a in
            !Model.isVM(a.key) && Model.vmHosts.contains { h in
                a.name.caseInsensitiveCompare(h) == .orderedSame || a.name.lowercased().hasPrefix(h.lowercased() + " ")
            }
        }
    }

    /// What an app on the Memory tab is and what quitting it does, before anyone quits it.
    func memoryAbout(_ a: MemoryApp) -> String {
        if Model.isVM(a.key) {
            let host = vmHost().map { "It belongs to \($0.name): Quit here quits \($0.name), which shuts the VM down cleanly. " } ?? ""
            return "A Linux virtual machine, as used by Docker, Rancher Desktop, OrbStack, UTM or Parallels. \(host)It holds memory for everything inside it (containers, a guest system) and rarely hands it back while it runs. Quitting the app that runs it frees all of it, but stops its containers."
        }
        let browsers = ["Google Chrome", "Chrome tabs", "Safari", "Firefox", "Microsoft Edge", "Brave Browser", "Arc", "Opera"]
        if browsers.contains(a.name) {
            let base = "Your web browser. Every tab, extension and video is its own process, so memory grows with open tabs. Closing tabs you do not need frees memory without quitting; quitting closes every window."
            if ["Google Chrome", "Chrome tabs", "Microsoft Edge", "Brave Browser"].contains(a.name) {
                return base + " To make it lighter: Settings, Performance, turn on Memory Saver and pick Maximum, so tabs you are not using give their memory back. In Settings, System, turn off \"Continue running background apps\" when it is closed. Remove extensions you do not use: each one runs all the time."
            }
            return base
        }
        if AppIdentity.bundlePath(of: a.sample.path) != nil, !a.sample.path.hasPrefix("/System/") {
            let helpers = a.pids.count > 1 ? " with \(a.pids.count - 1) helper processes" : ""
            return "The \(a.name) app\(helpers). Quitting it closes its windows; it asks to save anything unsaved."
        }
        return ProcessGuide.about(name: a.sample.name, path: a.sample.path)
    }

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

    /// Stops caffeinate processes so the Mac can sleep. Only caffeinate itself goes: whatever
    /// it was started for (a build, an agent session) keeps running.
    func decaffeinate(_ targets: [ProcessSample]) {
        let list = targets.filter { $0.name == "caffeinate" && !killing.contains($0.pid) }
        guard !list.isEmpty else { return }
        for t in list { killing.insert(t.pid) }
        Task.detached {
            let outcomes = list.map { Killer.kill($0) }
            await MainActor.run {
                let stopped = zip(list, outcomes).filter { [.terminated, .forceKilled, .alreadyGone].contains($0.1) }.map(\.0)
                for t in list { self.killing.remove(t.pid) }
                for t in stopped { self.sentinel.history.record(.killed, t, detail: "decaffeinated") }
                let gone = Set(stopped.map(\.pid))
                self.blockers.removeAll { gone.contains($0.pid) }
                self.lastEnergy = nil // read the sleep holds again on the next tick
                self.showToast(Toast(ok: stopped.count == list.count,
                                     title: stopped.count == list.count ? "Stopped \(list.count) caffeinate\(list.count == 1 ? "" : "s"): the Mac can sleep"
                                                                        : "Stopped \(stopped.count) of \(list.count) caffeinates",
                                     detail: "What they were keeping awake carries on running."))
                self.tick()
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

    /// Force Quit for a whole app: SIGKILL to every process at once, no chance to save. One
    /// toast for the lot, saying how much memory came back.
    func forceQuit(pids: [Int32], name: String) {
        let targets = pids.compactMap(sample(pid:)).filter { $0.pid != getpid() }
        guard !targets.isEmpty else { return }
        let before = MemoryStatus.read()
        startImpact(name, pids: pids)
        for t in targets { killing.insert(t.pid) }
        Task.detached {
            let outcomes: [KillOutcome] = targets.map { Killer.forceKill($0) }
            let gone: Int = outcomes.filter { $0 == .forceKilled || $0 == .alreadyGone }.count
            let after = MemoryStatus.read()
            await MainActor.run {
                for t in targets {
                    self.killing.remove(t.pid)
                    self.sentinel.history.record(Killer.isAlive(t.pid) ? .killFailed : .killed, t, detail: "force quit \(name)")
                }
                var detail: String?
                if let b = before, let a = after, b.used > a.used {
                    detail = "About \(ReportDocument.bytes(b.used - a.used)) of memory came back so far."
                }
                let ok = gone == targets.count
                let title = ok ? "Force quit \(name)" : "\(name): \(gone) of \(targets.count) processes stopped"
                self.showToast(Toast(ok: ok, title: title, detail: detail))
                self.tick()
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
            return "It is still running. Right-click it and choose Force kill, or use Force kill in its finding on Checkup."
        }
        return nil
    }

    /// Each tick: Terminal kills that have now exited, and killed programs that came back.
    /// ChatGPT's computer-use helper screenshots the screen even while ChatGPT sits unused.
    /// After 15 minutes without ChatGPT in front, stop it once; ChatGPT starts it again when used.
    private func stopIdleScreenHelperIfNeeded(_ now: Date) {
        guard stopIdleScreenHelper, Model.snapshotDir == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier?.hasPrefix("com.openai.") == true || front.localizedName == "ChatGPT" {
            chatGPTInFront = now
            return
        }
        guard now.timeIntervalSince(chatGPTInFront) >= 15 * 60,
              helperStopped.map({ $0 < chatGPTInFront }) ?? true,
              let s = sentinel.latest.first(where: { $0.name == "SkyComputerUseService" }) else { return }
        helperStopped = now
        Task.detached {
            guard Killer.isSameProcess(s) else { return }
            let outcome = Killer.kill(s)
            guard outcome == .terminated || outcome == .forceKilled else { return }
            await MainActor.run {
                self.sentinel.history.record(.killed, s, detail: "ChatGPT unused for 15 minutes; it starts again when you use ChatGPT")
                self.lastAction = "Stopped ChatGPT's screen helper: ChatGPT unused for 15 minutes"
            }
        }
    }

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
        if !t.ok { Diagnostics.report("action", t.title + (t.detail.map { ": " + $0 } ?? "")) }
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
                ? "Allow System Sentinel to control Terminal in System Settings > Privacy & Security > Automation."
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
            notify(s, title: "\(s.displayName) is using \(Fmt.cpu(s.cpu)) of the Mac",
                   body: "Over \(Fmt.cpu(threshold)) for \(Self.duration(windowSeconds)). \(s.isRoot ? "Runs as root: Kill asks for your password." : "")",
                   actions: true)
        case .autoKillWithheld(let s, let reason):
            flagged.insert(s.pid)
            notify(s, title: "\(s.displayName) is using \(Fmt.cpu(s.cpu)) of the Mac",
                   body: "Not auto-killed: \(reason).", actions: true)
        case .autoKilled(let s, let outcome):
            notify(s, title: "Auto-killed \(s.displayName)",
                   body: "It was using \(Fmt.cpu(s.cpu)) of the Mac. \(Self.describe(outcome)).", actions: false)
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
        // Stacked by app in Notification Centre, so a busy day reads as a few groups.
        content.threadIdentifier = "app-" + Model.appKey(s.path)
        Snooze.post(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { done() }
            if id.hasPrefix("update-") || id.hasPrefix("alarm-") { PopOut.show(self); return }
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

    /// Asking SMAppService is a round trip to launchd; the Settings tab read it many times a
    /// redraw and hung for seconds. Read once, then kept in step with what we set.
    private var loginStatus: Bool?
    var launchAtLogin: Bool {
        get {
            if let s = loginStatus { return s }
            let s = SMAppService.mainApp.status == .enabled
            loginStatus = s
            return s
        }
        set {
            defer { loginStatus = nil }
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}

// MARK: Saving on quit

extension Model {
    /// The stores write every few minutes; without this a quit or an update loses the minutes
    /// since the last write, which shows as a hole in the charts.
    func saveAll() {
        sentinel.dailyUsage.save()
        sentinel.recentUsage.save()
        energyUsage.save()
        powerHistory.save()
        memoryHistory.save()
        storage.history.save()
    }

    /// Quit from the menu, logout and restart arrive as willTerminate; an installer or `kill`
    /// sends SIGTERM, which otherwise ends the app on the spot.
    /// Written by an install just before it quits the app; read at the next launch.
    nonisolated static var updateMarker: URL { supportDir.appendingPathComponent("update-pending") }

    /// At launch: a new build since last time says so, so a restart is never a mystery.
    func announceUpdate() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let last = UserDefaults.standard.string(forKey: "lastLaunchedBuild")
        let marked = FileManager.default.fileExists(atPath: Model.updateMarker.path)
        try? FileManager.default.removeItem(at: Model.updateMarker)
        UserDefaults.standard.set(build, forKey: "lastLaunchedBuild")
        guard marked || (last != nil && last != build) else { return }
        let note = UNMutableNotificationContent()
        note.title = "System Sentinel \(Model.appVersion) is running"
        note.body = last == build ? "Restarted with a fresh build. Monitoring carried on where it left off."
                                  : "Updated and restarted (build \(build)). Monitoring carried on where it left off."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "updated-\(build)", content: note, trigger: nil))
    }

    func saveOnQuit() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Model.current?.saveAll(); Model.crashMarker.cleanExit() }
        }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { Model.current?.saveAll() }
            Model.crashMarker.cleanExit()
            // An install asked us to quit (it leaves a marker): say so from the app itself, which
            // macOS shows reliably, unlike a script's notification.
            guard FileManager.default.fileExists(atPath: Model.updateMarker.path) else { exit(0) }
            let note = UNMutableNotificationContent()
            note.title = "System Sentinel"
            note.subtitle = "Restarting to update"
            note.body = "Installing a new version. Back in a few seconds."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "restarting", content: note, trigger: nil)) { _ in exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        }
        source.resume()
        Model.termSource = source
    }
}

// MARK: Hangs and waits

extension Model {
    /// What a process is held up by, for the Processes rows. nil when it is idle.
    func waitReason(_ s: ProcessSample) -> WaitReason? {
        let io = ioRates[s.pid]
        let tight = (memory?.pressure ?? .normal) >= .warning
        return WaitReason.of(cpu: s.cpu, state: s.state, diskPerSec: io?.disk ?? 0, netPerSec: io?.net ?? 0, memoryTight: tight)
    }

    /// Why things were slow at this moment: the app's own wait, then the Mac as a whole.
    func hangReason(pid: Int32?) -> String {
        var parts: [String] = []
        if let pid, let s = sample(pid: pid), let w = waitReason(s) {
            parts.append(w == .cpu ? "It was busy on CPU (\(Fmt.cpu(s.cpu)))" : "It was \(w.label.lowercased())")
        }
        if machineLoad >= 80 { parts.append("the Mac was \(Int(machineLoad))% busy") }
        if let m = memory {
            if m.pressure >= .warning { parts.append("memory pressure was \(m.pressure == .critical ? "critical" : "high")") }
            if m.swapUsed >= 2 << 30 { parts.append("the Mac had \(ReportDocument.bytes(m.swapUsed)) in swap") }
        }
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { parts.append("the Mac was hot and slowed down") }
        guard !parts.isEmpty else { return "No sign of CPU, memory or disk trouble: the app itself was stuck." }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    func recordOwnHang(start: Date, seconds: Double, doing: String?) {
        let what = doing.map { "Stuck \($0). " } ?? "Stuck drawing the window. "
        addHang(Hang(app: "System Sentinel", start: start, seconds: seconds, reason: what + hangReason(pid: nil), own: true))
    }

    func updateHangs(_ hung: [Int32: String]) {
        let now = Date()
        for h in hangTracker.update(hung: hung, at: now, reason: { self.hangReason(pid: $0) }) { addHang(h) }
        guard alertHangs, Model.snapshotDir == nil else { return }
        for d in hangTracker.due(after: 10, at: now) {
            let content = UNMutableNotificationContent()
            content.title = "\(d.open.name) is not responding"
            content.body = d.open.reason + " The Events tab lists every hang."
            content.categoryIdentifier = "info"
            content.threadIdentifier = "hang"
            Snooze.post(UNNotificationRequest(identifier: "hang-\(d.pid)-\(Int(d.open.since.timeIntervalSince1970))", content: content, trigger: nil))
        }
    }

    private func addHang(_ h: Hang) {
        hangs.insert(h, at: 0)
        if hangs.count > 50 { hangs.removeLast(hangs.count - 50) }
        if let data = try? JSONEncoder().encode(hangs) { UserDefaults.standard.set(data, forKey: "hangs.v1") }
    }

    static func loadHangs() -> [Hang] {
        guard let data = UserDefaults.standard.data(forKey: "hangs.v1") else { return [] }
        return (try? JSONDecoder().decode([Hang].self, from: data)) ?? []
    }
}

/// The window in front before an admin password prompt. The prompt belongs to osascript, and
/// when it closes macOS hands the focus to whatever app was behind, not back to us.
@MainActor func frontWindowNumber() -> Int? { (NSApp.keyWindow ?? NSApp.mainWindow)?.windowNumber }

/// Brings System Sentinel and that window back to the front after the prompt.
@MainActor func comeBack(to window: Int?) {
    NSApp.activate(ignoringOtherApps: true)
    if let n = window, let w = NSApp.window(withWindowNumber: n) { w.makeKeyAndOrderFront(nil) }
}
