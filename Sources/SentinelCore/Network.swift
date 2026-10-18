import Darwin
import Foundation

// MARK: Connections

/// One socket from `netstat -anv`: who owns it, where it goes, how far it got.
public struct NetConn: Equatable, Sendable {
    public enum Proto: String, Sendable { case tcp, udp }
    public let proto: Proto
    public let local: String
    public let remoteHost: String
    public let remotePort: Int
    /// TCP state (ESTABLISHED, SYN_SENT, TIME_WAIT…); empty for UDP.
    public let state: String
    public let rx: UInt64
    public let tx: UInt64
    public let pid: Int32
    /// As netstat prints it: cut to 16 characters.
    public let process: String

    public init(proto: Proto, local: String, remoteHost: String, remotePort: Int, state: String,
                rx: UInt64, tx: UInt64, pid: Int32, process: String) {
        self.proto = proto; self.local = local; self.remoteHost = remoteHost; self.remotePort = remotePort
        self.state = state; self.rx = rx; self.tx = tx; self.pid = pid; self.process = process
    }

    /// The same socket from one sample to the next.
    public var key: String { "\(proto.rawValue) \(local) \(remoteHost).\(remotePort) \(pid)" }
    public var isOpen: Bool { proto == .udp || ["ESTABLISHED", "SYN_SENT", "SYN_RCVD"].contains(state) }
    /// Loopback and link-local: this Mac talking to itself, not the network.
    public var isLocal: Bool { NetParse.isLoopback(remoteHost) }
}

public enum NetParse {
    /// `netstat -anv -p tcp` or `-p udp`. Columns: proto, recv-q, send-q, local, foreign,
    /// [state], rxbytes, txbytes, rhiwat, shiwat, process:pid… UDP has no state column.
    public static func netstat(_ s: String) -> [NetConn] {
        var out: [NetConn] = []
        for line in s.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 10, let proto: NetConn.Proto = f[0].hasPrefix("tcp") ? .tcp : (f[0].hasPrefix("udp") ? .udp : nil) else { continue }
            let hasState = proto == .tcp
            let state = hasState ? f[5] : ""
            guard state != "LISTEN" else { continue }
            let base = hasState ? 6 : 5
            guard f.count > base + 4, let rx = UInt64(f[base]), let tx = UInt64(f[base + 1]) else { continue }
            // "process:pid": names can hold spaces ("Google Chrome He:8224"), so join until the
            // field that ends in ":digits".
            var i = base + 4
            var name = ""
            var pid: Int32?
            while i < f.count {
                name += (name.isEmpty ? "" : " ") + f[i]
                if let c = name.lastIndex(of: ":"), let p = Int32(name[name.index(after: c)...]) {
                    pid = p
                    name = String(name[..<c])
                    break
                }
                i += 1
            }
            guard let pid, let (host, port) = split(f[4]), host != "*" else { continue }
            out.append(NetConn(proto: proto, local: f[3], remoteHost: host, remotePort: port, state: state,
                               rx: rx, tx: tx, pid: pid, process: name))
        }
        return out
    }

    /// "142.251.155.119.443" or "2a00:1450::1.443" to host and port.
    static func split(_ addr: String) -> (String, Int)? {
        guard let dot = addr.lastIndex(of: "."), let port = Int(addr[addr.index(after: dot)...]) else { return nil }
        return (String(addr[..<dot]), port)
    }

    public static func isLoopback(_ host: String) -> Bool {
        host.hasPrefix("127.") || host == "::1" || host.hasPrefix("fe80") || host == "localhost"
    }

    /// `nettop -P -L 1 -n -x -J …`: the header names the columns, in nettop's own order.
    public static func nettop(_ s: String) -> [Int32: AppTraffic] {
        var cols: [String] = []
        var out: [Int32: AppTraffic] = [:]
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if f.last == "" { f.removeLast() }
            if cols.isEmpty {
                if f.contains("bytes_in") { cols = f }
                continue
            }
            guard f.count >= cols.count, cols.count >= 2 else { continue }
            // Process names may contain commas: the counters are the last columns.
            let n = cols.count - 1
            let values = Array(f.suffix(n))
            let ident = f.dropLast(n).joined(separator: ",")
            guard let dot = ident.lastIndex(of: "."), let pid = Int32(ident[ident.index(after: dot)...]) else { continue }
            var t = out[pid] ?? AppTraffic(pid: pid, name: String(ident[..<dot]))
            for (c, v) in zip(cols.dropFirst(), values) {
                let x = UInt64(v) ?? 0
                switch c {
                case "bytes_in": t.bytesIn += x
                case "bytes_out": t.bytesOut += x
                case "packets_in": t.packetsIn += x
                case "packets_out": t.packetsOut += x
                default: break
                }
            }
            out[pid] = t
        }
        return out
    }

    /// The first resolver's nameservers from `scutil --dns`, in order, without repeats.
    public static func dnsServers(_ s: String) -> [String] {
        var out: [String] = []
        for line in s.split(separator: "\n") where line.contains("nameserver[") {
            guard let v = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !out.contains(v) else { continue }
            out.append(v)
        }
        return out
    }
}

/// Network totals for one process since it started, from nettop.
public struct AppTraffic: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public var bytesIn: UInt64 = 0
    public var bytesOut: UInt64 = 0
    public var packetsIn: UInt64 = 0
    public var packetsOut: UInt64 = 0
    public init(pid: Int32, name: String, bytesIn: UInt64 = 0, bytesOut: UInt64 = 0, packetsIn: UInt64 = 0, packetsOut: UInt64 = 0) {
        self.pid = pid; self.name = name; self.bytesIn = bytesIn; self.bytesOut = bytesOut
        self.packetsIn = packetsIn; self.packetsOut = packetsOut
    }
}

// MARK: Following connections over time

/// Watches sockets come and go between samples, to see what a single look cannot: secure
/// connections that open and drop within seconds (a handshake refused, a proxy or certificate
/// problem, an app retrying in a loop), connections that never get answered, and which hosts
/// the traffic actually goes to.
public final class ConnectionTracker {
    /// Something that went wrong with a connection.
    public struct Event: Equatable, Sendable {
        public enum Kind: String, Sendable {
            /// HTTPS (or other TLS) that closed within seconds having received almost nothing.
            case shortTLS
            /// Stayed in SYN_SENT: the other side never answered.
            case noAnswer
        }
        public let kind: Kind
        public let at: Date
        public let pid: Int32
        public let process: String
        public let host: String
        public let port: Int
        /// How long it lasted, at most (between samples).
        public let seconds: TimeInterval
        public let rx: UInt64
        public let tx: UInt64
        public init(kind: Kind, at: Date, pid: Int32, process: String, host: String, port: Int, seconds: TimeInterval, rx: UInt64, tx: UInt64) {
            self.kind = kind; self.at = at; self.pid = pid; self.process = process; self.host = host
            self.port = port; self.seconds = seconds; self.rx = rx; self.tx = tx
        }
    }

    /// Bytes to and from one remote host, by one process, in one minute.
    public struct Flow: Equatable, Sendable {
        public let minute: Int
        public let pid: Int32
        public let process: String
        public let host: String
        public var rx: UInt64
        public var tx: UInt64
    }

    struct Seen {
        var conn: NetConn
        var first: Date
        var last: Date
        var closedAt: Date?
        var synSince: Date?
        var reportedNoAnswer = false
    }

    private var seen: [String: Seen] = [:]
    public private(set) var events: [Event] = []
    private var flows: [String: Flow] = [:]
    private var lastSample: Date?
    /// Kept for this long.
    public let window: TimeInterval
    /// Ports where a connection means TLS.
    public static let tlsPorts: Set<Int> = [443, 993, 995, 465, 587, 853, 8443]
    /// A TLS connection that closed in under this, with less than `shortBytes` received.
    public static let shortSeconds: TimeInterval = 10
    public static let shortBytes: UInt64 = 8_000

    public init(window: TimeInterval = 3600) { self.window = window }

    public func update(_ conns: [NetConn], at now: Date) {
        let gap = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now
        var current = Set<String>()
        for c in conns where !c.isLocal {
            current.insert(c.key)
            if var s = seen[c.key] {
                addFlow(c, previous: s.conn, at: now)
                s.conn = c
                s.last = now
                if !c.isOpen, s.closedAt == nil { s.closedAt = now; finish(s, at: now) }
                if c.state == "SYN_SENT" {
                    if let since = s.synSince, now.timeIntervalSince(since) >= 5, !s.reportedNoAnswer {
                        s.reportedNoAnswer = true
                        record(.noAnswer, c, seconds: now.timeIntervalSince(since), at: now)
                    }
                } else { s.synSince = nil }
                seen[c.key] = s
            } else {
                // New since the last look. Already closed (TIME_WAIT): it opened and ended
                // between two samples, so it lasted at most `gap` seconds.
                addFlow(c, previous: nil, at: now)
                var s = Seen(conn: c, first: now, last: now)
                if c.state == "SYN_SENT" { s.synSince = now }
                if !c.isOpen {
                    s.closedAt = now
                    if gap > 0 { judge(c, seconds: gap, at: now) }
                }
                seen[c.key] = s
            }
        }
        // Gone without a closing state seen: ended between samples.
        for (k, s) in seen where !current.contains(k) {
            if s.closedAt == nil { finish(s, at: now) }
            seen[k] = nil
        }
        let cutoff = now.addingTimeInterval(-window)
        events.removeAll { $0.at < cutoff }
        let minute = Int(cutoff.timeIntervalSince1970 / 60)
        flows = flows.filter { $0.value.minute >= minute }
    }

    private func finish(_ s: Seen, at now: Date) {
        judge(s.conn, seconds: now.timeIntervalSince(s.first), at: now)
    }

    private func judge(_ c: NetConn, seconds: TimeInterval, at now: Date) {
        // Nothing sent means no handshake was tried: a reachability probe (connect and close,
        // as network monitors and claude-burst's hotspot watch do), not a failed one. A real
        // attempt sends its ClientHello first, a few hundred bytes.
        guard c.proto == .tcp, Self.tlsPorts.contains(c.remotePort), c.tx > 0,
              seconds <= Self.shortSeconds, c.rx < Self.shortBytes else { return }
        record(.shortTLS, c, seconds: seconds, at: now)
    }

    private func record(_ kind: Event.Kind, _ c: NetConn, seconds: TimeInterval, at now: Date) {
        events.append(Event(kind: kind, at: now, pid: c.pid, process: c.process, host: c.remoteHost, port: c.remotePort,
                            seconds: seconds, rx: c.rx, tx: c.tx))
    }

    private func addFlow(_ c: NetConn, previous: NetConn?, at now: Date) {
        let rx = c.rx >= (previous?.rx ?? 0) ? c.rx - (previous?.rx ?? 0) : c.rx
        let tx = c.tx >= (previous?.tx ?? 0) ? c.tx - (previous?.tx ?? 0) : c.tx
        guard rx + tx > 0 else { return }
        let minute = Int(now.timeIntervalSince1970 / 60)
        let k = "\(minute) \(c.pid) \(c.remoteHost)"
        var f = flows[k] ?? Flow(minute: minute, pid: c.pid, process: c.process, host: c.remoteHost, rx: 0, tx: 0)
        f.rx += rx
        f.tx += tx
        flows[k] = f
    }

    /// Open connections now.
    public var open: [NetConn] { seen.values.map(\.conn).filter(\.isOpen) }

    /// Bytes per (process, host) since `since`.
    public func flows(since: Date) -> [Flow] {
        let m = Int(since.timeIntervalSince1970 / 60)
        var acc: [String: Flow] = [:]
        for f in flows.values where f.minute >= m {
            let k = "\(f.pid) \(f.host)"
            if var a = acc[k] { a.rx += f.rx; a.tx += f.tx; acc[k] = a } else { acc[k] = f }
        }
        return acc.values.sorted { $0.rx + $0.tx > $1.rx + $1.tx }
    }

    /// Feeds sockets from a test or a replay.
    public func reset() { seen = [:]; events = []; flows = [:]; lastSample = nil }
}

/// Repeated failures folded by who and where: "Chrome to 1.2.3.4:443, 14 times".
public struct ConnectionProblem: Equatable, Sendable, Identifiable {
    public let kind: ConnectionTracker.Event.Kind
    public let process: String
    public let pids: [Int32]
    public let host: String
    public let port: Int
    public let count: Int
    public let last: Date
    public var id: String { "\(kind.rawValue) \(process) \(host) \(port)" }

    public static func group(_ events: [ConnectionTracker.Event], since: Date) -> [ConnectionProblem] {
        var acc: [String: [ConnectionTracker.Event]] = [:]
        for e in events where e.at >= since {
            acc["\(e.kind.rawValue)|\(e.process)|\(e.host)|\(e.port)", default: []].append(e)
        }
        return acc.values.compactMap { list in
            guard let f = list.first else { return nil }
            return ConnectionProblem(kind: f.kind, process: f.process, pids: Array(Set(list.map(\.pid))).sorted(),
                                     host: f.host, port: f.port, count: list.count, last: list.map(\.at).max() ?? f.at)
        }
        .sorted { ($0.count, $0.last) > ($1.count, $1.last) }
    }
}

// MARK: Whole-Mac traffic

/// Bytes through each interface since boot, 64-bit (getifaddrs' counters wrap at 4 GB).
public enum InterfaceCounters {
    public static func read() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: (UInt64, UInt64)] = [:]
        var i = 0
        while i + MemoryLayout<if_msghdr>.size <= len {
            let (msglen, type): (Int, Int32) = buf.withUnsafeBytes { p in
                let h = p.load(fromByteOffset: i, as: if_msghdr.self)
                return (Int(h.ifm_msglen), Int32(h.ifm_type))
            }
            guard msglen > 0 else { break }
            if type == RTM_IFINFO2, i + MemoryLayout<if_msghdr2>.size <= len {
                let h = buf.withUnsafeBytes { $0.load(fromByteOffset: i, as: if_msghdr2.self) }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(h.ifm_index), &name) != nil {
                    out[String(cString: name)] = (h.ifm_data.ifi_ibytes, h.ifm_data.ifi_obytes)
                }
            }
            i += msglen
        }
        return out
    }

    /// Real traffic: Wi-Fi and Ethernet (en*), not loopback, VPN tunnels (which carry the same
    /// bytes again) or Apple's private links.
    public static func physical(_ name: String) -> Bool { name.hasPrefix("en") }
}

/// Download and upload speed, from interface counters read every few seconds.
public struct Throughput: Sendable {
    public struct Point: Equatable, Sendable {
        public let at: Date
        public let down: Double
        public let up: Double
    }
    public private(set) var points: [Point] = []
    private var last: (at: Date, rx: UInt64, tx: UInt64)?
    public let keep: TimeInterval

    public init(keep: TimeInterval = 3600) { self.keep = keep }

    public mutating func record(rx: UInt64, tx: UInt64, at now: Date) {
        defer { last = (now, rx, tx) }
        guard let l = last, now > l.at else { return }
        let dt = now.timeIntervalSince(l.at)
        // A counter that went backwards (an interface reset) gives no reading, not a negative one.
        guard rx >= l.rx, tx >= l.tx else { return }
        points.append(Point(at: now, down: Double(rx - l.rx) / dt, up: Double(tx - l.tx) / dt))
        let keep = self.keep
        points.removeAll { now.timeIntervalSince($0.at) > keep }
    }

    public var latest: Point? { points.last }
    public func peak(since: Date) -> Point? {
        points.filter { $0.at >= since }.max { $0.down + $0.up < $1.down + $1.up }
    }
}

// MARK: The connection itself

public struct WiFiInfo: Equatable, Sendable {
    public var ssid: String?
    public var rssi: Int
    public var noise: Int
    /// Mbit/s the link runs at now.
    public var txRate: Double
    public var channel: Int?
    /// 2.4, 5 or 6 (GHz).
    public var band: Double?
    public var width: Int?
    public init(ssid: String? = nil, rssi: Int, noise: Int, txRate: Double, channel: Int? = nil, band: Double? = nil, width: Int? = nil) {
        self.ssid = ssid; self.rssi = rssi; self.noise = noise; self.txRate = txRate
        self.channel = channel; self.band = band; self.width = width
    }

    /// Signal over noise, in dB: what decides speed and dropouts more than signal alone.
    public var snr: Int { rssi - noise }

    public enum Quality: Int, Sendable, Comparable {
        case poor, fair, good, excellent
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
        public var label: String { ["Poor", "Fair", "Good", "Excellent"][rawValue] }
    }

    public var quality: Quality {
        if rssi >= -55 && snr >= 35 { return .excellent }
        if rssi >= -67 && snr >= 25 { return .good }
        if rssi >= -75 && snr >= 15 { return .fair }
        return .poor
    }
}

public struct LinkHealth: Equatable, Sendable {
    public var routerMs: Double?
    public var routerLoss: Double?
    public var internetMs: Double?
    public var internetLoss: Double?
    public var dnsMs: Double?
    public var dnsOK = true
    /// The largest packet that crosses whole, and what the interface allows.
    public var pathMTU: Int?
    public var interfaceMTU: Int?
    public var at: Date

    /// Packets bigger than the path allows get split or dropped.
    public var fragments: Bool {
        guard let p = pathMTU, let i = interfaceMTU else { return false }
        return p < i
    }
    public init(routerMs: Double? = nil, routerLoss: Double? = nil, internetMs: Double? = nil, internetLoss: Double? = nil,
                dnsMs: Double? = nil, dnsOK: Bool = true, pathMTU: Int? = nil, interfaceMTU: Int? = nil, at: Date) {
        self.routerMs = routerMs; self.routerLoss = routerLoss; self.internetMs = internetMs
        self.internetLoss = internetLoss; self.dnsMs = dnsMs; self.dnsOK = dnsOK
        self.pathMTU = pathMTU; self.interfaceMTU = interfaceMTU; self.at = at
    }
}

public struct NetworkLink: Equatable, Sendable {
    public var interface: String?
    public var gateway: String?
    public var address: String?
    public var dns: [String] = []
    /// A VPN or security tunnel by name, when one is running.
    public var vpn: String?
    public var wifi: WiFiInfo?
    public init(interface: String? = nil, gateway: String? = nil, address: String? = nil, dns: [String] = [], vpn: String? = nil, wifi: WiFiInfo? = nil) {
        self.interface = interface; self.gateway = gateway; self.address = address; self.dns = dns; self.vpn = vpn; self.wifi = wifi
    }

    /// An iPhone or iPad sharing its connection: data may be metered.
    public var isHotspot: Bool { gateway == "172.20.10.1" }

    public var kind: String {
        guard let i = interface else { return "Offline" }
        if isHotspot { return "Personal Hotspot" }
        if wifi != nil { return "Wi-Fi" }
        if i.hasPrefix("utun") || i.hasPrefix("ipsec") || i.hasPrefix("ppp") { return "VPN" }
        return i.hasPrefix("en") ? "Ethernet" : i
    }

    /// VPN and security clients by process name.
    public static let vpnClients: [String: String] = [
        "ZscalerTunnel": "Zscaler", "GlobalProtect": "GlobalProtect", "PanGPS": "GlobalProtect", "vpnagentd": "Cisco AnyConnect",
        "acwebsecagent": "Cisco Umbrella", "openvpn": "OpenVPN", "wireguard-go": "WireGuard", "tailscaled": "Tailscale",
        "NordVPN": "NordVPN", "ExpressVPN": "ExpressVPN", "FortiClient": "FortiClient", "nesessionmanager": "VPN",
        "Cloudflare WARP": "Cloudflare WARP", "warp-svc": "Cloudflare WARP", "netskope": "Netskope", "stAgentSvc": "Netskope",
    ]

    /// A named client wins over macOS's generic VPN service, which runs alongside most of them.
    public static func vpn(processNames: [String]) -> String? {
        let found = processNames.compactMap { vpnClients[$0] }
        return found.first { $0 != "VPN" } ?? found.first
    }
}

// MARK: Packet size

/// The largest packet that crosses the path whole. Pings with the don't-fragment flag at
/// decreasing sizes: the biggest that gets an answer, plus 28 bytes of IP and ICMP headers.
public enum PathMTU {
    /// Binary search between 1200 and the interface's own limit. `probe(payload)` says whether
    /// a ping of that payload got through. Returns the path MTU, or nil if nothing got through.
    public static func find(interfaceMTU: Int, probe: (Int) -> Bool) -> Int? {
        var lo = 1200, hi = min(interfaceMTU - 28, 1472), best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if probe(mid) { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best > 0 ? best + 28 : nil
    }
}

// MARK: What is worth saying

public enum NetworkAnalysis {
    public struct AppRow: Equatable, Sendable {
        public let key: String
        public let name: String
        public let pids: [Int32]
        public let down: Double
        public let up: Double
        public let totalIn: UInt64
        public let totalOut: UInt64
        public let connections: Int
        public init(key: String, name: String, pids: [Int32], down: Double, up: Double, totalIn: UInt64, totalOut: UInt64, connections: Int) {
            self.key = key; self.name = name; self.pids = pids; self.down = down; self.up = up
            self.totalIn = totalIn; self.totalOut = totalOut; self.connections = connections
        }
    }

    static func gb(_ b: UInt64) -> String { ReportDocument.bytes(b) }

    public static func insights(link: NetworkLink, health: LinkHealth?, problems: [ConnectionProblem],
                                apps: [AppRow], closeWait: [String: Int] = [:], at now: Date) -> [Insight] {
        var out: [Insight] = []
        if link.interface == nil {
            out.append(Insight(id: "net-offline", tone: .critical, symbol: "wifi.slash", title: "Not connected",
                               detail: "No Wi-Fi or Ethernet connection."))
            return out
        }
        if let w = link.wifi {
            if w.quality == .poor {
                var x = Insight(id: "net-wifi-weak", tone: .warning, symbol: "wifi.exclamationmark",
                                title: "Weak Wi-Fi: signal \(w.rssi) dBm, \(w.snr) dB above the noise",
                                detail: "Expect slow pages, dropped calls and retries.")
                x.why = "Signal under about -75 dBm, or less than 15 dB above the background noise, forces the link to slow down and resend. Walls, distance, microwaves and crowded channels all cost signal."
                x.steps = ["Move closer to the router, or into the same room.", "Use 5 GHz or 6 GHz if the router offers it.", "Wired Ethernet for calls and big transfers."]
                x.fixes = [.openSettings(.wifi)]
                out.append(x)
            }
            if let b = w.band, b < 3, w.quality < .excellent {
                out.append(Insight(id: "net-wifi-24", tone: .info, symbol: "antenna.radiowaves.left.and.right",
                                   title: "On 2.4 GHz Wi-Fi",
                                   detail: "Reaches further but is slower and more crowded than 5 GHz. If the router has a 5 GHz network, join it when nearby.",
                                   fixes: [.openSettings(.wifi)]))
            }
            if w.txRate > 0, w.txRate < 50 {
                out.append(Insight(id: "net-wifi-rate", tone: .info, symbol: "speedometer",
                                   title: "Wi-Fi link is slow: \(Int(w.txRate)) Mbit/s",
                                   detail: "The radio link itself caps transfers at about \(max(1, Int(w.txRate / 10))) MB/s, whatever the internet plan."))
            }
        }
        if let h = health {
            let routerBad = (h.routerLoss ?? 0) >= 5 || (h.routerMs ?? 0) >= 50
            let netBad = (h.internetLoss ?? 0) >= 5 || (h.internetMs ?? 0) >= 150
            if h.internetLoss == 100 {
                out.append(Insight(id: "net-down", tone: .critical, symbol: "icloud.slash",
                                   title: "Internet is not reachable",
                                   detail: h.routerLoss.map { $0 < 100 ? "The router answers, so the problem is beyond it: the internet line, the provider or the VPN." : "The router does not answer either: reconnect Wi-Fi or check the cable." } ?? "Pings to 1.1.1.1 get no answer."))
            } else if routerBad {
                var x = Insight(id: "net-router", tone: .warning, symbol: "wifi.router",
                                title: "The link to the router is poor: \(Int(h.routerMs ?? 0)) ms, \(Int(h.routerLoss ?? 0))% loss",
                                detail: "The problem is in the room, not the internet: Wi-Fi signal, interference, or a busy router.")
                x.steps = ["Move closer to the router or use Ethernet.", "Restart Wi-Fi (Checkup, Quick fixes).", "Restart the router."]
                out.append(x)
            } else if netBad {
                var x = Insight(id: "net-internet", tone: .warning, symbol: "globe",
                                title: "The internet is slow beyond the router: \(Int(h.internetMs ?? 0)) ms, \(Int(h.internetLoss ?? 0))% loss",
                                detail: link.vpn.map { "The router link is fine. \($0) routes everything through its servers, which often adds this." }
                                    ?? "The router link is fine, so it is the line or the provider.")
                x.steps = link.vpn != nil ? ["Try with the VPN off, if allowed, to compare."] : ["Restart the router.", "If it persists, check with the provider."]
                out.append(x)
            }
            if h.fragments, let p = h.pathMTU, let i = h.interfaceMTU {
                var x = Insight(id: "net-mtu", tone: p < 1400 ? .warning : .info, symbol: "square.split.2x1",
                                title: "Packets over \(p) bytes get split up (this Mac sends up to \(i))",
                                detail: (link.vpn.map { "Usually the VPN: \($0) wraps each packet in its own, leaving less room. " } ?? "Usually a VPN or a PPPoE internet line. ")
                                    + "Large downloads and uploads can stall, and some sites hang half-loaded.")
                x.why = "Found by sending pings marked do-not-split at decreasing sizes: \(p) bytes is the largest that got through. When a full \(i)-byte packet does not fit, it is split in two or dropped; if the message saying so is blocked, connections freeze on big transfers while small requests work."
                x.steps = ["If transfers stall on this network, set the MTU to \(p) in System Settings, Network, Details, Hardware (Configure: Manually).",
                           "On a VPN, ask IT: the VPN normally handles this itself."]
                x.fixes = [.openSettings(.network)]
                out.append(x)
            }
            if !h.dnsOK || (h.dnsMs ?? 0) >= 300 {
                out.append(Insight(id: "net-dns", tone: .warning, symbol: "text.magnifyingglass",
                                   title: h.dnsOK ? "Name lookups are slow: \(Int(h.dnsMs ?? 0)) ms" : "Name lookups are failing",
                                   detail: "Every new website waits for this first. Flushing the DNS cache (Checkup, Quick fixes) often helps; otherwise try DNS 1.1.1.1."))
            }
        }
        // Secure connections that keep failing: the clearest sign of a broken app, a proxy or
        // certificate problem, or something blocked.
        // One insight per app, however many hosts it fails against.
        let tls = Dictionary(grouping: problems.filter { $0.kind == .shortTLS }, by: \.process)
            .map { (process: $0.key, list: $0.value, count: $0.value.reduce(0) { $0 + $1.count }) }
            .filter { $0.count >= 8 }
            .sorted { $0.count > $1.count }
        for g in tls.prefix(3) {
            let hosts = g.list.sorted { $0.count > $1.count }.map(\.host)
            let p = (process: g.process, count: g.count, pids: Array(Set(g.list.flatMap(\.pids))).sorted())
            let to = hosts.count == 1 ? hosts[0] : "\(hosts.count) hosts"
            var x = Insight(id: "net-tls-\(p.process)", tone: p.count >= 30 ? .warning : .info, symbol: "lock.trianglebadge.exclamationmark",
                            title: "\(p.process) keeps dropping secure connections to \(to)",
                            detail: "\(p.count) secure connections closed within seconds, having received almost nothing, in the last hour"
                                + (hosts.count > 1 ? ": \(hosts.prefix(4).joined(separator: ", "))\(hosts.count > 4 ? "…" : "")." : "."))
            x.why = "A TLS connection that closes before any real data arrives usually means the handshake failed: a certificate the app does not trust (often a corporate proxy or VPN inspecting traffic), a blocked address, a wrong clock, or a server refusing the app. Apps then retry in a loop, which wastes battery and can make the app hang."
            x.steps = ["Check the app works; if not, quit and reopen it.", "If a VPN or security proxy is on, it may be blocking this host: ask IT.", "Check the clock is right (Checkup, Sync clock)."]
            x.fixes = p.pids.isEmpty ? [] : [.quit(pids: p.pids, name: p.process)]
            out.append(x)
        }
        for p in problems.filter({ $0.kind == .noAnswer && $0.count >= 5 }).prefix(2) {
            out.append(Insight(id: "net-noanswer-\(p.process)-\(p.host)", tone: .info, symbol: "network.slash",
                               title: "\(p.process) cannot reach \(p.host):\(p.port)",
                               detail: "\(p.count) attempts got no answer in the last hour. A firewall, VPN or server that is down."))
        }
        for (name, n) in closeWait where n >= 20 {
            out.append(Insight(id: "net-closewait-\(name)", tone: .info, symbol: "rectangle.stack.badge.minus",
                               title: "\(name) is not closing \(n) finished connections",
                               detail: "The other side hung up but the app has not let go. A bug that slowly uses up resources; restarting the app clears it."))
        }
        // Who is moving data.
        if let up = apps.filter({ $0.up >= 1_000_000 }).max(by: { $0.up < $1.up }) {
            var x = Insight(id: "net-uploading", tone: link.isHotspot ? .warning : .info, symbol: "arrow.up.circle.fill",
                            title: "\(up.name) is uploading \(IORow.rate(up.up))",
                            detail: link.isHotspot ? "You are on a phone hotspot: this uses mobile data." : "Uploads slow everything else on the connection, calls first.")
            x.fixes = [.quit(pids: up.pids, name: up.name)]
            out.append(x)
        }
        if let big = apps.filter({ $0.totalOut >= 1 << 30 }).max(by: { $0.totalOut < $1.totalOut }) {
            out.append(Insight(id: "net-bigsender", tone: .info, symbol: "arrow.up.doc.fill",
                               title: "\(big.name) has sent \(gb(big.totalOut)) since it started",
                               detail: "Received \(gb(big.totalIn)). Backup, sync and security agents send a lot; anything else sending this much is worth knowing about."))
        }
        if link.isHotspot {
            let total = apps.reduce(UInt64(0)) { $0 + $1.totalIn + $1.totalOut }
            out.append(Insight(id: "net-hotspot", tone: .info, symbol: "personalhotspot",
                               title: "On a phone's Personal Hotspot",
                               detail: "Data may be metered. Apps running now have moved \(gb(total)) since they started; pause big syncs and updates."))
        }
        if let many = apps.filter({ $0.connections >= 300 }).max(by: { $0.connections < $1.connections }) {
            out.append(Insight(id: "net-manyconns", tone: .info, symbol: "point.3.connected.trianglepath.dotted",
                               title: "\(many.name) has \(many.connections) connections open",
                               detail: "Far more than an app normally needs: a leak or a runaway retry loop. Restarting the app clears it.",
                               fixes: [.quit(pids: many.pids, name: many.name)]))
        }
        return out
    }
}
