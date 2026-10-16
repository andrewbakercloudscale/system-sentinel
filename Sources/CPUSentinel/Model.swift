import AppKit
import ServiceManagement
import SentinelCore
import SwiftUI
import UserNotifications

/// Holds the engine, runs it on a timer, and turns its events into notifications.
@MainActor
final class Model: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var top: [ProcessSample] = []
    @Published var totalCPU: Double = 0
    @Published var flagged: Set<Int32> = []
    @Published var lastError: String?
    @Published var lastAction: String?

    let sentinel: Sentinel
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    private var timer: Timer?
    /// Processes named in a pending notification, so its Kill button acts on the right one.
    private var pending: [String: ProcessSample] = [:]

    @AppStorage("threshold") var threshold: Double = 80 { didSet { sentinel.detector.threshold = threshold } }
    @AppStorage("windowSeconds") var windowSeconds: Double = 120 { didSet { sentinel.detector.window = windowSeconds } }

    static let supportDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CPUSentinel", isDirectory: true)

    override init() {
        sentinel = Sentinel(
            policies: PolicyStore(fileURL: Model.supportDir.appendingPathComponent("policies.json")),
            history: History(fileURL: Model.supportDir.appendingPathComponent("history.jsonl")),
            dailyUsage: DailyUsage(fileURL: Model.supportDir.appendingPathComponent("usage-24h.json")))
        super.init()
        sentinel.detector.threshold = threshold
        sentinel.detector.window = windowSeconds
        setUpNotifications()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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
            top = sentinel.top(10)
            totalCPU = sentinel.totalCPU
            let live = Set(sentinel.latest.map(\.pid))
            flagged.formIntersection(live)
            // A flagged process that has cooled down is no longer flagged.
            flagged = flagged.filter { sentinel.detector.hotDuration(of: $0, at: Date()) != nil }
            lastError = nil
            for e in events { handle(e) }
        } catch {
            lastError = "Could not read processes: \(error)"
        }
    }

    func hotFor(_ s: ProcessSample) -> String? {
        guard let d = sentinel.detector.hotDuration(of: s.pid, at: Date()), d >= 10 else { return nil }
        return Self.duration(d)
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
