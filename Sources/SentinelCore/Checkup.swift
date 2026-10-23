import Foundation

/// One finding from the checkup: what was checked, how it stands, why it matters and what fixes it.
public struct Check: Identifiable, Equatable, Sendable {
    public enum Status: Int, Comparable, Sendable {
        case ok, info, warning, problem
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    /// In the order the Checkup tab shows them: what slows the Mac first, security last.
    public enum Area: String, CaseIterable, Sendable {
        case system = "System", apps = "Apps", network = "Network", backup = "Backup", security = "Security"
        public var symbol: String {
            switch self {
            case .security: return "lock.shield.fill"
            case .network: return "network"
            case .system: return "gearshape.2.fill"
            case .apps: return "app.badge.fill"
            case .backup: return "clock.arrow.circlepath"
            }
        }
    }

    /// What a fix button does. Admin commands are fixed strings written here, never built
    /// from anything read off the Mac, so nothing can be slipped into the password prompt.
    public enum Fix: Equatable, Sendable {
        /// Runs a program as the user.
        case run(label: String, path: String, args: [String])
        /// Runs a fixed shell command after the admin password prompt.
        case admin(label: String, command: AdminCommand)
        case settings(label: String, url: String)
        case reveal(label: String, path: String)
        case web(label: String, url: String)
        /// Stops a user launch agent and moves its plist to the Trash (reversible).
        case removeAgent(label: String, plist: String, job: String)

        public var label: String {
            switch self {
            case .run(let l, _, _), .admin(let l, _), .settings(let l, _), .reveal(let l, _), .web(let l, _), .removeAgent(let l, _, _): return l
            }
        }
    }

    /// The only commands that may run as admin.
    public enum AdminCommand: String, Sendable, CaseIterable {
        case firewallOn = "/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"
        case stealthOn = "/usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on"
        case flushDNS = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case restartAudio = "/usr/bin/killall coreaudiod"
        case restartBluetooth = "/usr/bin/pkill bluetoothd"
        case spotlightReindex = "/usr/bin/mdutil -E /"
        case spotlightOn = "/usr/bin/mdutil -i on /"
        case syncClock = "/usr/bin/sntp -sS time.apple.com"
        case guestOff = "/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow GuestEnabled -bool false"
        case cancelPrintJobs = "/usr/bin/cancel -a -"
        case restartSoftwareUpdate = "/usr/bin/killall softwareupdated"
        case autoSecurityUpdatesOn = "/usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true; /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true"
    }

    public let id: String
    public let area: Area
    public let title: String
    public var status: Status
    public var detail: String
    public var why: String?
    public var steps: [String] = []
    public var fixes: [Fix] = []
    /// Things worth naming under the check: ports, processes, files.
    public var items: [String] = []
    /// One-click fixes that need the app, such as quitting an app or opening another tab.
    public var actions: [FixAction] = []
    /// Who or what it is about (the apps holding the Mac awake, the app that crashes), so
    /// ignoring it ignores just that: a different app doing the same thing shows again.
    public var subject: String?

    /// What Ignore remembers. A finding with a subject is ignored for good; one without (the
    /// Mac running hot, the disk filling) is a passing state, so it is ignored for a day.
    public var ignoreKey: String { id + (subject.map { ":" + $0 } ?? "") }
    public var ignoreFor: TimeInterval { subject == nil ? 86_400 : .infinity }

    public init(id: String, area: Area, title: String, status: Status, detail: String, why: String? = nil,
                steps: [String] = [], fixes: [Fix] = [], items: [String] = []) {
        self.id = id; self.area = area; self.title = title; self.status = status; self.detail = detail
        self.why = why; self.steps = steps; self.fixes = fixes; self.items = items
    }
}

/// Reading what macOS tools print. Pure, so each is tested with real output.
public enum CheckParse {
    public static func fileVaultOn(_ s: String) -> Bool? {
        if s.contains("FileVault is On") { return true }
        if s.contains("FileVault is Off") { return false }
        return nil
    }

    public static func firewallOn(_ s: String) -> Bool? {
        if s.contains("enabled") || s.contains("State = 1") || s.contains("State = 2") { return true }
        if s.contains("disabled") || s.contains("State = 0") { return false }
        return nil
    }

    public static func stealthOn(_ s: String) -> Bool? {
        if s.contains("stealth mode is on") || s.contains("Stealth mode enabled") { return true }
        if s.contains("stealth mode is off") || s.contains("Stealth mode disabled") { return false }
        return nil
    }

    public static func gatekeeperOn(_ s: String) -> Bool? {
        if s.contains("assessments enabled") { return true }
        if s.contains("assessments disabled") { return false }
        return nil
    }

    public static func sipOn(_ s: String) -> Bool? {
        if s.contains("status: enabled") { return true }
        if s.contains("status: disabled") || s.contains("Custom Configuration") { return false }
        return nil
    }

    /// `softwareupdate -l`: the titles of what is waiting.
    /// The pending updates, or nil when `softwareupdate -l` gave no answer (stopped or offline),
    /// so a timeout is never read as "up to date".
    public static func pendingUpdates(answer s: String) -> [String]? {
        let list = pendingUpdates(s)
        return list.isEmpty && !s.contains("No new software available") ? nil : list
    }

    public static func pendingUpdates(_ s: String) -> [String] {
        s.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("Title:") else { return nil }
            return l.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    public struct Listener: Equatable, Sendable {
        public let process: String
        public let pid: Int32
        public let port: Int
        /// Reachable from other machines: bound to every address, not just this Mac.
        public let exposed: Bool
    }

    /// `netstat -anv -p tcp`, LISTEN lines: who listens on which port.
    public static func listeners(_ s: String) -> [Listener] {
        var out: [Listener] = []
        for line in s.split(separator: "\n") where line.contains("LISTEN") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 10, let local = f.dropFirst(3).first,
                  let dot = local.lastIndex(of: "."), let port = Int(local[local.index(after: dot)...]) else { continue }
            let host = String(local[..<dot])
            guard let procField = processField(f) else { continue }
            let parts = procField.split(separator: ":")
            let exposed = !(host.hasPrefix("127.") || host == "::1" || host.hasPrefix("fe80"))
            let l = Listener(process: parts.dropLast().joined(separator: ":"), pid: Int32(parts.last!) ?? 0, port: port, exposed: exposed)
            if !out.contains(l) { out.append(l) }
        }
        return out
    }

    /// "process:pid" sits after the state and four counters: column 11.
    static func processField(_ f: [String]) -> String? {
        guard f.count > 10, f[10].contains(":"), Int(f[10].split(separator: ":").last ?? "") != nil else { return nil }
        return f[10]
    }

    /// Services that should be off unless you use them on purpose.
    public static let riskyPorts: [Int: String] = [
        21: "FTP (unencrypted file transfer)", 22: "Remote Login (SSH)", 23: "Telnet (unencrypted)",
        445: "File Sharing (SMB)", 548: "File Sharing (AFP)", 3283: "Apple Remote Desktop", 5900: "Screen Sharing (VNC)",
        3389: "Remote Desktop", 5432: "PostgreSQL", 3306: "MySQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch",
    ]

    public struct Connection: Equatable, Sendable {
        public let process: String
        public let remote: String
        public let port: Int
    }

    /// `netstat -anv -p tcp`, ESTABLISHED lines to ports that carry data in the clear.
    public static let clearTextPorts: [Int: String] = [21: "FTP", 23: "Telnet", 25: "SMTP", 80: "HTTP", 110: "POP3", 143: "IMAP"]

    public static func clearText(_ s: String) -> [Connection] {
        var out: [Connection] = []
        for line in s.split(separator: "\n") where line.contains("ESTABLISHED") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 10, f.count > 4 else { continue }
            let foreign = f[4]
            guard let dot = foreign.lastIndex(of: "."), let port = Int(foreign[foreign.index(after: dot)...]),
                  clearTextPorts[port] != nil else { continue }
            let host = String(foreign[..<dot])
            guard !host.hasPrefix("127.") && host != "::1" else { continue }
            let procField = processField(f)
            let name = procField.map { $0.split(separator: ":").dropLast().joined(separator: ":") } ?? "?"
            let c = Connection(process: name, remote: host, port: port)
            if !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// Remote access and tunnelling tools worth knowing about when they run.
    public static let remoteAccessTools: [String: String] = [
        "teamviewer": "TeamViewer", "anydesk": "AnyDesk", "ngrok": "ngrok tunnel", "rustdesk": "RustDesk",
        "screenconnect": "ScreenConnect", "connectwise": "ConnectWise", "logmein": "LogMeIn", "splashtop": "Splashtop",
        "remoting_host": "Chrome Remote Desktop", "cloudflared": "Cloudflare tunnel", "tailscaled": "Tailscale",
        "zerotier": "ZeroTier", "parsec": "Parsec", "vnc": "VNC server", "frpc": "frp tunnel", "chisel": "chisel tunnel",
    ]

    public static func remoteTool(_ path: String) -> String? {
        let n = (path as NSString).lastPathComponent.lowercased()
        let p = path.lowercased()
        return remoteAccessTools.first { n.contains($0.key) || p.contains("/\($0.key)") }?.value
    }

    /// Program locations malware favours: temporary folders, Downloads, shared and hidden folders.
    public static func oddLocation(_ path: String, home: String) -> Bool {
        let p = path
        if p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") || p.hasPrefix("/private/var/tmp/") || p.hasPrefix("/Users/Shared/") { return true }
        if p.hasPrefix(home + "/Downloads/") { return true }
        if p.hasPrefix("/private/var/folders/") && !p.contains("/T/AppTranslocation/") && !p.contains("/X/") { return true }
        // A hidden folder straight under home holding a program, other than well known tool folders.
        if p.hasPrefix(home + "/.") {
            let known = [".cargo", ".rustup", ".nvm", ".pyenv", ".rbenv", ".local", ".npm", ".bun", ".deno", ".volta", ".sdkman",
                         ".vscode", ".cursor", ".docker", ".rd", ".colima", ".lima", ".orbstack", ".claude", ".codex", ".gem", ".asdf", ".pnpm", ".config"]
            let first = p.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? ""
            return !known.contains(first)
        }
        return false
    }

    /// An app's App Transport Security settings that allow plain HTTP or old TLS.
    public static func weakTransport(_ info: [String: Any]) -> String? {
        guard let ats = info["NSAppTransportSecurity"] as? [String: Any] else { return nil }
        var why: [String] = []
        if ats["NSAllowsArbitraryLoads"] as? Bool == true { why.append("allows unencrypted HTTP to any site") }
        if let domains = ats["NSExceptionDomains"] as? [String: Any] {
            let old = domains.compactMap { name, v -> String? in
                guard let d = v as? [String: Any], let tls = d["NSExceptionMinimumTLSVersion"] as? String,
                      tls == "TLSv1.0" || tls == "TLSv1.1" else { return nil }
                return name
            }
            if !old.isEmpty { why.append("accepts TLS 1.0/1.1 for \(old.sorted().prefix(3).joined(separator: ", "))") }
        }
        return why.isEmpty ? nil : why.joined(separator: "; ")
    }

    /// A launch agent or daemon plist: its label and the program it starts.
    public static func launchItem(_ plist: [String: Any]) -> (label: String, program: String?) {
        let label = plist["Label"] as? String ?? "?"
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        return (label, program)
    }

    /// `ping` summary: packet loss percent and average round trip in ms.
    public static func ping(_ s: String) -> (loss: Double, avg: Double?)? {
        guard let lossLine = s.split(separator: "\n").first(where: { $0.contains("packet loss") }) else { return nil }
        let loss = lossLine.split(separator: ",").first { $0.contains("packet loss") }
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces).split(separator: "%").first ?? "") } ?? 100
        var avg: Double?
        if let rtt = s.split(separator: "\n").first(where: { $0.contains("round-trip") || $0.contains("rtt") }),
           let eq = rtt.split(separator: "=").last {
            let parts = eq.trimmingCharacters(in: .whitespaces).split(separator: "/")
            if parts.count >= 2 { avg = Double(parts[1]) }
        }
        return (loss, avg)
    }

    /// `route -n get default`: gateway and interface.
    public static func defaultRoute(_ s: String) -> (gateway: String?, interface: String?) {
        var g: String?, i: String?
        for line in s.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("gateway:") { g = l.dropFirst(8).trimmingCharacters(in: .whitespaces) }
            if l.hasPrefix("interface:") { i = l.dropFirst(10).trimmingCharacters(in: .whitespaces) }
        }
        return (g, i)
    }

    /// `ifconfig en0`: the interface MTU.
    public static func mtu(_ s: String) -> Int? {
        guard let r = s.range(of: "mtu ") else { return nil }
        return Int(s[r.upperBound...].prefix { $0.isNumber })
    }

    /// `sntp -t 2 time.apple.com`: clock offset in seconds ("+0.012345 +/- 0.01 ...").
    public static func clockOffset(_ s: String) -> Double? {
        for line in s.split(separator: "\n") {
            let f = line.split(separator: " ")
            if let first = f.first, let v = Double(first), f.contains("+/-") { return v }
        }
        return nil
    }

    /// `mdutil -s /`: whether Spotlight indexing is on.
    public static func spotlightOn(_ s: String) -> Bool? {
        if s.contains("Indexing enabled") { return true }
        if s.contains("Indexing disabled") || s.contains("Indexing and searching disabled") { return false }
        return nil
    }

    /// `tmutil latestbackup`: the date in the backup's folder name (2026-10-17-093012).
    public static func backupDate(_ s: String) -> Date? {
        guard let r = s.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: String(s[r]))
    }

    /// Crash reports by process: "Name-2026-10-18-110706.ips" counted per Name.
    /// The bundle id from the one-line JSON header of a `.ips` crash report. Apps have one;
    /// command-line programs (compilers, scripts, helpers) do not.
    public static func crashBundleID(_ header: String) -> String? {
        guard let line = header.split(separator: "\n", maxSplits: 1).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["bundleID"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// One program's crashes this week.
    public struct Crashes: Equatable, Sendable {
        public let process: String
        public let dates: [Date]
        /// Nil for a command-line program.
        public let bundleID: String?
        public init(process: String, dates: [Date], bundleID: String?) { self.process = process; self.dates = dates; self.bundleID = bundleID }
    }

    /// The crash check: which program keeps crashing, and whether it still does. Crashes that
    /// all came in one burst hours ago (a build that hit a compiler bug) are history,
    /// not a warning. A command-line program gets advice about what ran it, not "reinstall the app".
    public static func crashCheck(_ all: [Crashes], reports: String, now: Date = Date()) -> Check? {
        let list = all.filter { $0.dates.count >= 3 }.sorted { $0.dates.count > $1.dates.count }
        guard let top = list.first, let first = top.dates.min(), let last = top.dates.max() else { return nil }
        let burst = last.timeIntervalSince(first) <= 3600
        // A burst with six quiet hours after it is over; spread-out crashes need a quiet day.
        let quiet = now.timeIntervalSince(last) >= (burst ? 6 * 3600 : 86_400)
        let isApp = top.bundleID != nil
        let day = last.formatted(.dateTime.day().month(.abbreviated))
        let span = burst ? "all on \(day) between \(first.formatted(date: .omitted, time: .shortened)) and \(last.formatted(date: .omitted, time: .shortened))"
                         : "the last on \(day) at \(last.formatted(date: .omitted, time: .shortened))"
        let others = list.dropFirst().prefix(3).map { "\($0.process) ×\($0.dates.count)" }
        var detail = "\(top.dates.count) crashes, \(span)" + (quiet ? ", and none since." : ".")
        if !others.isEmpty { detail += " Also: " + others.joined(separator: ", ") + "." }
        let steps: [String]
        if quiet {
            steps = ["Nothing to do unless it happens again. The reports age out after a week."]
        } else if isApp {
            steps = ["Update the app.", "If it continues, reinstall it, or move its preferences out of ~/Library/Preferences."]
        } else {
            steps = ["\(top.process) is a command-line program, not an app: something ran it, such as a build, a script or a developer tool.",
                     "The cause is in that tool's output or its crash report. Updating the tool that ran it usually fixes it."]
        }
        var c = Check(id: "crashes", area: .apps, title: "\(top.process) crashed \(top.dates.count) times this week", status: quiet ? .info : .warning,
                      detail: detail, why: "A crash ends that one program. It does not restart the Mac; that is a kernel panic, checked separately.",
                      steps: steps, fixes: [.reveal(label: "Show crash reports", path: reports)],
                      items: list.map { "\($0.process)\($0.bundleID == nil ? " (command-line)" : ""): \($0.dates.count) crashes" })
        c.subject = top.process
        return c
    }

    public static func crashCounts(_ files: [(name: String, date: Date)], since: Date) -> [(process: String, count: Int)] {
        var counts: [String: Int] = [:]
        for f in files where f.date >= since && (f.name.hasSuffix(".ips") || f.name.hasSuffix(".crash")) {
            guard let r = f.name.range(of: #"-\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { continue }
            let proc = String(f.name[..<r.lowerBound])
            if proc.hasPrefix("panic") || proc.hasPrefix("JetsamEvent") || proc.contains(".cpu_resource") || proc.contains(".diag") { continue }
            counts[proc, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }
}
