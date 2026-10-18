import Foundation

// MARK: DNS: what is configured

/// One resolver from `scutil --dns`: the default ones answer everything, supplemental ones
/// only their domain (split DNS, as VPNs set up for internal names).
public struct Resolver: Equatable, Sendable {
    public var domain: String?
    public var servers: [String] = []
    public var searchDomains: [String] = []
    public var supplemental = false
    public var mdns = false
    public init(domain: String? = nil, servers: [String] = [], searchDomains: [String] = [], supplemental: Bool = false, mdns: Bool = false) {
        self.domain = domain; self.servers = servers; self.searchDomains = searchDomains
        self.supplemental = supplemental; self.mdns = mdns
    }
}

/// What `dig` said for one query.
public struct DigResult: Equatable, Sendable {
    /// NOERROR, NXDOMAIN, SERVFAIL, REFUSED…
    public let status: String
    public let ms: Int?
    /// A and AAAA addresses in the answer.
    public let addresses: [String]
    public init(status: String, ms: Int?, addresses: [String]) {
        self.status = status; self.ms = ms; self.addresses = addresses
    }
}

public struct HostsEntry: Equatable, Sendable {
    public let address: String
    public let names: [String]
}

extension NetParse {
    /// Every resolver in the first section of `scutil --dns` (the second repeats them per
    /// interface).
    public static func resolvers(_ s: String) -> [Resolver] {
        var out: [Resolver] = []
        var cur: Resolver?
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (for scoped queries)") { break }
            if line.hasPrefix("resolver #") {
                if let c = cur { out.append(c) }
                cur = Resolver()
                continue
            }
            guard cur != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("nameserver[") { cur?.servers.append(value) }
            else if key.hasPrefix("search domain[") { cur?.searchDomains.append(value) }
            else if key == "domain" { cur?.domain = value }
            else if key == "flags" { cur?.supplemental = value.contains("Supplemental") }
            else if key == "options" { cur?.mdns = value.contains("mdns") }
        }
        if let c = cur { out.append(c) }
        return out
    }

    /// `dig` output. Nil when no server answered at all.
    public static func dig(_ s: String) -> DigResult? {
        if s.contains("no servers could be reached") || s.contains("timed out") && !s.contains("status:") { return nil }
        guard let r = s.range(of: "status: ") else { return nil }
        let status = String(s[r.upperBound...].prefix { $0.isLetter })
        var ms: Int?
        var addrs: [String] = []
        var inAnswer = false
        for line in s.split(separator: "\n") {
            if line.hasPrefix(";; ANSWER SECTION") { inAnswer = true; continue }
            if line.hasPrefix(";;") { inAnswer = false }
            if line.hasPrefix(";; Query time:") {
                ms = Int(line.split(separator: " ").dropFirst(3).first ?? "")
            }
            guard inAnswer else { continue }
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if f.count >= 5, f[3] == "A" || f[3] == "AAAA" { addrs.append(String(f[4])) }
        }
        return DigResult(status: status, ms: ms, addresses: addrs)
    }

    /// /etc/hosts lines other than the defaults every Mac has.
    public static func hosts(_ s: String) -> [HostsEntry] {
        s.split(separator: "\n").compactMap { raw in
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 2 else { return nil }
            let names = Array(f.dropFirst())
            if Set(names).isSubset(of: ["localhost", "broadcasthost"]) { return nil }
            return HostsEntry(address: f[0], names: names)
        }
    }
}

// MARK: DNS: what happened

/// How each DNS server, and the Mac's own lookup path, answered just now.
public struct DNSReport: Equatable, Sendable {
    public struct Server: Equatable, Sendable {
        public let address: String
        /// Answers for these domains only (split DNS), or nil for everything.
        public let domain: String?
        public let ms: Int?
        public let status: String?
        public var ok: Bool { status == "NOERROR" }
        public init(address: String, domain: String?, ms: Int?, status: String?) {
            self.address = address; self.domain = domain; self.ms = ms; self.status = status
        }
    }
    public var servers: [Server] = []
    /// Addresses returned for a name that cannot exist; empty is right.
    public var madeUp: [String] = []
    /// The network wants a sign-in page first (hotel, café, guest Wi-Fi).
    public var captive = false
    /// The work name the user asked to check, and how it went.
    public var workHost: String?
    public var workResolved: Bool?
    public var workMs: Int?
    public var resolvers: [Resolver] = []
    public var hosts: [HostsEntry] = []
    public var at: Date
    public init(at: Date) { self.at = at }

    /// The servers that answer every name, in order: the ones that matter most.
    public var main: [Server] { servers.filter { $0.domain == nil } }
    public var splitDomains: [String] { resolvers.filter { $0.supplemental }.compactMap(\.domain) }
}

/// Lookups through the Mac's resolver over the last day, to catch DNS that breaks now and then.
public struct DNSHistory: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let t: Int
        public let ok: Bool
        public let ms: Int?
    }
    public private(set) var points: [Point] = []
    public init() {}

    public mutating func record(ok: Bool, ms: Double?, at now: Date) {
        points.append(Point(t: Int(now.timeIntervalSince1970), ok: ok, ms: ms.map { Int($0.rounded()) }))
        let cutoff = Int(now.timeIntervalSince1970) - 86_400
        points.removeAll { $0.t < cutoff }
    }

    public func failures(since: Date) -> Int {
        points.filter { $0.t >= Int(since.timeIntervalSince1970) && !$0.ok }.count
    }

    /// Slow means over a second: a page visibly waits.
    public func slow(since: Date) -> Int {
        points.filter { $0.t >= Int(since.timeIntervalSince1970) && $0.ok && ($0.ms ?? 0) >= 1000 }.count
    }

    public struct Hour: Equatable, Sendable {
        public let start: Date
        public let lookups: Int
        public let failed: Int
        public let slow: Int
    }

    /// The last 24 hours, one bucket each, oldest first.
    public func hours(at now: Date) -> [Hour] {
        let end = Int(now.timeIntervalSince1970)
        return (0..<24).reversed().map { h in
            let lo = end - (h + 1) * 3600, hi = end - h * 3600
            let p = points.filter { $0.t >= lo && $0.t < hi }
            return Hour(start: Date(timeIntervalSince1970: TimeInterval(lo)), lookups: p.count,
                        failed: p.filter { !$0.ok }.count, slow: p.filter { $0.ok && ($0.ms ?? 0) >= 1000 }.count)
        }
    }
}

// MARK: Speed test

/// macOS's own `networkQuality`: throughput both ways and responsiveness under load, which is
/// what decides whether a call stutters while something else downloads.
public struct SpeedResult: Codable, Equatable, Sendable {
    /// Bits per second.
    public let down: Double
    public let up: Double
    /// Round trips per minute while loaded; higher is better.
    public let rpmDown: Double?
    public let rpmUp: Double?
    /// Milliseconds, idle.
    public let idleRTT: Double?
    public let proxied: Bool
    public let interface: String?
    public let at: Date

    public init(down: Double, up: Double, rpmDown: Double?, rpmUp: Double?, idleRTT: Double?, proxied: Bool, interface: String?, at: Date) {
        self.down = down; self.up = up; self.rpmDown = rpmDown; self.rpmUp = rpmUp
        self.idleRTT = idleRTT; self.proxied = proxied; self.interface = interface; self.at = at
    }

    public static func parse(_ data: Data, at: Date) -> SpeedResult? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let down = (j["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (j["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        let other = j["other"] as? [String: Any]
        let proxy = (other?["proxy_state"] as? [String: Any])?.keys.contains { $0 != "not_proxied" } ?? false
        return SpeedResult(down: down, up: up,
                           rpmDown: (j["dl_responsiveness"] as? NSNumber)?.doubleValue ?? (j["responsiveness"] as? NSNumber)?.doubleValue,
                           rpmUp: (j["ul_responsiveness"] as? NSNumber)?.doubleValue,
                           idleRTT: (j["base_rtt"] as? NSNumber)?.doubleValue, proxied: proxy,
                           interface: j["interface_name"] as? String, at: at)
    }

    /// The worse of the two directions.
    public var rpm: Double? { [rpmDown, rpmUp].compactMap { $0 }.min() }

    public enum Responsiveness: Int, Sendable, Comparable {
        case low, medium, high
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        public var label: String { ["Low", "Medium", "High"][rawValue] }
    }

    /// Apple's bands: under 200 RPM low, 200 to 800 medium, over 800 high.
    public var responsiveness: Responsiveness? {
        guard let r = rpm else { return nil }
        return r < 200 ? .low : (r < 800 ? .medium : .high)
    }

    /// Milliseconds a call's audio waits behind other traffic, from the loaded RPM.
    public var loadedDelay: Double? { rpm.map { 60_000 / max($0, 1) } }

    public static func mbps(_ bits: Double) -> String {
        bits >= 100_000_000 ? "\(Int(bits / 1_000_000)) Mbit/s" : String(format: "%.1f Mbit/s", bits / 1_000_000)
    }
}

// MARK: HTTPS inspection

/// Whether a proxy or security agent re-signs secure traffic, seen by who issued the
/// certificate for a well-known site.
public struct TLSInspection: Equatable, Sendable {
    public let host: String
    /// The certificate chain's top: the authority this Mac had to trust.
    public let root: String
    /// That authority ships with macOS. False means one added to this Mac: a corporate
    /// inspection certificate, an antivirus, or a debugging proxy.
    public let rootIsSystem: Bool
    public init(host: String, root: String, rootIsSystem: Bool) {
        self.host = host; self.root = root; self.rootIsSystem = rootIsSystem
    }
    public var intercepted: Bool { !rootIsSystem }
}

/// Developer tools carry their own list of trusted authorities, so an inspection certificate
/// the Mac trusts is not trusted by them until each is told about it.
public struct ToolTrust: Equatable, Sendable, Identifiable {
    public let tool: String
    public let configured: Bool
    /// Where it is set, or what to add.
    public let how: String
    public var id: String { tool }

    /// `files` maps a path (~/.npmrc, ~/.zshrc…) to its contents; `gitCA` is
    /// `git config --global http.sslCAInfo`.
    public static func scan(files: [String: String], gitCA: String?, pem: String) -> [ToolTrust] {
        func env(_ name: String) -> String? {
            for (path, text) in files where !path.hasSuffix("npmrc") && !path.hasSuffix(".conf") {
                for line in text.split(separator: "\n") {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard !l.hasPrefix("#") else { continue }
                    if l.hasPrefix("export \(name)=") || l.hasPrefix("\(name)=") || l.hasPrefix("set -gx \(name) ") {
                        return (path as NSString).lastPathComponent
                    }
                }
            }
            return nil
        }
        func setting(_ suffix: String, _ key: String) -> String? {
            for (path, text) in files where path.hasSuffix(suffix) {
                for line in text.split(separator: "\n") {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix(key) && l.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                        return (path as NSString).lastPathComponent
                    }
                }
            }
            return nil
        }
        let npm = setting("npmrc", "cafile") ?? env("NODE_EXTRA_CA_CERTS")
        let node = env("NODE_EXTRA_CA_CERTS")
        let py = env("REQUESTS_CA_BUNDLE") ?? env("SSL_CERT_FILE")
        let pip = setting("pip.conf", "cert") ?? env("PIP_CERT") ?? py
        let git = gitCA.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "git config" }
        let curl = env("CURL_CA_BUNDLE") ?? env("SSL_CERT_FILE")
        let aws = env("AWS_CA_BUNDLE")
        return [
            ToolTrust(tool: "Node.js and npm", configured: node != nil || npm != nil,
                      how: (node ?? npm).map { "set in \($0)" } ?? "export NODE_EXTRA_CA_CERTS=\"\(pem)\""),
            ToolTrust(tool: "Python (requests, pip)", configured: py != nil || pip != nil,
                      how: (py ?? pip).map { "set in \($0)" } ?? "export REQUESTS_CA_BUNDLE=\"\(pem)\"  and  pip config set global.cert \"\(pem)\""),
            ToolTrust(tool: "git", configured: git != nil, how: git.map { "set in \($0)" } ?? "git config --global http.sslCAInfo \"\(pem)\""),
            ToolTrust(tool: "curl and OpenSSL tools", configured: curl != nil, how: curl.map { "set in \($0)" } ?? "export CURL_CA_BUNDLE=\"\(pem)\""),
            ToolTrust(tool: "AWS CLI", configured: aws != nil, how: aws.map { "set in \($0)" } ?? "export AWS_CA_BUNDLE=\"\(pem)\""),
        ]
    }
}

// MARK: Phone hotspots

/// Follows the Mac onto and off a phone's hotspot, counting what it uses there, so joining one
/// by accident (Instant Hotspot, auto-join after leaving the office) does not quietly spend
/// mobile data.
public struct HotspotWatch: Sendable {
    public private(set) var since: Date?
    private var start: (rx: UInt64, tx: UInt64)?
    private var last: (rx: UInt64, tx: UInt64)?
    /// Data used since joining, in bytes.
    public private(set) var used: UInt64 = 0
    private var warned = 0
    /// The points at which to say how much has gone: 100 MB, 500 MB, 1 GB, then every GB.
    public static func milestone(_ n: Int) -> UInt64 {
        switch n {
        case 0: return 100_000_000
        case 1: return 500_000_000
        default: return UInt64(n - 1) * 1_000_000_000
        }
    }

    public enum Event: Equatable, Sendable {
        case joined
        case used(UInt64)
        case left(used: UInt64, minutes: Int)
    }

    public init() {}

    public var on: Bool { since != nil }

    public mutating func update(onHotspot: Bool, rx: UInt64, tx: UInt64, at now: Date) -> [Event] {
        defer { last = (rx, tx) }
        if onHotspot, since == nil {
            since = now
            start = (rx, tx)
            used = 0
            warned = 0
            return [.joined]
        }
        if !onHotspot, let s = since {
            let e = Event.left(used: used, minutes: Int(now.timeIntervalSince(s) / 60))
            since = nil
            start = nil
            return [e]
        }
        guard onHotspot, let s = start else { return [] }
        // An interface counter that went back (reconnected) restarts from here.
        if rx < s.rx || tx < s.tx {
            start = (rx >= used ? rx - used : 0, tx)
            return []
        }
        used = (rx - s.rx) + (tx - s.tx)
        var out: [Event] = []
        while used >= Self.milestone(warned) {
            out.append(.used(Self.milestone(warned)))
            warned += 1
        }
        return out.isEmpty ? [] : [out.last!]
    }
}

// MARK: Insights from the checks

extension NetworkAnalysis {
    public static func doctorInsights(dns: DNSReport?, history: DNSHistory, speed: SpeedResult?, inspection: TLSInspection?,
                                      tools: [ToolTrust], link: NetworkLink, hotspotUsed: UInt64?, hotspotSince: Date?,
                                      hotspotApps: [(name: String, bytes: UInt64, pids: [Int32])], at now: Date) -> [Insight] {
        var out: [Insight] = []
        if let d = dns {
            if d.captive {
                var x = Insight(id: "net-captive", tone: .critical, symbol: "hand.raised.fill",
                                title: "This network wants you to sign in",
                                detail: "Hotel, café and guest Wi-Fi block everything until their page is accepted. Apps fail with odd certificate errors meanwhile.")
                x.fixes = [.openURL("http://captive.apple.com", label: "Open the sign-in page")]
                out.append(x)
            }
            if !d.madeUp.isEmpty {
                var x = Insight(id: "net-dns-madeup", tone: .warning, symbol: "questionmark.diamond.fill",
                                title: "DNS answers for names that do not exist",
                                detail: "A made-up name came back as \(d.madeUp.prefix(2).joined(separator: ", ")). The network or provider redirects mistyped names to its own page.")
                x.why = "A correct DNS server says a name does not exist. One that answers anyway sends typos, and some internal names, to an advertising or sign-in page, and can break VPNs and apps that check whether a name exists."
                x.steps = ["If you are not on a sign-in network, use DNS 1.1.1.1 or 8.8.8.8 in Network settings, or ask IT."]
                x.fixes = [.openSettings(.network)]
                out.append(x)
            }
            let main = d.main
            let dead = main.filter { $0.status == nil }
            let slow = main.filter { ($0.ms ?? 0) >= 300 }
            if !main.isEmpty, dead.count == main.count {
                out.append(Insight(id: "net-dns-dead", tone: .critical, symbol: "xmark.icloud.fill",
                                   title: "No DNS server answers",
                                   detail: "\(main.map(\.address).joined(separator: ", ")) all timed out. Nothing that needs a name will load.",
                                   fixes: [.openSettings(.network)]))
            } else if let first = main.first, first.status == nil {
                var x = Insight(id: "net-dns-first", tone: .warning, symbol: "exclamationmark.icloud.fill",
                                title: "The first DNS server, \(first.address), does not answer",
                                detail: "Every lookup waits for it to time out before the next server is tried: pages hang for seconds before loading.")
                x.steps = ["Remove \(first.address) from Network, Details, DNS, or move a working server above it.", "On a VPN, reconnect it, or tell IT which server is down."]
                x.fixes = [.openSettings(.network)]
                out.append(x)
            } else if !dead.isEmpty {
                out.append(Insight(id: "net-dns-some", tone: .info, symbol: "icloud.slash",
                                   title: "\(dead.count) of \(main.count) DNS servers do not answer: \(dead.map(\.address).joined(separator: ", "))",
                                   detail: "Lookups still work through the others, but each time one of these is tried first there is a pause."))
            } else if let s = slow.first {
                out.append(Insight(id: "net-dns-slow", tone: .info, symbol: "tortoise.fill",
                                   title: "DNS server \(s.address) takes \(s.ms ?? 0) ms",
                                   detail: "Good servers answer in under 50 ms. Every new site waits this long first."))
            }
            let split = d.servers.filter { $0.domain != nil && $0.status == nil }
            if let s = split.first, let dom = s.domain {
                out.append(Insight(id: "net-dns-split", tone: .warning, symbol: "building.2.fill",
                                   title: "Work names under \(dom) cannot be looked up",
                                   detail: "The VPN sends them to \(s.address), which does not answer. Internal sites and tools will not open: reconnect the VPN."))
            }
            if let h = d.workHost, d.workResolved == false {
                out.append(Insight(id: "net-dns-work", tone: .warning, symbol: "building.2.crop.circle",
                                   title: "\(h) does not resolve",
                                   detail: link.vpn == nil ? "It is an internal name: is the VPN connected?" : "Even with \(link.vpn!) on. The VPN's DNS may not be in use: reconnect it."))
            }
            let odd = d.hosts.filter { !$0.address.hasPrefix("127.") && $0.address != "::1" && $0.address != "0.0.0.0" }
            if !odd.isEmpty {
                var x = Insight(id: "net-hosts", tone: .info, symbol: "doc.text.fill",
                                title: "/etc/hosts sends \(odd.flatMap(\.names).prefix(3).joined(separator: ", ")) to a fixed address",
                                detail: "These names skip DNS entirely. Fine if you set them up; a stale entry sends a site to an old server for ever.")
                x.fixes = [.reveal(path: "/etc/hosts")]
                out.append(x)
            }
        }
        let day = now.addingTimeInterval(-86_400)
        let fails = history.failures(since: day)
        if fails >= 3 {
            out.append(Insight(id: "net-dns-flaky", tone: fails >= 10 ? .warning : .info, symbol: "waveform.path.badge.minus",
                               title: "DNS failed \(fails) times in the last day",
                               detail: "Lookups that fail now and then are why a page sometimes will not load and then does on reload. The DNS chart below shows when."))
        }
        if let s = speed, now.timeIntervalSince(s.at) < 86_400 {
            if s.responsiveness == .low {
                var x = Insight(id: "net-bufferbloat", tone: .warning, symbol: "phone.down.waves.left.and.right",
                                title: "Calls will stutter when anything downloads: \(Int(s.rpm ?? 0)) RPM",
                                detail: "Under load, each packet waits about \(Int(s.loadedDelay ?? 0)) ms behind the others (idle: \(Int(s.idleRTT ?? 0)) ms).")
                x.why = "The router queues too much data while the line is busy (bufferbloat), so voice and video wait behind downloads, backups and updates."
                x.steps = ["Turn on Smart Queue Management or QoS on the router if it has one.", "Pause big downloads and cloud sync during calls.", "Use Ethernet for calls."]
                out.append(x)
            }
            if s.down < 10_000_000 {
                out.append(Insight(id: "net-slowline", tone: .info, symbol: "speedometer",
                                   title: "Download speed is \(SpeedResult.mbps(s.down))",
                                   detail: "Enough for a call, slow for big files. Run the test again away from the VPN or closer to the router to see what limits it."))
            }
        }
        if let i = inspection, i.intercepted {
            let missing = tools.filter { !$0.configured }
            var x = Insight(id: "net-inspection", tone: missing.isEmpty ? .info : .warning, symbol: "eye.trianglebadge.exclamationmark",
                            title: "Secure traffic is inspected by \(i.root)",
                            detail: missing.isEmpty ? "Developer tools are set up to trust it."
                                : "Browsers trust it, but \(missing.map(\.tool).prefix(3).joined(separator: ", ")) do not: they fail with certificate errors (SELF_SIGNED_CERT_IN_CHAIN, CERTIFICATE_VERIFY_FAILED).")
            x.why = "A corporate proxy or security agent decrypts HTTPS to scan it and re-signs each site with its own certificate. macOS was told to trust that certificate; tools with their own trust list were not."
            if !missing.isEmpty { x.steps = ["Export the certificate (HTTPS inspection card below), then add the line it shows for each tool to ~/.zshrc."] }
            x.fixes = [.review(card: "inspection", label: "Set up tools")]
            out.append(x)
        }
        if let since = hotspotSince, let used = hotspotUsed {
            let minutes = Int(now.timeIntervalSince(since) / 60)
            let top = hotspotApps.filter { $0.bytes >= 10_000_000 }.prefix(3)
            var x = Insight(id: "net-hotspot", tone: used >= 500_000_000 ? .warning : .info, symbol: "personalhotspot",
                            title: "On a phone's hotspot: \(ReportDocument.bytes(used)) of mobile data in \(minutes < 1 ? "under a minute" : "\(minutes) min")",
                            detail: top.isEmpty ? "Nothing big is downloading. Pause cloud sync and updates while on mobile data."
                                : "Most of it: " + top.map { "\($0.name) \(ReportDocument.bytes($0.bytes))" }.joined(separator: ", ") + ".")
            x.why = "Macs join a phone's hotspot by themselves when a known Wi-Fi drops (Instant Hotspot, or auto-join), and stay on it after the office Wi-Fi is back. Backups, sync, updates and video then run on mobile data."
            x.steps = ["Leave the hotspot: Wi-Fi off and on rejoins the best known network.",
                       "To stop it happening: System Settings, Wi-Fi, Ask to join hotspots: Never; and on the hotspot's (i), turn off Auto-Join.",
                       "Or keep Low Data Mode on for the hotspot (its (i) in Wi-Fi settings) so macOS holds back updates and sync."]
            x.fixes = [.leaveHotspot] + (top.first.map { [.quit(pids: $0.pids, name: $0.name)] } ?? [])
            out.append(x)
        }
        return out
    }
}
