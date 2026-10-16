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

    let sentinel: Sentinel
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    private var timer: Timer?
    /// Processes named in a pending notification, so its Kill button acts on the right one.
    private var pending: [String: ProcessSample] = [:]
    private var startTimes: [Int32: Date] = [:]

    @AppStorage("threshold") var threshold: Double = 80 { didSet { sentinel.detector.threshold = threshold } }
    @AppStorage("windowSeconds") var windowSeconds: Double = 120 { didSet { sentinel.detector.window = windowSeconds } }

    static let supportDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CPUSentinel", isDirectory: true)

    /// Set by `--snapshot`: render screens to PNG without writing any of the owner's data.
    static let snapshotDir: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }()

    override init() {
        sentinel = Sentinel(
            policies: PolicyStore(fileURL: Model.supportDir.appendingPathComponent("policies.json")),
            history: History(fileURL: Model.snapshotDir == nil ? Model.supportDir.appendingPathComponent("history.jsonl") : nil,
                             seed: Model.snapshotDir == nil ? nil : Model.supportDir.appendingPathComponent("history.jsonl")),
            dailyUsage: DailyUsage(fileURL: Model.supportDir.appendingPathComponent("usage-24h.json"),
                                   readOnly: Model.snapshotDir != nil))
        super.init()
        sentinel.detector.threshold = threshold
        sentinel.detector.window = windowSeconds
        setUpNotifications()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let dir = Model.snapshotDir {
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { Snapshot.run(self, into: dir) }
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
            thermal = ProcessInfo.processInfo.thermalState
            insights = Insights.generate(insightInput())
        } catch {
            lastError = "Could not read processes: \(error)"
        }
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
        return InsightInput(
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
        // The kill blocks (grace period, admin prompt), so it runs off the main thread; the
        // history write stays on it, where every other read and write of the engine happens.
        Task.detached {
            let outcome = Killer.kill(s)
            await MainActor.run {
                let ok = outcome == .terminated || outcome == .forceKilled || outcome == .alreadyGone
                self.sentinel.history.record(ok ? .killed : .killFailed, s, detail: "\(outcome)")
                self.lastAction = "\(s.displayName): \(Self.describe(outcome))"
                self.flagged.remove(s.pid)
                self.tick()
            }
        }
    }

    /// The deliberate override for a protected process: the admin password prompt.
    func killProtected(_ s: ProcessSample) {
        Task.detached {
            let outcome = Killer.killProtectedAsAdmin(s)
            await MainActor.run {
                let ok = outcome == .terminated || outcome == .alreadyGone
                self.sentinel.history.record(ok ? .killed : .killFailed, s, detail: "as admin: \(outcome)")
                self.lastAction = "\(s.displayName): \(Self.describe(outcome))"
                self.tick()
            }
        }
    }

    /// Opens Terminal with the sudo kill typed and run, so the password goes to sudo itself.
    func openSudoShell(_ s: ProcessSample) {
        let cmd = Killer.sudoCommand(for: s).replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            lastError = code == -1743
                ? "Allow CPU Sentinel to control Terminal in System Settings > Privacy & Security > Automation."
                : "Could not open Terminal: \(error[NSAppleScript.errorMessage] ?? error)"
        } else {
            lastAction = "Terminal: \(Killer.sudoCommand(for: s))"
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
