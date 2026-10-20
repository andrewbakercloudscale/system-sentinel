import Foundation

/// What a person says is wrong, in their words. Each one gathers the checks that answer it, so
/// the Checkup tab can start from the problem rather than from a list of settings.
public enum Symptom: String, CaseIterable, Sendable, Identifiable {
    case slow = "Slow or hot"
    case battery = "Battery drains"
    case disk = "Disk full"
    case network = "Wi-Fi or internet"
    case sleep = "Won't sleep"
    case micCamera = "Mic or camera"
    case appWontOpen = "App crashes or won't open"
    case bluetooth = "Bluetooth"
    case icloud = "iCloud stuck"
    case restarts = "Restarted by itself"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .slow: return "tortoise.fill"
        case .battery: return "battery.25percent"
        case .disk: return "internaldrive.fill"
        case .network: return "wifi.exclamationmark"
        case .sleep: return "moon.zzz.fill"
        case .micCamera: return "mic.fill"
        case .appWontOpen: return "xmark.app.fill"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .icloud: return "icloud.slash.fill"
        case .restarts: return "restart.circle.fill"
        }
    }

    /// The question the panel answers, as its heading.
    public var question: String {
        switch self {
        case .slow: return "Is the Mac slow or running hot?"
        case .battery: return "Why does the battery run down?"
        case .disk: return "Is the disk full?"
        case .network: return "Is the Wi-Fi or internet the problem?"
        case .sleep: return "What keeps the Mac awake?"
        case .micCamera: return "Can apps use the microphone and camera?"
        case .appWontOpen: return "Is an app crashing, or being blocked?"
        case .bluetooth: return "Is Bluetooth working?"
        case .icloud: return "Is iCloud syncing?"
        case .restarts: return "Why did the Mac restart?"
        }
    }
}

/// An app and how much of something it uses: percent of a core, bytes or energy impact.
public struct AppLoad: Equatable, Sendable {
    public let name: String
    public let amount: Double
    public let pids: [Int32]
    public init(name: String, amount: Double, pids: [Int32]) { self.name = name; self.amount = amount; self.pids = pids }
}

/// One app's microphone or camera permission, from the privacy database.
public struct PrivacyGrant: Equatable, Sendable {
    public let service: String
    public let bundleID: String
    public var name: String
    public let allowed: Bool
    public init(service: String, bundleID: String, name: String, allowed: Bool) {
        self.service = service; self.bundleID = bundleID; self.name = name; self.allowed = allowed
    }
}

/// An app Gatekeeper will refuse to open: downloaded, never approved, and not passing its check.
public struct BlockedApp: Equatable, Sendable {
    public let name: String
    public let path: String
    public init(name: String, path: String) { self.name = name; self.path = path }
}

public struct BluetoothState: Equatable, Sendable {
    public let on: Bool
    public let connected: [String]
    public init(on: Bool, connected: [String]) { self.on = on; self.connected = connected }
}

/// Everything the symptom checks look at, gathered by the app from what it already measures
/// plus a few probes, so the diagnosis itself is pure and tested.
public struct Vitals: Sendable {
    /// Share of the whole Mac in use over the last minute, 0 to 100.
    public var cpuBusy: Double = 0
    public var pressure: MemoryStatus.Pressure = .normal
    public var swap: UInt64 = 0
    /// `ProcessInfo.ThermalState` raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int = 0
    /// Apps by CPU over the last minute, in percent of one core, busiest first.
    public var busyApps: [AppLoad] = []
    /// Apps by memory, in bytes, largest first.
    public var memoryApps: [AppLoad] = []
    public var battery: BatteryStatus?
    /// Apps by energy impact now, highest first.
    public var energyApps: [AppLoad] = []
    public var disk: DiskSpace?
    /// The checkup's network checks.
    public var networkChecks: [Check] = []
    public var sleep: SleepReport?
    public var blockers: [SleepBlocker] = []
    /// Nil when the privacy database could not be read (it needs Full Disk Access).
    public var privacy: [PrivacyGrant]?
    public var blockedApps: [BlockedApp] = []
    /// Nil until it has been read.
    public var bluetooth: BluetoothState?
    /// bluetoothd, in percent of one core over the last minute.
    public var bluetoothCPU: Double = 0
    /// bird and cloudd together, in percent of one core over the last minute.
    public var syncCPU: Double = 0
    /// The checkup's kernel panic check: the Mac restarting itself.
    public var restartChecks: [Check] = []
    /// The checkup's crash check: one program ending, which is not a restart.
    public var crashChecks: [Check] = []
    /// The newest kernel panic in plain words, when there is one this month.
    public var panic: String?

    public init() {}
}

public enum Diagnose {
    static let gb: UInt64 = 1 << 30

    /// What the Mac shows without being asked: for each symptom with a warning or worse, the
    /// most serious finding. Worst first.
    public static func found(_ v: Vitals, ignoring ignored: Set<String> = []) -> [(symptom: Symptom, check: Check)] {
        // Problems before warnings; within each, in symptom order, so performance comes first.
        Symptom.allCases.enumerated().compactMap { i, s -> (Int, Symptom, Check)? in
            guard let worst = checks(s, v).filter({ !ignored.contains($0.ignoreKey) }).max(by: { $0.status < $1.status }),
                  worst.status >= .warning else { return nil }
            return (i, s, worst)
        }
        .sorted { ($0.2.status, -$0.0) > ($1.2.status, -$1.0) }
        .map { ($0.1, $0.2) }
    }

    /// The checks behind one symptom, worst first. Never empty: when nothing is wrong the last
    /// check says so and lists what to try next.
    public static func checks(_ s: Symptom, _ v: Vitals) -> [Check] {
        let list: [Check]
        switch s {
        case .slow: list = slow(v)
        case .battery: list = battery(v)
        case .disk: list = disk(v)
        case .network: list = network(v)
        case .sleep: list = sleep(v)
        case .micCamera: list = micCamera(v)
        case .appWontOpen: list = appWontOpen(v)
        case .bluetooth: list = bluetooth(v)
        case .icloud: list = icloud(v)
        case .restarts: list = restarts(v)
        }
        return list.enumerated().sorted { ($0.element.status, -$0.offset) > ($1.element.status, -$1.offset) }.map(\.element)
    }

    private static func check(_ s: Symptom, _ n: String, _ title: String, _ status: Check.Status, _ detail: String,
                              why: String? = nil, steps: [String] = [], fixes: [Check.Fix] = [],
                              actions: [FixAction] = [], items: [String] = []) -> Check {
        var c = Check(id: "symptom-\(s.symbol)-\(n)", area: .system, title: title, status: status, detail: detail,
                      why: why, steps: steps, fixes: fixes, items: items)
        c.actions = actions
        return c
    }

    private static func quits(_ apps: [AppLoad], _ n: Int = 3) -> [FixAction] {
        apps.prefix(n).map { .quit(pids: $0.pids, name: $0.name) }
    }

    // MARK: Slow or hot

    static func slow(_ v: Vitals) -> [Check] {
        var out: [Check] = []
        if v.thermal >= 2 {
            out.append(check(.slow, "hot", "Running hot: macOS is slowing the processor to cool it", v.thermal >= 3 ? .problem : .warning,
                             "Everything takes longer until it cools down. The busiest apps below are usually the heat.",
                             steps: ["Quit the busiest app below.", "Keep the vents clear: not on a bed or a lap.", "Unplug a charger on the left side of an Intel MacBook and use the right."],
                             actions: quits(v.busyApps)))
        }
        if v.cpuBusy >= 60 {
            let top = v.busyApps.first
            out.append(check(.slow, "cpu", String(format: "The processor is %.0f%% busy", v.cpuBusy), v.cpuBusy >= 85 ? .problem : .warning,
                             top.map { String(format: "%@ is the busiest, at %.0f%% of a core. Quitting it usually helps most.", $0.name, $0.amount) } ?? "Several apps add up to it.",
                             actions: quits(v.busyApps), items: v.busyApps.prefix(5).map { String(format: "%@: %.0f%% of a core", $0.name, $0.amount) }))
        }
        if v.pressure != .normal || v.swap >= 8 * gb {
            out.append(check(.slow, "memory", v.pressure == .critical ? "Memory is critically short" : "Memory is running short",
                             v.pressure == .critical ? .problem : .warning,
                             "Apps no longer fit in memory, so macOS parks some on the disk (\(bytes(v.swap)) so far). Switching apps then stalls.",
                             actions: quits(v.memoryApps), items: v.memoryApps.prefix(5).map { "\($0.name): \(bytes(UInt64($0.amount)))" }))
        }
        if out.isEmpty {
            out.append(check(.slow, "ok", "No sign of it right now", .ok,
                             String(format: "The processor is %.0f%% busy, memory is %@ and the Mac is cool. If one app feels slow, it is that app.", v.cpuBusy, v.pressure.label.lowercased()),
                             steps: ["Quit and reopen the app that feels slow.", "Restart the Mac if it has been on for weeks."],
                             actions: [.goTo(tab: "Processes", card: nil, label: "See every process")],
                             items: v.busyApps.prefix(3).map { String(format: "%@: %.0f%% of a core", $0.name, $0.amount) }))
        }
        return out
    }

    // MARK: Battery

    static func battery(_ v: Vitals) -> [Check] {
        guard let b = v.battery, b.present else {
            return [check(.battery, "none", "This Mac has no battery", .info, "Nothing to check here.")]
        }
        var out: [Check] = []
        if let c = b.condition, c.lowercased() != "normal" {
            out.append(check(.battery, "condition", "macOS says the battery needs service", .problem,
                             "Its condition is \"\(c)\". A worn battery runs down fast and can shut the Mac off early.",
                             steps: ["Book a battery replacement with Apple or an authorised repairer."],
                             actions: [.openSettings(.battery)]))
        } else if let h = b.health, h < 80 {
            out.append(check(.battery, "health", String(format: "The battery holds %.0f%% of what it did new", h), .warning,
                             "Below 80% it runs down noticeably sooner. That is wear, not something an app is doing\(b.cycleCount.map { ", after \($0) charge cycles" } ?? "").",
                             actions: [.goTo(tab: "Energy", card: nil, label: "Battery details")]))
        }
        if b.onBattery, let w = b.watts, w >= 15 {
            out.append(check(.battery, "draw", String(format: "Drawing %.0f W on battery: it will run down fast", w), w >= 25 ? .problem : .warning,
                             v.energyApps.first.map { "\($0.name) is using the most energy." } ?? "A light load is under 10 W.",
                             actions: quits(v.energyApps) + [.lowPowerMode], items: v.energyApps.prefix(5).map { String(format: "%@: energy impact %.0f", $0.name, $0.amount) }))
        }
        if let s = v.sleep, let loss = s.lossPerHour, loss >= 2 {
            out.append(check(.battery, "asleep", String(format: "Loses %.0f%% an hour while asleep", loss), .warning,
                             "A healthy MacBook loses about 1% an hour asleep. Something is waking it: see Won't sleep.",
                             actions: [.goTo(tab: "Energy", card: nil, label: "Sleep and wakes")]))
        }
        if out.isEmpty {
            out.append(check(.battery, "ok", "Nothing is draining it unusually right now", .ok,
                             (b.health.map { String(format: "The battery holds %.0f%% of new. ", $0) } ?? "") + (b.onBattery ? (b.watts.map { String(format: "Drawing %.0f W.", $0) } ?? "") : "Plugged in now: check again on battery."),
                             steps: ["Watch the Energy tab while on battery: it ranks apps by energy.", "Browsers with many tabs and video calls drain most."],
                             actions: [.goTo(tab: "Energy", card: nil, label: "Open Energy")],
                             items: v.energyApps.prefix(3).map { String(format: "%@: energy impact %.0f", $0.name, $0.amount) }))
        }
        return out
    }

    // MARK: Disk

    static func disk(_ v: Vitals) -> [Check] {
        guard let d = v.disk, d.total > 0 else {
            return [check(.disk, "unknown", "Could not read the disk's free space", .info, "Open the Storage tab to scan it.",
                          actions: [.goTo(tab: "Storage", card: nil, label: "Open Storage")])]
        }
        let free = d.available
        let share = Double(free) / Double(d.total) * 100
        let status: Check.Status = free < 5 * gb ? .problem : (free < 20 * gb || share < 10) ? .warning : .ok
        let title = status == .ok ? "\(bytes(free)) free: plenty of room" : "Only \(bytes(free)) free"
        let detail = status == .ok ? String(format: "%.0f%% of the disk is free.", share)
            : "macOS needs about 20 GB free to update and to swap memory. Below 5 GB apps start failing to save."
        return [check(.disk, "free", title, status, detail,
                      steps: status == .ok ? [] : ["Empty the Trash and clear rebuildable caches.", "Look at what grew this week.", "Move videos and old downloads to a drive."],
                      actions: [.goTo(tab: "Storage", card: status == .ok ? nil : "cleanups", label: status == .ok ? "Open Storage" : "Free up space")])]
    }

    // MARK: Network

    static func network(_ v: Vitals) -> [Check] {
        var out = v.networkChecks.filter { $0.status >= .warning }
        let tools: [Check.Fix] = [.run(label: "Restart Wi-Fi", path: "/bin/sh", args: ["-c", wifiCycle]),
                                  .admin(label: "Flush DNS cache", command: .flushDNS)]
        for i in out.indices { out[i].fixes += tools.filter { t in !out[i].fixes.contains(t) } }
        if out.isEmpty {
            let healthy = v.networkChecks.first { $0.id == "net-internet" }
            out.append(check(.network, "ok", v.networkChecks.isEmpty ? "Not checked yet" : "The connection looks healthy", .ok,
                             healthy?.title ?? "Run the checkup to test the connection.",
                             steps: ["If it drops now and then, run a 15 minute route test on the Network tab: it shows when packets were lost and where.",
                                     "If only one site fails, flush the DNS cache."],
                             fixes: tools, actions: [.goTo(tab: "Network", card: nil, label: "Route test")]))
        }
        return out
    }

    /// Finds the Wi-Fi interface (en0 on most Macs, not all) and turns it off and on.
    public static let wifiCycle = """
        d=$(/usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '/Wi-Fi|AirPort/{getline; print $2; exit}'); \
        [ -n "$d" ] && /usr/sbin/networksetup -setairportpower "$d" off && /bin/sleep 2 && /usr/sbin/networksetup -setairportpower "$d" on
        """

    // MARK: Sleep

    static func sleep(_ v: Vitals) -> [Check] {
        var out: [Check] = []
        // The app behind each block: caffeinate and runningboardd hold them on behalf of another.
        // macOS's own (powerd and the like) come and go and are not something to quit.
        let awake = v.blockers.filter { $0.kind == .system }
        var seen = Set<String>()
        let apps = awake.compactMap { b -> (name: String, pid: Int32)? in
            let name = b.onBehalfOf ?? b.name
            guard !systemHolders.contains(name), !Safety.protectedNames.contains(name), seen.insert(name).inserted else { return nil }
            return (name, b.onBehalfOfPID ?? b.pid)
        }
        if !apps.isEmpty {
            var c = check(.sleep, "blockers", "\(apps.map(\.name).prefix(3).joined(separator: ", ")) \(apps.count == 1 ? "is" : "are") keeping the Mac awake", .warning,
                             "While \(apps.count == 1 ? "it holds" : "they hold") the Mac awake it will not sleep on its own, even with you away.",
                             actions: apps.prefix(3).map { .quit(pids: [$0.pid], name: $0.name) },
                             items: awake.map { "\($0.onBehalfOf ?? $0.name): \($0.reason)" })
            c.subject = apps.map(\.name).sorted().joined(separator: ",")
            out.append(c)
        }
        if let s = v.sleep, s.darkWakes >= 24, s.asleep >= 3600 {
            let causes = s.wakeCauses.prefix(3).map { "\($0.cause) ×\($0.count)" }
            out.append(check(.sleep, "wakes", "Woke \(s.darkWakes) times while asleep", .warning,
                             causes.isEmpty ? "Something keeps waking it briefly." : "Most often: " + causes.joined(separator: ", ") + ".",
                             steps: ["Turn off Wake for network access in Battery settings.", "Unplug USB devices and hubs overnight to see if the wakes stop."],
                             actions: [.openSettings(.battery)]))
        }
        if out.isEmpty {
            out.append(check(.sleep, "ok", "Nothing is holding the Mac awake", .ok,
                             v.sleep.map { "It woke \($0.darkWakes) times while asleep recently, which is normal." } ?? "No app holds a sleep block now.",
                             steps: ["If it still will not sleep, check Battery settings: Prevent automatic sleeping, and Wake for network access."],
                             actions: [.openSettings(.battery)]))
        }
        return out
    }

    /// Parts of macOS that hold the Mac awake for a moment while they work.
    static let systemHolders: Set<String> = ["powerd", "runningboardd", "sharingd", "bluetoothd", "backupd", "useractivityd",
                                              "mDNSResponder", "softwareupdated", "coreaudiod", "airportd", "apsd", "WindowServer"]

    // MARK: Microphone and camera

    static func micCamera(_ v: Vitals) -> [Check] {
        let tools: [Check.Fix] = [.admin(label: "Restart sound", command: .restartAudio)]
        guard let grants = v.privacy else {
            return [check(.micCamera, "unknown", "Cannot see which apps are allowed", .info,
                          "Reading the privacy list needs Full Disk Access for System Sentinel. You can still check by hand.",
                          steps: ["Open Microphone settings and turn the app on.", "Quit and reopen the app after changing it."],
                          fixes: [.settings(label: "Microphone settings", url: privacyURL("Microphone")),
                                  .settings(label: "Camera settings", url: privacyURL("Camera")),
                                  .settings(label: "Full Disk Access", url: privacyURL("AllFiles"))] + tools)]
        }
        var out: [Check] = []
        for g in grants where !g.allowed {
            out.append(check(.micCamera, "\(g.service)-\(g.bundleID)", "\(g.name) is not allowed to use the \(g.service.lowercased())", .info,
                             "If that was not on purpose, reset it: macOS asks again the next time \(g.name) wants it.",
                             fixes: [.run(label: "Reset \(g.name)'s \(g.service.lowercased()) permission", path: "/usr/bin/tccutil", args: ["reset", g.service, g.bundleID]),
                                     .settings(label: "\(g.service) settings", url: privacyURL(g.service))]))
        }
        let allowed = grants.filter(\.allowed)
        out.append(check(.micCamera, "ok", out.isEmpty ? "No app has been refused" : "The other apps are allowed", .ok,
                         allowed.isEmpty ? "No app has asked yet." : "\(allowed.count) permission\(allowed.count == 1 ? "" : "s") granted.",
                         steps: ["If sound or the microphone stopped for every app, restart sound.", "Check the input device in Sound settings."],
                         fixes: tools, items: allowed.map { "\($0.name): \($0.service.lowercased())" }))
        return out
    }

    public static func privacyURL(_ service: String) -> String {
        "x-apple.systempreferences:com.apple.preference.security?Privacy_\(service)"
    }

    // MARK: Apps that will not open

    static func appWontOpen(_ v: Vitals) -> [Check] {
        var out = v.crashChecks + v.blockedApps.map { a in
            var c = check(.appWontOpen, a.path, "macOS will not open \(a.name)", .warning,
                  "It was downloaded and fails Apple's check, so macOS calls it damaged or from an unidentified developer.",
                  why: "Only allow it if you trust where it came from. Allowing it removes the download flag, as Open Anyway in Privacy & Security does.",
                  fixes: [.run(label: "Allow \(a.name) to open", path: "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", a.path]),
                          .settings(label: "Privacy & Security", url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
                          .reveal(label: "Show in Finder", path: a.path)])
            c.subject = a.path
            return c
        }
        if out.isEmpty {
            out.append(check(.appWontOpen, "ok", "No app keeps crashing, and none is blocked", .ok,
                             "Nothing crashed three times this week, and every app in Applications passes Apple's check or has been allowed.",
                             steps: ["If one app misbehaves, quit it and open it again.", "Reinstall the app from its maker."]))
        }
        return out
    }

    // MARK: Bluetooth

    static func bluetooth(_ v: Vitals) -> [Check] {
        let restart: [Check.Fix] = [.admin(label: "Restart Bluetooth", command: .restartBluetooth),
                                    .settings(label: "Bluetooth settings", url: "x-apple.systempreferences:com.apple.BluetoothSettings")]
        var out: [Check] = []
        if v.bluetoothCPU >= 30 {
            out.append(check(.bluetooth, "cpu", String(format: "Bluetooth is stuck: bluetoothd at %.0f%% of a core", v.bluetoothCPU), .warning,
                             "That usually means devices dropping and reconnecting. Restarting it clears it; keyboards and mice drop for a few seconds.",
                             fixes: restart))
        }
        if let b = v.bluetooth, !b.on {
            out.append(check(.bluetooth, "off", "Bluetooth is off", .info, "Turn it on in Control Centre or Bluetooth settings.", fixes: restart))
        }
        if out.isEmpty {
            let connected = v.bluetooth?.connected ?? []
            out.append(check(.bluetooth, "ok", connected.isEmpty ? "Bluetooth is on, nothing connected" : "Bluetooth is working", .ok,
                             connected.isEmpty ? "No device is connected right now." : "Connected: \(connected.joined(separator: ", ")).",
                             steps: ["Remove the device in Bluetooth settings and pair it again.", "USB 3 hubs and drives near the Mac can interfere: move them away."],
                             fixes: restart))
        }
        return out
    }

    // MARK: iCloud

    static func icloud(_ v: Vitals) -> [Check] {
        let restart: Check.Fix = .run(label: "Restart iCloud sync", path: "/usr/bin/killall", args: ["bird", "cloudd"])
        if v.syncCPU >= 30 {
            return [check(.icloud, "busy", String(format: "iCloud sync is busy: %.0f%% of a core", v.syncCPU), .warning,
                          "Fine for a while after adding many files. If it stays busy and files sit on Waiting, restart it: it picks up where it left off.",
                          fixes: [restart])]
        }
        return [check(.icloud, "ok", "iCloud sync is idle", .ok,
                      "Nothing is uploading or stuck in a loop right now.",
                      steps: ["If files stay on Waiting to upload, restart iCloud sync.", "Check you have iCloud storage left in Apple Account settings."],
                      fixes: [restart])]
    }

    // MARK: Restarts

    static func restarts(_ v: Vitals) -> [Check] {
        var out = v.restartChecks
        if let p = v.panic, let i = out.firstIndex(where: { $0.id == "panics" }) {
            out[i].detail = "Last one: \(p)"
        }
        if out.isEmpty {
            out.append(check(.restarts, "ok", "No unexpected restarts", .ok,
                             "No kernel panic in 30 days. An app crashing does not restart the Mac: that shows under App crashes or won't open."))
        }
        return out
    }

    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
}

/// Reading what the probes behind the symptoms print. Pure, so each is tested with real output.
public enum SymptomParse {
    /// `sqlite3 TCC.db "select service, client, auth_value from access where ..."`:
    /// "kTCCServiceMicrophone|us.zoom.xos|2". 2 is allowed, 0 denied.
    public static func privacy(_ out: String, name: (String) -> String = { $0 }) -> [PrivacyGrant] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, f[0].hasPrefix("kTCCService"), let auth = Int(f[2].trimmingCharacters(in: .whitespaces)) else { return nil }
            let service = String(f[0].dropFirst("kTCCService".count))
            guard service == "Microphone" || service == "Camera", !f[1].hasPrefix("/") else { return nil }
            return PrivacyGrant(service: service, bundleID: f[1], name: name(f[1]), allowed: auth == 2 || auth == 3)
        }
    }

    /// The quarantine flag "0083;65f1c2a0;Safari;UUID": its first field is hex flags, and 0x40
    /// means the person already said Open to it.
    public static func approved(_ quarantine: String) -> Bool {
        guard let f = quarantine.split(separator: ";").first, let flags = UInt(f, radix: 16) else { return true }
        return flags & 0x40 != 0
    }

    /// `spctl -a -vv -t exec`: "App.app: rejected" or "App.app: accepted".
    public static func rejected(_ spctl: String) -> Bool {
        spctl.contains(": rejected")
    }

    /// `system_profiler SPBluetoothDataType -json`.
    public static func bluetooth(_ data: Data) -> BluetoothState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
        let props = first["controller_properties"] as? [String: Any]
        let state = (props?["controller_state"] as? String) ?? ""
        let connected = (first["device_connected"] as? [[String: Any]] ?? []).flatMap(\.keys)
        return BluetoothState(on: state.hasSuffix("_on") || state.lowercased() == "on", connected: connected.sorted())
    }

    /// A kernel panic report in a sentence: what kind it was, and the outside driver named in
    /// it, if any. Nil when the text says nothing recognisable.
    public static func panic(_ text: String) -> String? {
        let t = text.lowercased()
        let kind: String? = {
            if t.contains("sleep wake failure") || t.contains("sleep/wake") { return "it failed to wake from sleep" }
            if t.contains("watchdog") { return "the Mac stopped responding for minutes and the watchdog restarted it" }
            if t.contains("thunderbolt") || t.contains("ioportfeature") || t.contains("appleusb") { return "a USB or Thunderbolt device (often a hub or dock) crashed the system" }
            if t.contains("agx") || t.contains("gpu") { return "the graphics hardware or its driver crashed" }
            if t.contains("zone_map") || t.contains("zalloc") { return "the system ran out of kernel memory, usually a driver leaking it" }
            if t.contains("smc") || t.contains("thermal") || t.contains("power") { return "a power or temperature fault" }
            if t.contains("panic(") { return "the system kernel crashed" }
            return nil
        }()
        guard let kind else { return nil }
        // Kernel extensions named in the report that are not Apple's.
        let ns = text as NSString
        let re = try? NSRegularExpression(pattern: #"(?:^|[\s(])([a-z0-9]+\.[a-z0-9.\-]+)\(\d[\d.]*\)"#, options: [.anchorsMatchLines, .caseInsensitive])
        let names = (re?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [])
            .map { ns.substring(with: $0.range(at: 1)) }.filter { !$0.hasPrefix("com.apple.") }
        let extra = Array(Set(names)).sorted().first.map { ". It names \($0), a driver that is not Apple's: update or remove it" } ?? ""
        return kind.prefix(1).uppercased() + kind.dropFirst() + extra + "."
    }
}
