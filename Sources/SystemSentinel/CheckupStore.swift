import AppKit
import SentinelCore
import Security
import SwiftUI

/// The Checkup tab: security posture, network health, broken leftovers, crashes and backups,
/// each with a fix. Runs a minute after launch and every 6 hours, or on demand.
@MainActor
final class CheckupStore: ObservableObject {
    @Published var checks: [Check] = []
    @Published var running = false
    @Published var ranAt: Date?
    var ran: (TaskHealth.Job) -> Void = { _ in }
    @Published var working: Set<String> = []
    /// Pending macOS updates, from the slow `softwareupdate -l`, refreshed once a day.
    @Published var updates: [String]?
    private var updatesAt: Date?
    private var timer: Timer?
    /// What the symptom checks read beyond the live numbers: privacy grants, blocked apps,
    /// Bluetooth and the last panic. Refreshed with the checkup and when a symptom is opened.
    @Published var probes = SymptomProbes()
    var toast: (Model.Toast) -> Void = { _ in }

    init(readOnly: Bool) {
        if readOnly { run(); return }
        // Soon after launch: Checkup is the first tab, so an empty one would be the first thing seen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in SelfGuard.when("checkup") { self?.run() } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in SelfGuard.when("checkup") { self?.run() } }
        }
    }

    var problems: [Check] { checks.filter { $0.status >= .warning && !isIgnored($0) } }

    /// Findings the person said are on purpose, by `Check.ignoreKey`, with when that ends.
    @Published var ignored: [String: Double] = UserDefaults.standard.dictionary(forKey: "ignoredFindings") as? [String: Double] ?? [:]

    var ignoredKeys: Set<String> {
        let now = Date().timeIntervalSince1970
        return Set(ignored.filter { $0.value > now }.keys)
    }

    func isIgnored(_ c: Check) -> Bool { ignoredKeys.contains(c.ignoreKey) }

    func ignore(_ c: Check) { ignore(key: c.ignoreKey, for: c.ignoreFor) }

    func ignore(key: String, for duration: TimeInterval) {
        ignored[key] = duration == .infinity ? Double.greatestFiniteMagnitude : Date().timeIntervalSince1970 + duration
        UserDefaults.standard.set(ignored, forKey: "ignoredFindings")
    }

    func showIgnoredAgain() {
        ignored = [:]
        UserDefaults.standard.removeObject(forKey: "ignoredFindings")
    }

    /// Re-reads only what listens on the network, a few seconds after a Stop, so the finding
    /// goes once the service has.
    func refreshExposure() {
        guard !running else { return }
        Task.detached(priority: .utility) {
            let fresh = CheckupStore.exposure()
            await MainActor.run {
                let ids: Set<String> = ["listen-risky", "listen-apps", "cleartext"]
                let at = self.checks.firstIndex { ids.contains($0.id) } ?? self.checks.count
                var kept = self.checks.filter { !ids.contains($0.id) }
                kept.insert(contentsOf: fresh, at: min(at, kept.count))
                self.checks = kept
            }
        }
    }

    func run() {
        guard !running else { return }
        running = true
        let needUpdates = updatesAt.map { Date().timeIntervalSince($0) >= 86_400 } ?? true
        let known = updates
        Task.detached(priority: .utility) {
            async let security = CheckupStore.securityChecks()
            async let network = CheckupStore.networkChecks()
            async let system = CheckupStore.systemChecks()
            async let probes = CheckupStore.readProbes()
            var all = await security + network + system
            all.append(CheckupStore.updatesCheck(known, checking: needUpdates))
            let sorted = CheckupStore.sorted(all)
            let read = await probes
            await MainActor.run {
                self.checks = sorted
                self.probes = read
                self.ranAt = Date()
                self.running = false
                self.ran(.checkup)
                if needUpdates { self.checkUpdates() }
            }
        }
    }

    nonisolated static func sorted(_ all: [Check]) -> [Check] {
        all.sorted { ($0.status, $1.area.rawValue) > ($1.status, $0.area.rawValue) }
    }

    private var updatesRunning = false

    /// `softwareupdate -l` can take minutes, or hang when Software Update is busy, so it runs
    /// on its own and fills in its row when it answers instead of holding up the checkup.
    private func checkUpdates() {
        guard !updatesRunning else { return }
        updatesRunning = true
        Task.detached(priority: .utility) {
            let pending = CheckParse.pendingUpdates(answer: sh("/usr/sbin/softwareupdate", ["-l"], timeout: 120))
            await MainActor.run {
                self.updatesRunning = false
                if let pending { self.updates = pending; self.updatesAt = Date() }
                let row = CheckupStore.updatesCheck(self.updates, checking: false)
                var list = self.checks.filter { $0.id != row.id }
                list.append(row)
                self.checks = CheckupStore.sorted(list)
            }
        }
    }

    // MARK: Security

    nonisolated static func securityChecks() -> [Check] {
        var out: [Check] = []
        let pane = "x-apple.systempreferences:com.apple.preference.security"
        switch CheckParse.fileVaultOn(sh("/usr/bin/fdesetup", ["status"])) {
        case true?: out.append(Check(id: "filevault", area: .security, title: "FileVault disk encryption is on", status: .ok, detail: "A lost or stolen Mac does not give away its files."))
        case false?: out.append(Check(id: "filevault", area: .security, title: "FileVault is off", status: .problem,
                                      detail: "Anyone with the Mac can read the disk without your password.",
                                      steps: ["Open Privacy & Security, FileVault, Turn On. Keep the recovery key somewhere safe."],
                                      fixes: [.settings(label: "Open FileVault settings", url: pane + "?FileVault")]))
        case nil: break
        }
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        if let on = CheckParse.firewallOn(sh(fw, ["--getglobalstate"])) {
            if on {
                let stealth = CheckParse.stealthOn(sh(fw, ["--getstealthmode"])) ?? true
                out.append(Check(id: "firewall", area: .security, title: "Firewall is on\(stealth ? " (stealth)" : "")", status: stealth ? .ok : .info,
                                 detail: stealth ? "Incoming connections are filtered and the Mac does not answer probes." : "Stealth mode would stop the Mac answering pings and port scans on public networks.",
                                 fixes: stealth ? [] : [.admin(label: "Turn on stealth mode", command: .stealthOn)]))
            } else if let ztn = zeroTrustClient() {
                // On a zero trust network the client filters every connection in its own cloud,
                // so the Mac's firewall adds little and is often off by company policy.
                out.append(Check(id: "firewall", area: .security, title: "Firewall: covered by \(ztn) (zero trust)", status: .ok,
                                 detail: "The Mac's own firewall is off, which is fine here: \(ztn) filters traffic before it reaches the Mac. Turn it on if you disconnect \(ztn) on public Wi-Fi.",
                                 fixes: [.settings(label: "Firewall settings", url: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")]))
            } else {
                // Info, not a warning: work Macs often sit behind a company firewall that this
                // switch says nothing about.
                out.append(Check(id: "firewall", area: .security, title: "The Mac's own firewall is off", status: .info,
                                 detail: "Fine behind a company firewall or zero trust network. On café and hotel Wi-Fi, turn it on.",
                                 why: "On public Wi-Fi, other devices can connect to sharing services and apps that listen on a port. The firewall asks before letting an app accept connections. Company networks usually filter this before it reaches the Mac, so it is often left off on purpose.",
                                 fixes: [.admin(label: "Turn firewall on", command: .firewallOn), .settings(label: "Firewall settings", url: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")]))
            }
        }
        if let on = CheckParse.gatekeeperOn(sh("/usr/sbin/spctl", ["--status"])) {
            out.append(on ? Check(id: "gatekeeper", area: .security, title: "Gatekeeper checks apps", status: .ok, detail: "Apps must be signed and notarised to open without a warning.")
                          : Check(id: "gatekeeper", area: .security, title: "Gatekeeper is off", status: .problem,
                                  detail: "Any downloaded app opens without a malware check.",
                                  steps: ["In Terminal: sudo spctl --global-enable, then allow apps from the App Store and identified developers in Privacy & Security."],
                                  fixes: [.settings(label: "Privacy & Security", url: pane)]))
        }
        if let on = CheckParse.sipOn(sh("/usr/bin/csrutil", ["status"])) {
            out.append(on ? Check(id: "sip", area: .security, title: "System Integrity Protection is on", status: .ok, detail: "macOS system files cannot be changed, even by admin.")
                          : Check(id: "sip", area: .security, title: "System Integrity Protection is off", status: .problem,
                                  detail: "Malware with admin rights can change macOS itself.",
                                  steps: ["Start up in Recovery (hold the power button), open Terminal, run csrutil enable, restart."]))
        }
        let su = UserDefaults(suiteName: "/Library/Preferences/com.apple.SoftwareUpdate")
        let critical = su?.object(forKey: "CriticalUpdateInstall") as? Bool ?? true
        let config = su?.object(forKey: "ConfigDataInstall") as? Bool ?? true
        out.append(critical && config
            ? Check(id: "autosecurity", area: .security, title: "Security responses install automatically", status: .ok, detail: "XProtect malware definitions and urgent fixes arrive without waiting for you.")
            : Check(id: "autosecurity", area: .security, title: "Security responses do not install automatically", status: .warning,
                    detail: "XProtect malware definitions and urgent security fixes wait for you to install them.",
                    fixes: [.admin(label: "Turn on", command: .autoSecurityUpdatesOn), .settings(label: "Software Update", url: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")]))
        // macOS 15 and later keep the live definitions elsewhere and report them through
        // `xprotect version`; the old bundle's date is only a fallback.
        var xpVersion: String?, xpDate: Date?
        let xpOut = sh("/usr/bin/xprotect", ["version"], timeout: 10)
        if let r = xpOut.range(of: #"Version: (\S+) Installed: (.+)"#, options: .regularExpression) {
            let parts = xpOut[r].components(separatedBy: " Installed: ")
            xpVersion = parts.first?.replacingOccurrences(of: "Version: ", with: "")
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            xpDate = parts.count > 1 ? f.date(from: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            // macOS 26 can report "Installed: 0001-01-01", a placeholder, not a date: it made
            // the check say the definitions were 739,933 days old. Fall back to the bundle.
            if let d = xpDate, d < Date(timeIntervalSince1970: 946_684_800) { xpDate = nil }
        }
        if xpDate == nil {
            let bundles = ["/private/var/protected/xprotect/XProtect.bundle", "/Library/Apple/System/Library/CoreServices/XProtect.bundle"]
            xpDate = bundles.compactMap { (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
            xpVersion = xpVersion ?? NSDictionary(contentsOfFile: bundles[1] + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
        }
        if let mod = xpDate {
            let days = Int(Date().timeIntervalSince(mod) / 86_400)
            out.append(Check(id: "xprotect", area: .security, title: "XProtect malware definitions \(xpVersion ?? "?"), \(days) day\(days == 1 ? "" : "s") old", status: days > 60 ? .warning : .ok,
                             detail: days > 60 ? "Apple usually ships new definitions every few weeks: updates may be blocked." : "Up to date.",
                             steps: days > 60 ? ["Check now with the button. If they stay old, a management profile or a firewall may be blocking Apple's update servers: ask IT."] : [],
                             fixes: days > 60 ? [.admin(label: "Check for new definitions", command: .xprotectUpdate)] : []))
        }
        let login = UserDefaults(suiteName: "/Library/Preferences/com.apple.loginwindow")
        if login?.bool(forKey: "GuestEnabled") == true {
            out.append(Check(id: "guest", area: .security, title: "Guest account is on", status: .info, detail: "Anyone can log in as Guest without a password.",
                             fixes: [.admin(label: "Turn Guest off", command: .guestOff)]))
        }
        if let user = login?.string(forKey: "autoLoginUser") {
            out.append(Check(id: "autologin", area: .security, title: "Automatic login as \(user)", status: .warning,
                             detail: "The Mac starts up without asking for a password.",
                             fixes: [.settings(label: "Users & Groups", url: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")]))
        }
        let enrolment = sh("/usr/bin/profiles", ["status", "-type", "enrollment"])
        if enrolment.contains("MDM enrollment: Yes") {
            out.append(Check(id: "mdm", area: .security, title: "Managed by your organisation (MDM)", status: .info,
                             detail: "Some settings here may be set by your IT team and cannot be changed locally."))
        }
        out += exposure()
        out += runningProcessChecks()
        return out
    }

    /// What listens on the network, and what talks in the clear.
    nonisolated static func exposure() -> [Check] {
        var out: [Check] = []
        let ns = sh("/usr/sbin/netstat", ["-anv", "-p", "tcp"])
        let exposed = CheckParse.listeners(ns).filter(\.exposed)
        let risky = exposed.filter { CheckParse.riskyPorts[$0.port] != nil }
        if !risky.isEmpty {
            var c = Check(id: "listen-risky", area: .security, title: "\(risky.count) sensitive service\(risky.count == 1 ? "" : "s") open to the network", status: .warning,
                          detail: risky.map { "\(CheckParse.riskyPorts[$0.port]!) on port \($0.port)" }.joined(separator: ", ") + ".",
                          why: "Others on the same network can try to connect. Turn off sharing services you do not use, and keep the firewall on. Stop ends it for now; if it comes back by itself, something starts it at login (for Homebrew, brew services list shows it and brew services stop turns it off).",
                          fixes: [.settings(label: "Sharing settings", url: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")],
                          items: risky.map { "\($0.process) (pid \($0.pid)) listening on port \($0.port)" })
            // One Stop per program, covering every copy of it that listens.
            let byProcess = Dictionary(grouping: risky, by: \.process)
            c.actions = byProcess.keys.sorted().map { name in
                .kill(pids: Array(Set(byProcess[name]!.map(\.pid))).sorted(), label: "Stop \(name)")
            }
            out.append(c)
        }
        let others = exposed.filter { CheckParse.riskyPorts[$0.port] == nil && !["rapportd", "ControlCenter", "sharingd", "launchd", "mDNSResponder", "identityservicesd"].contains($0.process) }
        let byProcess = Dictionary(grouping: others, by: \.process)
        if !byProcess.isEmpty {
            out.append(Check(id: "listen-apps", area: .security, title: "\(byProcess.count) app\(byProcess.count == 1 ? "" : "s") accept connections from the network", status: .info,
                             detail: byProcess.keys.sorted().prefix(5).joined(separator: ", ") + ". Usually fine (sync, AirPlay, dev servers); check you recognise them.",
                             items: byProcess.sorted { $0.key < $1.key }.map { "\($0.key): port\($0.value.count == 1 ? "" : "s") \($0.value.map { String($0.port) }.joined(separator: ", "))" }))
        }
        let clear = CheckParse.clearText(ns)
        if !clear.isEmpty {
            // Who each address belongs to, from its reverse DNS name (an Akamai or Cloudflare
            // edge, say), so a line says more than a bare number.
            func owner(_ ip: String) -> String {
                let name = sh("/usr/bin/dig", ["-x", ip, "+short", "+time=1", "+tries=1"], timeout: 3)
                    .split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) } ?? ""
                return name.isEmpty || name.hasPrefix(";") ? ip : "\(name) (\(ip))"
            }
            let lines = clear.map { c in
                "\(c.process) → \(owner(c.remote)), \(CheckParse.clearTextPorts[c.port] ?? "port \(c.port)")"
                    + (CheckParse.clearTextExpected[c.process].map { ": \($0.components(separatedBy: ". ").first ?? $0)" } ?? "")
            }
            let unexpected = clear.filter { CheckParse.clearTextExpected[$0.process] == nil }
            let apps = Array(Set(unexpected.map(\.process))).sorted()
            if unexpected.isEmpty {
                let who = Array(Set(clear.map(\.process))).sorted()
                out.append(Check(id: "cleartext", area: .security, title: "\(clear.count) plain HTTP connection\(clear.count == 1 ? "" : "s") from macOS, as expected", status: .ok,
                                 detail: who.compactMap { p in CheckParse.clearTextExpected[p].map { "\(p) is \($0)." } }.joined(separator: " "),
                                 items: lines))
            } else {
                out.append(Check(id: "cleartext", area: .security, title: "\(unexpected.count) unencrypted connection\(unexpected.count == 1 ? "" : "s") open, from \(apps.prefix(3).joined(separator: ", "))", status: .warning,
                                 detail: "Data on these goes over the network in plain text: anyone on the same Wi-Fi can read it.",
                                 why: "HTTP, FTP, Telnet, POP3 and IMAP without TLS send content (and sometimes passwords) unencrypted. Modern apps use TLS on port 443; an app still using these ports is worth updating or replacing."
                                    + (unexpected.count < clear.count ? " Lines from trustd and other macOS services are expected and safe: they say why." : ""),
                                 steps: ["Look up the app below: if it is an old version, update it.", "On public Wi-Fi, avoid signing in to anything through these apps until they use TLS."],
                                 items: lines))
            }
        }
        return out
    }

    /// Remote access tools, programs running from odd places or unsigned, apps that allow
    /// unencrypted HTTP or old TLS.
    nonisolated static func runningProcessChecks() -> [Check] {
        var out: [Check] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lines = sh("/bin/ps", ["-axo", "pid=,comm="]).split(separator: "\n")
        var paths: [String: Int32] = [:]
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { continue }
            let path = t[sp...].trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { paths[path] = pid }
        }
        let remote = Set(paths.keys.compactMap(CheckParse.remoteTool))
        if !remote.isEmpty {
            out.append(Check(id: "remote-tools", area: .security, title: "Remote access running: \(remote.sorted().joined(separator: ", "))", status: .info,
                             detail: "These let someone else see or control this Mac, or open a tunnel into it. Fine if you set them up; quit them if you did not."))
        }
        var odd: [String] = []
        for (p, _) in paths where CheckParse.oddLocation(p, home: home) {
            odd.append(p + (isSigned(p) ? "" : " (not signed)"))
        }
        if !odd.isEmpty {
            out.append(Check(id: "odd-programs", area: .security, title: "\(odd.count) program\(odd.count == 1 ? "" : "s") running from an unusual place", status: .warning,
                             detail: "Temporary folders, Downloads and hidden folders are where malware likes to run from.",
                             why: "Normal apps run from Applications or a tool folder. Check you recognise each one; Show in Finder, and quit it from the Processes tab if not.",
                             fixes: odd.prefix(3).map { .reveal(label: "Show \(URL(fileURLWithPath: $0.components(separatedBy: " (").first!).lastPathComponent)", path: $0.components(separatedBy: " (").first!) },
                             items: odd.sorted()))
        }
        // Apps running now whose Info.plist relaxes App Transport Security.
        var weak: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL, let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  let why = CheckParse.weakTransport(info) else { continue }
            weak.append("\(app.localizedName ?? url.lastPathComponent): \(why)")
        }
        if !weak.isEmpty {
            out.append(Check(id: "weak-tls", area: .security, title: "\(weak.count) running app\(weak.count == 1 ? "" : "s") allow unencrypted or old-TLS connections", status: .info,
                             detail: "Their settings switch off Apple's rule that connections use TLS 1.2 or later. Often a convenience for the developer; on public Wi-Fi it makes those connections readable or tamperable.",
                             items: weak.sorted()))
        }
        return out
    }

    /// The zero trust client running (Zscaler, Netskope, Cloudflare WARP), if any.
    nonisolated static func zeroTrustClient() -> String? {
        let names = sh("/bin/ps", ["-axco", "comm"], timeout: 5).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let all = NetworkLink.zeroTrust(processNames: names)
        return all.isEmpty ? nil : ListFormatter.localizedString(byJoining: all)
    }

    nonisolated static func isSigned(_ path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    // MARK: Network

    nonisolated static func networkChecks() -> [Check] {
        var out: [Check] = []
        let route = CheckParse.defaultRoute(sh("/sbin/route", ["-n", "get", "default"]))
        guard let iface = route.interface else {
            return [Check(id: "net-offline", area: .network, title: "No network connection", status: .warning, detail: "There is no default route: Wi-Fi or Ethernet is not connected.")]
        }
        let icmp = CheckParse.ping(sh("/sbin/ping", ["-c", "5", "-i", "0.2", "-t", "4", "1.1.1.1"], timeout: 8))
        let gateway = route.gateway.flatMap { g in g.contains(":") ? nil : CheckParse.ping(sh("/sbin/ping", ["-c", "5", "-i", "0.2", "-t", "4", g], timeout: 8)) }
        // Zero trust networks (Zscaler and the like) drop pings: time TCP handshakes instead, as tcping does.
        let ztn = zeroTrustClient()
        let tcp = (icmp?.loss ?? 100) >= 100 ? TCPPing.ping("1.1.1.1", count: 5) : nil
        let viaTCP = (tcp?.loss ?? 100) < 100
        let internet = viaTCP ? tcp : icmp
        let how = viaTCP ? " Pings are blocked \(ztn.map { "by \($0) (zero trust)" } ?? "on this network"), so this is a TCP handshake to port 443." : ""
        if let i = internet {
            let gw = gateway.map { g in " Router: \(Int(g.loss))% loss\(g.avg.map { ", \(Int($0)) ms" } ?? "")." } ?? ""
            if i.loss >= 100 {
                out.append(Check(id: "net-internet", area: .network, title: "Internet is not reachable", status: .problem,
                                 detail: "Pings and connections to 1.1.1.1 get no answer.\(gw)",
                                 steps: gateway.map { $0.loss < 100 ? [ztn.map { "The router answers, so check \($0) is connected and signed in." } ?? "The router answers, so the problem is the internet connection or the ISP: restart the router or call the provider."] : ["The router does not answer either: reconnect Wi-Fi or check the cable."] } ?? []))
            } else if i.loss >= 10 || (i.avg ?? 0) >= 150 {
                let local = (gateway?.loss ?? 0) >= 10 || (gateway?.avg ?? 0) >= 50
                // Loss makes a connection unreliable; delay alone only makes it slow.
                let title = i.loss >= 10 ? "Connection is unreliable: \(Int(i.loss))% loss, \(Int(i.avg ?? 0)) ms"
                                         : "Connection is slow: \(Int(i.avg ?? 0)) ms to the internet, no loss"
                out.append(Check(id: "net-internet", area: .network, title: title, status: .warning,
                                 detail: (local ? "The router link itself is poor: Wi-Fi signal or interference." : "The router link is fine, so the slowness is beyond it: ISP or VPN.") + gw + how,
                                 steps: local ? ["Move closer to the router or use 5 GHz.", "Turn Wi-Fi off and on."] : ["Check the VPN, or restart the router."],
                                 // The interface name goes into a shell line, so only plain names like en0 pass.
                                 fixes: local && iface.range(of: "^[a-z]{2,8}[0-9]{1,3}$", options: .regularExpression) != nil
                                    ? [.run(label: "Turn Wi-Fi off and on", path: "/bin/sh", args: ["-c", "/usr/sbin/networksetup -setairportpower \(iface) off; sleep 2; /usr/sbin/networksetup -setairportpower \(iface) on"])] : []))
            } else {
                out.append(Check(id: "net-internet", area: .network, title: "Internet is healthy: \(Int(i.avg ?? 0)) ms, no loss", status: .ok, detail: "Via \(iface).\(gw)\(how)"))
            }
        }
        // DNS: how long a lookup takes through the Mac's resolver.
        let t0 = Date()
        let resolved = !sh("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "www.apple.com"], timeout: 6).isEmpty
        let ms = Date().timeIntervalSince(t0) * 1000
        if !resolved || ms > 1500 {
            out.append(Check(id: "net-dns", area: .network, title: resolved ? "Name lookups are slow: \(Int(ms)) ms" : "Name lookups are failing", status: .warning,
                             detail: "Every website waits for DNS first.",
                             steps: ["Flush the DNS cache.", "If it keeps happening, try another DNS server (1.1.1.1 or 8.8.8.8) in Network settings."],
                             fixes: [.admin(label: "Flush DNS cache", command: .flushDNS)]))
        } else {
            out.append(Check(id: "net-dns", area: .network, title: "Name lookups work: \(Int(ms)) ms", status: .ok, detail: "DNS answers quickly.",
                             fixes: [.admin(label: "Flush DNS cache", command: .flushDNS)]))
        }
        // Path MTU: the largest packet that crosses without being fragmented.
        if let i = icmp, i.loss < 100, let ifMTU = CheckParse.mtu(sh("/sbin/ifconfig", [iface])) {
            let path = PathMTU.find(interfaceMTU: ifMTU) { size in
                (CheckParse.ping(sh("/sbin/ping", ["-D", "-c", "1", "-t", "2", "-s", String(size), "1.1.1.1"], timeout: 4))?.loss ?? 100) < 100
            } ?? 0
            if path > 0 && path < ifMTU {
                out.append(Check(id: "net-mtu", area: .network, title: "Packets over \(path) bytes get fragmented (interface MTU \(ifMTU))", status: path < 1400 ? .warning : .info,
                                 detail: "Usually a VPN or PPPoE link. Large transfers can stall or be slow when packets are split or dropped.",
                                 why: "Found by sending pings with the don't-fragment flag at decreasing sizes. Path MTU is the largest that got through plus 28 bytes of headers.",
                                 steps: ["If downloads stall on this network, set the MTU to \(path) in Network, Details, Hardware, or ask the VPN admin."]))
            } else if path > 0 {
                out.append(Check(id: "net-mtu", area: .network, title: "No fragmentation: full \(path)-byte packets get through", status: .ok, detail: "The path MTU matches the interface."))
            }
        }
        // IPv6: an address that does not reach anything makes apps wait before falling back.
        let hasV6 = sh("/sbin/ifconfig", [iface]).contains("inet6 2") || sh("/sbin/ifconfig", [iface]).contains("inet6 3")
        if hasV6 {
            let v6 = CheckParse.ping(sh("/sbin/ping6", ["-c", "3", "-i", "0.2", "2606:4700:4700::1111"], timeout: 6))
            if (v6?.loss ?? 100) >= 100 {
                out.append(Check(id: "net-ipv6", area: .network, title: "IPv6 is configured but does not work", status: .warning,
                                 detail: "Apps try IPv6 first and wait before falling back, which feels like slow loading.",
                                 steps: ["Restart the router; if it persists, set Configure IPv6 to Link-local only in Network, Details, TCP/IP."]))
            }
        }
        // Clock: TLS and two-factor codes fail when the clock is off.
        if let off = CheckParse.clockOffset(sh("/usr/bin/sntp", ["-t", "2", "time.apple.com"], timeout: 6)), abs(off) > 2 {
            out.append(Check(id: "clock", area: .network, title: "Clock is \(String(format: "%.0f", abs(off))) s \(off > 0 ? "behind" : "ahead")", status: abs(off) > 30 ? .warning : .info,
                             detail: "Secure connections and two-factor codes fail when the clock drifts.",
                             fixes: [.admin(label: "Sync clock now", command: .syncClock)]))
        }
        return out
    }

    // MARK: System

    /// Launch agents and daemons whose program no longer exists: leftovers of removed apps.
    nonisolated static func brokenLaunchItems() -> [(plist: String, label: String, program: String, user: Bool)] {
        let fm = FileManager.default
        var broken: [(plist: String, label: String, program: String, user: Bool)] = []
        let dirs = [(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path, true), ("/Library/LaunchAgents", false), ("/Library/LaunchDaemons", false)]
        for (dir, user) in dirs {
            for f in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where f.hasSuffix(".plist") {
                let p = dir + "/" + f
                guard let d = NSDictionary(contentsOfFile: p) as? [String: Any] else { continue }
                let item = CheckParse.launchItem(d)
                guard let prog = item.program, prog.hasPrefix("/"), !fm.fileExists(atPath: prog) else { continue }
                broken.append((p, item.label, prog, user))
            }
        }
        return broken
    }

    /// Stops the listed launch items and moves them to the Trash. It looks again first and
    /// only touches plists that are still broken, so a stale checkup cannot remove a live item.
    /// Your own go straight to the Trash; /Library ones go through one admin prompt into a
    /// staging folder you own, then to the Trash from there.
    nonisolated static func removeLaunchItems(_ plists: [String]) -> (removed: Int, failed: Int, cancelled: Bool) {
        let fm = FileManager.default
        let wanted = Set(plists)
        let still = brokenLaunchItems().filter { wanted.contains($0.plist) }
        let uid = getuid()
        var removed = 0, failed = 0
        for item in still where item.user {
            _ = status("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])
            if (try? fm.trashItem(at: URL(fileURLWithPath: item.plist), resultingItemURL: nil)) != nil { removed += 1 } else { failed += 1 }
        }
        let system = still.filter { !$0.user }.map(\.plist)
        guard !system.isEmpty else { return (removed, failed, false) }
        let staging = fm.temporaryDirectory.appendingPathComponent("SystemSentinel-startup-items-\(UUID().uuidString)")
        for sub in CheckParse.systemLaunchDirs.values {
            try? fm.createDirectory(at: staging.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        guard let command = CheckParse.removeSystemItemsCommand(plists: system, staging: staging.path, uid: uid) else {
            try? fm.removeItem(at: staging)
            return (removed, failed + system.count, false)
        }
        // The command holds only paths that passed the shape check: no quotes or backslashes.
        let ok = status("/usr/bin/osascript", ["-e", "do shell script \"\(command)\" with administrator privileges"]) == 0
        var moved = 0, stuck = 0
        for sub in CheckParse.systemLaunchDirs.values {
            let dir = staging.appendingPathComponent(sub)
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                if (try? fm.trashItem(at: dir.appendingPathComponent(f), resultingItemURL: nil)) != nil { moved += 1 } else { stuck += 1 }
            }
        }
        // Only an empty staging folder is deleted: a file the Trash refused stays there.
        if stuck == 0 { try? fm.removeItem(at: staging) }
        removed += moved
        failed += stuck + system.filter { fm.fileExists(atPath: $0) }.count
        let cancelled = !ok && moved == 0 && stuck == 0
        return (removed, failed, cancelled)
    }

    /// Security, DLP and network agents: from the system extensions and running processes.
    nonisolated static func securityAgents() -> [SecurityAgent] {
        let procs = sh("/bin/ps", ["-axo", "pcpu=,comm="], timeout: 5).split(separator: "\n").compactMap { line -> (name: String, cpu: Double)? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let cpu = Double(t[..<sp].replacingOccurrences(of: ",", with: ".")) else { return nil }
            return (String(t[sp...]).trimmingCharacters(in: .whitespaces), cpu)
        }
        return SecurityAgents.find(extensions: sh("/usr/bin/systemextensionsctl", ["list"], timeout: 5), processes: procs)
    }

    nonisolated static func systemChecks() -> [Check] {
        var out: [Check] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // Launch agents and daemons whose program no longer exists: leftovers of removed apps.
        let broken = brokenLaunchItems()
        if !broken.isEmpty {
            let system = broken.filter { !$0.user }
            out.append(Check(id: "broken-agents", area: .system, title: "\(broken.count) startup item\(broken.count == 1 ? "" : "s") point at programs that are gone", status: .warning,
                             detail: "Left behind by apps that were removed. macOS keeps trying to start them, which wastes time at login and fills the log.",
                             why: "Remove stops them and moves their files to the Trash. \(system.isEmpty ? "" : "Items in /Library ask for your admin password once. ")Only items whose program is missing are touched, so nothing that still runs is affected. If your IT team installed one, its management tool may put it back.",
                             fixes: [.removeAgents(label: broken.count == 1 ? "Remove it" : "Remove all \(broken.count)", plists: broken.map(\.plist))]
                                + system.prefix(2).map { .reveal(label: "Show \($0.label)", path: $0.plist) },
                             items: broken.map { "\($0.label) → \($0.program)" }))
        }
        // Apps that keep crashing, and kernel panics.
        func reports(_ dir: String) -> [(name: String, date: Date)] {
            ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).map {
                ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
        }
        let userReports = reports(home.appendingPathComponent("Library/Logs/DiagnosticReports").path)
        let sysReports = reports("/Library/Logs/DiagnosticReports")
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let userDir = home.appendingPathComponent("Library/Logs/DiagnosticReports").path
        let crashFiles = (userReports.map { (dir: userDir, file: $0) } + sysReports.map { (dir: "/Library/Logs/DiagnosticReports", file: $0) })
            .filter { $0.file.date >= weekAgo }
        let crashes = CheckParse.crashCounts(crashFiles.map(\.file), since: weekAgo).filter { $0.count >= 3 }.map { c -> CheckParse.Crashes in
            let mine = crashFiles.filter { $0.file.name.hasPrefix(c.process + "-") && ($0.file.name.hasSuffix(".ips") || $0.file.name.hasSuffix(".crash")) }
            // The newest report's header says whether it is an app (it has a bundle id).
            let newest = mine.max { $0.file.date < $1.file.date }
            let header = newest.flatMap { try? FileHandle(forReadingFrom: URL(fileURLWithPath: $0.dir + "/" + $0.file.name)).readData(ofLength: 4096) }
            return CheckParse.Crashes(process: c.process, dates: mine.map(\.file.date),
                                      bundleID: header.flatMap { CheckParse.crashBundleID(String(decoding: $0, as: UTF8.self)) })
        }
        if let crash = CheckParse.crashCheck(crashes, reports: userDir) { out.append(crash) }
        let agents = securityAgents()
        let note = SecurityAgents.suspectNote(agents)
        let panics = sysReports.filter { $0.name.hasPrefix("panic") && $0.date >= Date().addingTimeInterval(-30 * 86_400) }
        if !panics.isEmpty {
            out.append(Check(id: "panics", area: .system, title: "\(panics.count) unexpected restart\(panics.count == 1 ? "" : "s") (kernel panic) in 30 days", status: panics.count >= 2 ? .problem : .warning,
                             detail: "The Mac crashed and restarted itself. Repeated panics usually point at a peripheral, a driver, security software or failing hardware.",
                             why: note.map { $0 + " Note what you were doing at each panic: if it is always heavy file work, tell IT which agent and the times." },
                             steps: (note == nil ? [] : ["If the panics come during heavy file work (exporting many files, unzipping, builds), report it to IT with the times: the security agent is the likely cause."])
                                + ["Unplug hubs and docks to see if they stop.", "Update macOS.", "If they continue, run Apple Diagnostics (hold the power button at startup, then Command-D)."],
                             fixes: [.reveal(label: "Show panic reports", path: "/Library/Logs/DiagnosticReports")],
                             items: panics.sorted { $0.date > $1.date }.prefix(5).map { $0.date.formatted(date: .abbreviated, time: .shortened) }))
        }
        out.append(CheckupStore.loginCheck())
        if !agents.isEmpty {
            let busy = agents.filter { $0.cpu >= 50 }
            let watching = agents.filter(\.suspect)
            out.append(Check(id: "security-agents", area: .system,
                             title: busy.isEmpty ? "\(agents.count) security or network agent\(agents.count == 1 ? "" : "s") on this Mac: \(agents.prefix(3).map(\.name).joined(separator: ", "))\(agents.count > 3 ? "…" : "")"
                                                 : "\(busy.map(\.name).joined(separator: ", ")) \(busy.count == 1 ? "is" : "are") busy: \(Int(busy.reduce(0) { $0 + $1.cpu }))% CPU",
                             status: busy.isEmpty ? .info : .warning,
                             detail: watching.isEmpty ? "Tunnels that carry your traffic. They rarely slow the Mac itself."
                                : "They inspect what the Mac does as it happens. Normally unnoticed, but when one falls behind it can make the whole Mac slow, freeze, or restart itself.",
                             why: note,
                             steps: busy.isEmpty ? [] : ["This is company software: do not remove it. Tell IT what you were doing and when it was busy."],
                             items: agents.map(\.line)))
        }
        if let on = CheckParse.spotlightOn(sh("/usr/bin/mdutil", ["-s", "/"])), !on {
            out.append(Check(id: "spotlight", area: .system, title: "Spotlight indexing is off", status: .info,
                             detail: "Search in Finder, Mail and Spotlight will not find files. The Storage tab also uses Spotlight.",
                             fixes: [.admin(label: "Turn indexing on", command: .spotlightOn)]))
        }
        // Time Machine.
        let tm = sh("/usr/bin/tmutil", ["latestbackup"], timeout: 15)
        if let last = CheckParse.backupDate(tm) {
            let days = Date().timeIntervalSince(last) / 86_400
            out.append(Check(id: "backup", area: .backup, title: days < 1.5 ? "Backed up \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))" : "Last backup was \(Int(days)) days ago",
                             status: days > 14 ? .problem : (days > 3 ? .warning : .ok), detail: "Time Machine.",
                             fixes: days > 1 ? [.run(label: "Back up now", path: "/usr/bin/tmutil", args: ["startbackup", "--auto"])] : []))
        } else {
            let configured = !sh("/usr/bin/tmutil", ["destinationinfo"], timeout: 10).contains("No destinations")
            out.append(Check(id: "backup", area: .backup, title: configured ? "Time Machine has not completed a backup it can reach" : "No Time Machine backup set up",
                             status: .warning, detail: configured ? "The backup disk may be disconnected or full." : "If this Mac is lost or the disk fails, files that are not in iCloud or another backup are gone.",
                             fixes: [.settings(label: "Time Machine settings", url: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")]
                                + (configured ? [.run(label: "Back up now", path: "/usr/bin/tmutil", args: ["startbackup", "--auto"])] : [])))
        }
        // Stuck print jobs.
        let jobs = sh("/usr/bin/lpstat", ["-o"], timeout: 5).split(separator: "\n").filter { !$0.isEmpty }
        if !jobs.isEmpty {
            out.append(Check(id: "print", area: .system, title: "\(jobs.count) print job\(jobs.count == 1 ? "" : "s") waiting", status: .info,
                             detail: "A stuck job blocks everything after it.", fixes: [.run(label: "Cancel all print jobs", path: "/usr/bin/cancel", args: ["-a", "-"])]))
        }
        // Homebrew packages with newer versions.
        if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { fm.isExecutableFile(atPath: $0) }) {
            if let o = CheckParse.brewOutdated(sh(brew, ["outdated", "--json=v2"], timeout: 60)), o.formulae.count + o.casks.count >= 5 {
                let names = o.formulae.map(\.name) + o.casks
                let size = brewUpgradeSize(brew: brew, o)
                out.append(Check(id: "brew", area: .apps, title: "\(names.count) Homebrew packages are out of date" + (size > 0 ? ", about \(ReportDocument.bytes(size))" : ""), status: .info,
                                 detail: "Older tools miss security fixes."
                                    + (size > 0 ? " The versions installed now take about \(ReportDocument.bytes(size)); the new ones are usually similar, so that is roughly what the upgrade downloads and installs, with old versions removed afterwards." : ""),
                                 fixes: [.run(label: "Upgrade all (takes a while)", path: brew, args: ["upgrade"])], items: names))
            }
        }
        return out
    }

    /// Rough size of a Homebrew upgrade: what the outdated packages take now (each formula's
    /// installed version in the Cellar, each cask's folder and the apps or fonts it put in
    /// place). Bounded to 20 seconds; 0 when nothing could be measured.
    nonisolated static func brewUpgradeSize(brew: String, _ o: (formulae: [(name: String, installed: String?)], casks: [String])) -> UInt64 {
        let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent()
        let end = Date().addingTimeInterval(20)
        var paths = o.formulae.compactMap { f in f.installed.map { prefix.appendingPathComponent("Cellar/\(f.name)/\($0)").path } }
        if !o.casks.isEmpty {
            paths += o.casks.map { prefix.appendingPathComponent("Caskroom/\($0)").path }
            paths += CheckParse.caskTargets(sh(brew, ["info", "--cask", "--json=v2"] + o.casks, timeout: 30))
        }
        return paths.reduce(UInt64(0)) { sum, p in
            sum + (Date() < end ? (DiskUsage.size(of: URL(fileURLWithPath: p), deadline: end)?.bytes ?? 0) : 0)
        }
    }

    nonisolated static func updatesCheck(_ pending: [String]?, checking: Bool) -> Check {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        guard let pending else {
            return Check(id: "macos-updates", area: .security, title: "macOS \(os)", status: .info,
                         detail: checking ? "Checking for updates… Software Update can take a few minutes."
                                          : "Software Update did not answer, so updates could not be checked. Open Software Update to look.",
                         fixes: checking ? [] : [.settings(label: "Open Software Update", url: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")])
        }
        if pending.isEmpty {
            return Check(id: "macos-updates", area: .security, title: "macOS is up to date", status: .ok, detail: "macOS \(os).")
        }
        return Check(id: "macos-updates", area: .security, title: "\(pending.count) update\(pending.count == 1 ? "" : "s") waiting: \(pending.prefix(2).joined(separator: ", "))", status: .warning,
                     detail: "Updates close security holes that are often already being used. macOS \(os).",
                     fixes: [.settings(label: "Open Software Update", url: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")],
                     items: pending)
    }

    /// System Sentinel's own start at login: without it nothing is watched after a restart.
    nonisolated static func loginCheck() -> Check {
        switch LoginItem.state {
        case .on:
            return Check(id: "login-item", area: .system, title: "System Sentinel starts at login", status: .ok,
                         detail: "And starts again by itself if it ever crashes, so monitoring has no gaps.")
        case .plainLoginItem:
            return Check(id: "login-item", area: .system, title: "System Sentinel starts at login", status: .ok,
                         detail: "Quit and reopen it once so it also restarts by itself after a crash.")
        case .needsApproval:
            return Check(id: "login-item", area: .system, title: "System Sentinel is not allowed to start at login", status: .warning,
                         detail: "It is switched off in Login Items, so after a restart nothing is watched or recorded until you open it.",
                         steps: ["In Login Items, under Allow in the Background, turn System Sentinel on."],
                         fixes: [.settings(label: "Open Login Items", url: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")])
        case .off:
            return Check(id: "login-item", area: .system, title: "System Sentinel does not start at login", status: .warning,
                         detail: "After a restart nothing is watched or recorded until you open it, so a slow or crashing startup is missed.",
                         fixes: [.startAtLogin(label: "Start at login")])
        }
    }

    // MARK: Fixes

    func perform(_ fix: Check.Fix, in check: Check) {
        let key = check.id + fix.label
        switch fix {
        case .settings(_, let url), .web(_, let url):
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .reveal(_, let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .run(let label, let path, let args):
            working.insert(key)
            Task.detached {
                let ok = CheckupStore.status(path, args) == 0
                await MainActor.run {
                    self.working.remove(key)
                    self.toast(Model.Toast(ok: ok, title: ok ? "\(label): done" : "\(label) did not finish", detail: nil))
                    self.run()
                }
            }
        case .admin(let label, let command):
            working.insert(key)
            let front = frontWindowNumber()
            Task.detached {
                // The command is a fixed string from AdminCommand: nothing read off the Mac goes in.
                let ok = CheckupStore.status("/usr/bin/osascript", ["-e", "do shell script \"\(command.rawValue)\" with administrator privileges"]) == 0
                await MainActor.run {
                    comeBack(to: front)
                    self.working.remove(key)
                    self.toast(Model.Toast(ok: ok, title: ok ? "\(label): done" : "\(label) was not changed", detail: ok ? nil : "The password prompt was cancelled or refused."))
                    self.run()
                }
            }
        case .startAtLogin(let label):
            Model.current?.launchAtLogin = true
            let ok = LoginItem.state == .on
            toast(Model.Toast(ok: ok, title: ok ? "\(label): done" : "\(label) did not work",
                              detail: ok ? "It starts at every login and again if it ever crashes." : Model.current?.lastError))
            run()
        case .removeAgents(let label, let plists):
            working.insert(key)
            let front = frontWindowNumber()
            Task.detached {
                let r = CheckupStore.removeLaunchItems(plists)
                await MainActor.run {
                    comeBack(to: front)
                    self.working.remove(key)
                    if r.cancelled && r.removed == 0 {
                        self.toast(Model.Toast(ok: false, title: "\(label): nothing was changed", detail: "The password prompt was cancelled or refused."))
                    } else {
                        self.toast(Model.Toast(ok: r.failed == 0 && !r.cancelled,
                                               title: "Removed \(r.removed) startup item\(r.removed == 1 ? "" : "s")" + (r.failed > 0 ? ", \(r.failed) could not be" : ""),
                                               detail: "Moved to the Trash. To undo, drag a file back to the LaunchAgents or LaunchDaemons folder it came from."))
                    }
                    self.run()
                }
            }
        }
    }

    /// The everyday restarts, always available.
    static let toolbox: [(title: String, about: String, symbol: String, fix: Check.Fix)] = [
        ("Flush DNS cache", "Websites not loading or going to the wrong place after a network change.", "network", .admin(label: "Flush DNS cache", command: .flushDNS)),
        ("Reset network", "Pages half load, or the Mac keeps an old address after moving network. Flushes DNS and the address table and asks the router for a fresh address. Connections drop for a few seconds.", "arrow.triangle.2.circlepath",
         .admin(label: "Reset network", command: .resetNetwork)),
        ("Restart sound", "No sound, crackling, or the wrong output device stuck.", "speaker.wave.2.fill", .admin(label: "Restart sound", command: .restartAudio)),
        ("Restart Bluetooth", "Devices that will not connect or keep dropping. Bluetooth keyboards and mice drop for a few seconds.", "dot.radiowaves.left.and.right", .admin(label: "Restart Bluetooth", command: .restartBluetooth)),
        ("Restart Finder", "Finder windows frozen or not updating.", "folder.fill", .run(label: "Restart Finder", path: "/usr/bin/killall", args: ["Finder"])),
        ("Restart Dock", "Dock, Mission Control or app switching stuck.", "dock.rectangle", .run(label: "Restart Dock", path: "/usr/bin/killall", args: ["Dock"])),
        ("Restart menu bar", "Menu bar icons missing or not responding.", "menubar.rectangle", .run(label: "Restart menu bar", path: "/usr/bin/killall", args: ["SystemUIServer", "ControlCenter"])),
        ("Rebuild Spotlight index", "Search cannot find files you know are there. Indexing then takes hours and uses CPU.", "magnifyingglass", .admin(label: "Rebuild Spotlight index", command: .spotlightReindex)),
        ("Sync clock", "Certificate errors or two-factor codes rejected.", "clock.fill", .admin(label: "Sync clock", command: .syncClock)),
        ("Restart Wi-Fi", "Connected but nothing loads, or stuck on an old network. Turns Wi-Fi off and on, which also asks for a fresh address.", "wifi",
         .run(label: "Restart Wi-Fi", path: "/bin/sh", args: ["-c", wifiCycle])),
        ("Restart iCloud sync", "iCloud Drive stuck on Waiting or not uploading.", "icloud.fill",
         .run(label: "Restart iCloud sync", path: "/usr/bin/killall", args: ["bird", "cloudd"])),
        ("Restart AirDrop and Handoff", "AirDrop cannot see nearby devices, or copy and paste between devices stops.", "airplayaudio",
         .run(label: "Restart AirDrop and Handoff", path: "/usr/bin/killall", args: ["sharingd"])),
        ("Restart notifications", "Notifications stop appearing, or stay stuck on screen.", "bell.badge.fill",
         .run(label: "Restart notifications", path: "/usr/bin/killall", args: ["NotificationCenter"])),
        ("Reset Quick Look", "Space-bar previews blank, or thumbnails out of date.", "eye.fill",
         .run(label: "Reset Quick Look", path: "/usr/bin/qlmanage", args: ["-r", "cache"])),
        ("Fix Open With", "The Open With menu lists apps twice, or files open in the wrong app. Takes a minute.", "arrow.up.forward.app.fill",
         .run(label: "Fix Open With", path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
              args: ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])),
        ("Clear font cache", "Text drawn in the wrong font, garbled characters, or a font that will not show. Takes effect after logging out and in.", "textformat",
         .run(label: "Clear font cache", path: "/usr/bin/atsutil", args: ["databases", "-removeUser"])),
        ("Clear print queue", "A stuck print job blocks everything after it.", "printer.fill", .admin(label: "Clear print queue", command: .cancelPrintJobs)),
        ("Reset printing system", "Printing still broken after clearing the queue. Removes every printer: add them again in System Settings, Printers & Scanners.", "printer.dotmatrix.fill",
         .admin(label: "Reset printing system", command: .resetPrinting)),
        ("Rebuild Mail index", "Mail search misses messages, or mailboxes show wrong counts. Quits Mail, moves its index to the Trash and opens Mail, which rebuilds it over a few minutes. Needs Full Disk Access.", "envelope.badge.fill",
         .run(label: "Rebuild Mail index", path: "/bin/sh", args: ["-c", ToolboxScript.rebuildMailIndex])),
        ("Clear recent items", "Empties the recent apps, documents and servers lists in the Apple menu, Finder and each app's Open Recent. Favourites are kept.", "clock.arrow.circlepath",
         .run(label: "Clear recent items", path: "/bin/sh", args: ["-c", ToolboxScript.clearRecentItems])),
        ("Reset Microsoft sign-in", "Outlook, Teams or Office keep asking to sign in, or sign in as the wrong account. Quits the Microsoft apps and deletes their saved sign-in tokens; you then sign in again. Company Portal and device registration are not touched.", "key.fill",
         .run(label: "Reset Microsoft sign-in", path: "/bin/sh", args: ["-c", ToolboxScript.resetMicrosoftSignIn])),
        ("Restart Software Update", "Software Update stuck on Checking or a download that never finishes.", "arrow.down.circle.fill",
         .admin(label: "Restart Software Update", command: .restartSoftwareUpdate)),
    ]

    nonisolated static var wifiCycle: String { Diagnose.wifiCycle }

    nonisolated static func status(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Runs a tool and returns what it printed (stdout and stderr), killing it after `timeout`.
nonisolated func sh(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    // Every command we run waits behind the apps you are using.
    p.qualityOfService = .utility
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    guard (try? p.run()) != nil else {
        Diagnostics.report("checkup", "\(URL(fileURLWithPath: path).lastPathComponent) would not start")
        return ""
    }
    let timer = DispatchWorkItem {
        guard p.isRunning else { return }
        p.terminate()
        // Some tools ignore that and would hold this thread, and their own core, for good.
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
        Diagnostics.report("checkup", "\(URL(fileURLWithPath: path).lastPathComponent) \(args.first ?? "") took over \(Int(timeout)) s and was stopped")
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    timer.cancel()
    return String(data: data, encoding: .utf8) ?? ""
}
