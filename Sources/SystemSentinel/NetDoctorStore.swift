import AppKit
import Network
import SentinelCore
import Security
import UserNotifications

/// The Network tab's doctor: each DNS server checked on its own, made-up answers, sign-in
/// pages, the work name, HTTPS inspection and whether developer tools trust it, a speed test,
/// and phone hotspots joined by accident.
extension NetworkStore {
    nonisolated static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SystemSentinel", isDirectory: true)
    }
    nonisolated static var historyURL: URL { supportDir.appendingPathComponent("dns-24h.json") }
    nonisolated static var speedURL: URL { supportDir.appendingPathComponent("speed-test.json") }
    nonisolated static var pemURL: URL { supportDir.appendingPathComponent("inspection-ca.pem") }
    nonisolated(unsafe) static var pathMonitor: NWPathMonitor?

    func loadDoctor() {
        if let d = try? Data(contentsOf: Self.historyURL), let h = try? JSONDecoder().decode(DNSHistory.self, from: d) { dnsHistory = h }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Self.speedURL) { speed = try? dec.decode(SpeedResult.self, from: d) }
        if FileManager.default.fileExists(atPath: Self.pemURL.path) { exportedPEM = Self.pemURL.path }
    }

    func startDoctor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.expensive = path.isExpensive }
        }
        monitor.start(queue: .global(qos: .utility))
        Self.pathMonitor = monitor
        timers += [
            Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in Task { @MainActor in self?.runDNSDoctor() } },
            Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkInspection() } },
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.runDNSDoctor() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in self?.checkInspection() }
    }

    func recordLookup(ok: Bool, ms: Double?) {
        dnsHistory.record(ok: ok, ms: ms, at: Date())
        if !readOnly, let data = try? JSONEncoder().encode(dnsHistory) { Diagnostics.write(data, to: Self.historyURL, what: "DNS history") }
    }

    // MARK: DNS

    var workHost: String { (UserDefaults.standard.string(forKey: "dnsWorkHost") ?? "").trimmingCharacters(in: .whitespaces) }

    func runDNSDoctor() {
        guard !doctorRunning else { return }
        doctorRunning = true
        let work = workHost
        Task.detached(priority: .utility) {
            var r = DNSReport(at: Date())
            r.resolvers = NetParse.resolvers(sh("/usr/sbin/scutil", ["--dns"], timeout: 4))
            // Each server once: the main ones by a real name, split ones by their own domain.
            // A VPN lists the same servers for each of its domains: one row per server, naming
            // the domains, asked about the first.
            var seen = Set<String>()
            var targets: [(String, String?)] = []
            var domainsOf: [String: [String]] = [:]
            for res in r.resolvers where !res.mdns {
                let domain = res.supplemental ? res.domain : nil
                guard !res.supplemental || domain != nil else { continue }
                for s in res.servers {
                    let key = s + (domain == nil ? "" : "/split")
                    if let d = domain { domainsOf[s, default: []].append(d) }
                    guard !seen.contains(key), targets.count < 10 else { continue }
                    seen.insert(key)
                    targets.append((s, domain))
                }
            }
            // Supplemental resolvers with no domain (VPNs often add one) still answer everything.
            if !r.resolvers.contains(where: { !$0.supplemental && !$0.mdns && !$0.servers.isEmpty }) {
                for res in r.resolvers where res.supplemental && res.domain == nil {
                    for s in res.servers where !seen.contains(s) { seen.insert(s); targets.append((s, nil)) }
                }
            }
            r.servers = await withTaskGroup(of: (Int, DNSReport.Server).self) { group in
                for (i, t) in targets.enumerated() {
                    group.addTask {
                        let args = t.1.map { ["@\(t.0)", $0, "SOA", "+time=2", "+tries=1"] } ?? ["@\(t.0)", "www.apple.com", "+time=2", "+tries=1"]
                        let d = NetParse.dig(sh("/usr/bin/dig", args, timeout: 5))
                        let doms = domainsOf[t.0] ?? []
                        let label = t.1 == nil ? nil : (doms.count <= 2 ? doms.joined(separator: ", ") : "\(doms[0]) and \(doms.count - 1) more work domains")
                        return (i, DNSReport.Server(address: t.0, domain: label, ms: d?.ms, status: d?.status))
                    }
                }
                var out: [(Int, DNSReport.Server)] = []
                for await x in group { out.append(x) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            // A name that cannot exist must not resolve.
            let made = "sentinel-check-\(UUID().uuidString.prefix(12).lowercased()).com"
            r.madeUp = NetworkStore.resolve(made).addresses
            r.captive = await NetworkStore.captivePortal()
            if !work.isEmpty {
                let t0 = Date()
                let w = NetworkStore.resolve(work)
                r.workHost = work
                r.workResolved = !w.addresses.isEmpty
                r.workMs = Int(Date().timeIntervalSince(t0) * 1000)
            }
            r.hosts = NetParse.hosts((try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? "")
            let report = r
            await MainActor.run {
                self.dns = report
                self.doctorRunning = false
                self.ran(.networkDoctor)
                self.refreshAll()
            }
        }
    }

    /// Through the Mac's own resolver (VPN rules, split DNS, /etc/hosts, the cache).
    nonisolated static func resolve(_ name: String) -> (addresses: [String], ok: Bool) {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0 else { return ([], false) }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p = res
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let a = String(cString: buf)
                if !out.contains(a) { out.append(a) }
            }
            p = ai.pointee.ai_next
        }
        return (out, true)
    }

    /// Apple's own check: the page says Success unless a sign-in page is in the way.
    nonisolated static func captivePortal() async -> Bool {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html"),
              let (data, _) = try? await URLSession(configuration: cfg).data(from: url) else { return false }
        return !(String(data: data, encoding: .utf8) ?? "").contains("Success")
    }

    // MARK: HTTPS inspection

    func checkInspection() {
        guard !inspecting else { return }
        inspecting = true
        Task.detached(priority: .utility) {
            var found: (TLSInspection, Data)?
            // The first answer, unless a later site turns out to be inspected.
            for host in ["github.com", "registry.npmjs.org", "pypi.org"] {
                guard let r = await TrustProbe.inspect(host) else { continue }
                if found == nil || r.0.intercepted { found = r }
                if r.0.intercepted { break }
            }
            let tools = NetworkStore.scanTools()
            let result = found
            await MainActor.run {
                self.inspecting = false
                self.inspection = result?.0
                self.rootCertificate = result?.1
                self.tools = tools
                self.refreshAll()
            }
        }
    }

    nonisolated static func scanTools() -> [ToolTrust] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".bashrc", ".profile", ".config/fish/config.fish",
                     ".npmrc", ".config/pip/pip.conf", "Library/Application Support/pip/pip.conf", ".pip/pip.conf"]
        var files: [String: String] = [:]
        for p in paths {
            let full = home + "/" + p
            if let t = try? String(contentsOfFile: full, encoding: .utf8) { files[full] = t }
        }
        let gitconfig = (try? String(contentsOfFile: home + "/.gitconfig", encoding: .utf8)) ?? ""
        let gitCA = gitconfig.split(separator: "\n").first { $0.lowercased().contains("sslcainfo") }.map(String.init)
        return ToolTrust.scan(files: files, gitCA: gitCA, pem: pemURL.path)
    }

    /// Saves the inspecting authority's certificate where the tools' settings point.
    func exportCertificate() {
        guard let der = rootCertificate else { return }
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
        if Diagnostics.write(Data(pem.utf8), to: Self.pemURL, what: "the inspection certificate") {
            exportedPEM = Self.pemURL.path
        }
    }

    /// The lines that make every tool not yet set up trust the certificate.
    var setupLines: String {
        tools.filter { !$0.configured }.map(\.how).joined(separator: "\n")
    }

    // MARK: Speed test

    func runSpeedTest() {
        guard !speedRunning else { return }
        if link.isHotspot || expensive {
            let a = NSAlert()
            a.messageText = "Run a speed test on mobile data?"
            a.informativeText = "This connection is a phone hotspot or marked as metered. The test moves several hundred megabytes."
            a.addButton(withTitle: "Run anyway")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        speedRunning = true
        Task.detached(priority: .userInitiated) {
            let out = sh("/usr/bin/networkQuality", ["-c", "-s"], timeout: 90)
            let r = SpeedResult.parse(Data(out.utf8), at: Date())
            await MainActor.run {
                self.speedRunning = false
                if let r {
                    self.speed = r
                    let enc = JSONEncoder()
                    enc.dateEncodingStrategy = .iso8601
                    if !self.readOnly, let d = try? enc.encode(r) { Diagnostics.write(d, to: Self.speedURL, what: "speed test result") }
                } else {
                    Diagnostics.report("network", "Speed test (networkQuality) gave no result")
                }
                self.refreshAll()
            }
        }
    }

    // MARK: Phone hotspots

    var onHotspot: Bool { link.isHotspot || expensive }

    func watchHotspot(rx: UInt64, tx: UInt64, at now: Date) {
        for e in hotspot.update(onHotspot: onHotspot, rx: rx, tx: tx, at: now) {
            switch e {
            case .joined:
                hotspotBase = traffic
                notify("Joined a phone's hotspot", "\(link.wifi?.ssid.map { "\($0): " } ?? "")the Mac is using mobile data now. Backups, sync and updates will use it too. Open System Sentinel's Network tab to leave or see what is using it.")
            case .used(let b):
                let top = hotspotApps(paths: nil).first.map { " Most of it: \($0.name), \(ReportDocument.bytes($0.bytes))." } ?? ""
                notify("\(ReportDocument.bytes(b)) of mobile data used", "Still on the phone's hotspot.\(top)")
            case .left(let used, let minutes):
                if used >= 50_000_000 { notify("Left the phone's hotspot", "\(ReportDocument.bytes(used)) of mobile data in \(minutes) min.") }
                hotspotBase = [:]
            }
        }
    }

    func hotspotApps(paths: [Int32: String]?) -> [(name: String, bytes: UInt64, pids: [Int32])] {
        guard hotspot.on else { return [] }
        var acc: [String: (UInt64, [Int32])] = [:]
        for (pid, t) in traffic {
            let base = hotspotBase[pid]
            let now = t.bytesIn + t.bytesOut
            let then = (base?.bytesIn ?? 0) + (base?.bytesOut ?? 0)
            guard now > then else { continue }
            let name = appName(pid: pid, fallback: t.name, paths: paths)
            var a = acc[name] ?? (0, [])
            a.0 += now - then
            a.1.append(pid)
            acc[name] = a
        }
        return acc.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.bytes > $1.bytes }
    }

    /// Wi-Fi off and on: macOS then joins its best known network, ahead of a phone.
    func leaveHotspot() {
        Task.detached {
            _ = sh("/bin/sh", ["-c", CheckupStore.wifiCycle], timeout: 20)
            await MainActor.run { self.refreshAll() }
        }
    }

    func notify(_ title: String, _ body: String) {
        guard !readOnly, UserDefaults.standard.object(forKey: "hotspotAlerts") as? Bool ?? true else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.categoryIdentifier = "info"
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hotspot-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
    }

    func doctorInsights(paths: [Int32: String], at now: Date) -> [Insight] {
        NetworkAnalysis.doctorInsights(dns: dns, history: dnsHistory, speed: speed, inspection: inspection, tools: tools, link: link,
                                       hotspotUsed: hotspot.on ? hotspot.used : nil, hotspotSince: hotspot.since,
                                       hotspotApps: hotspotApps(paths: paths), at: now)
    }
}

/// Opens a TLS connection and reads who signed the chain, without sending a request body.
final class TrustProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private var chain: [SecCertificate] = []

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        }
        completionHandler(.performDefaultHandling, nil)
    }

    static func inspect(_ host: String) async -> (TLSInspection, Data)? {
        let probe = TrustProbe()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: cfg, delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: URL(string: "https://\(host)/")!)
        req.httpMethod = "HEAD"
        _ = try? await session.data(for: req)
        guard let root = probe.chain.last else { return nil }
        let der = SecCertificateCopyData(root) as Data
        var anchors: CFArray?
        SecTrustCopyAnchorCertificates(&anchors)
        let system = Set(((anchors as? [SecCertificate]) ?? []).map { SecCertificateCopyData($0) as Data })
        let name = SecCertificateCopySubjectSummary(root) as String? ?? "an unknown authority"
        return (TLSInspection(host: host, root: name, rootIsSystem: system.contains(der)), der)
    }
}
