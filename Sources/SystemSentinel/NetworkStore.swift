import AppKit
import CoreWLAN
import SentinelCore

/// The Network tab's data: speed now and over the last hour, every connection and where it
/// goes, which apps move the most, the link's quality, and connections that keep failing.
@MainActor
final class NetworkStore: ObservableObject {
    @Published var throughput = Throughput()
    @Published var link = NetworkLink()
    @Published var health: LinkHealth?
    @Published var testing = false
    @Published var apps: [NetworkAnalysis.AppRow] = []
    @Published var problems: [ConnectionProblem] = []
    @Published var flows: [ConnectionTracker.Flow] = []
    @Published var insights: [Insight] = []
    @Published var openCount = 0
    /// Reverse lookups: address to host name, filled in the background.
    @Published var names: [String: String] = [:]

    let tracker = ConnectionTracker()
    /// The model's processes, for names, icons and grouping by app.
    var processes: () -> [ProcessSample] = { [] }
    var ran: (TaskHealth.Job) -> Void = { _ in }

    private var timers: [Timer] = []
    private var traffic: [Int32: AppTraffic] = [:]
    private var rates: [Int32: (down: Double, up: Double)] = [:]
    private var lastTraffic: (at: Date, by: [Int32: AppTraffic])?
    private var closeWait: [String: Int] = [:]
    private var looking: Set<String> = []
    private var busy = false

    init() {
        sample()
        readLink()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.sample() } },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.readTraffic() } },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.readLink() } },
            Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in Task { @MainActor in self?.test() } },
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.readTraffic() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.test() }
    }

    // MARK: Sampling

    /// Every 3 s: sockets (to catch connections that live only seconds) and interface bytes.
    private func sample() {
        guard !busy else { return }
        busy = true
        Task.detached(priority: .utility) {
            let conns = NetParse.netstat(sh("/usr/sbin/netstat", ["-anv", "-p", "tcp"], timeout: 5))
                + NetParse.netstat(sh("/usr/sbin/netstat", ["-anv", "-p", "udp"], timeout: 5))
            let counters = InterfaceCounters.read().filter { InterfaceCounters.physical($0.key) }
            let rx = counters.values.reduce(UInt64(0)) { $0 + $1.rx }
            let tx = counters.values.reduce(UInt64(0)) { $0 + $1.tx }
            await MainActor.run {
                let now = Date()
                self.busy = false
                self.tracker.update(conns, at: now)
                self.throughput.record(rx: rx, tx: tx, at: now)
                var wait: [String: Int] = [:]
                for c in conns where c.state == "CLOSE_WAIT" { wait[self.appName(pid: c.pid, fallback: c.process), default: 0] += 1 }
                self.closeWait = wait
                self.openCount = self.tracker.open.count
                self.refresh()
            }
        }
    }

    /// Every 10 s: per-process totals since each started, from nettop, and rates from them.
    private func readTraffic() {
        Task.detached(priority: .utility) {
            let t = NetParse.nettop(sh("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out,packets_in,packets_out"], timeout: 8))
            await MainActor.run {
                let now = Date()
                if let last = self.lastTraffic, now > last.at {
                    let dt = now.timeIntervalSince(last.at)
                    self.rates = t.compactMapValues { cur in
                        guard let p = last.by[cur.pid] else { return nil }
                        return (Double(cur.bytesIn >= p.bytesIn ? cur.bytesIn - p.bytesIn : 0) / dt,
                                Double(cur.bytesOut >= p.bytesOut ? cur.bytesOut - p.bytesOut : 0) / dt)
                    }
                }
                self.lastTraffic = (now, t)
                self.traffic = t
                self.refresh()
            }
        }
    }

    /// Every 30 s: which interface, router, address, DNS, VPN and Wi-Fi radio.
    private func readLink() {
        let names = processes().map(\.name)
        let wifi = Self.readWiFi()
        Task.detached(priority: .utility) {
            let route = CheckParse.defaultRoute(sh("/sbin/route", ["-n", "get", "default"], timeout: 4))
            let dns = NetParse.dnsServers(sh("/usr/sbin/scutil", ["--dns"], timeout: 4))
            let address = route.interface.flatMap { i in
                sh("/usr/sbin/ipconfig", ["getifaddr", i], timeout: 3).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let link = NetworkLink(interface: route.interface, gateway: route.gateway,
                                   address: address?.isEmpty == false ? address : nil, dns: Array(dns.prefix(4)),
                                   vpn: NetworkLink.vpn(processNames: names),
                                   wifi: route.interface == wifi?.interface ? wifi?.info : nil)
            await MainActor.run {
                self.link = link
                self.refresh()
            }
        }
    }

    nonisolated static func readWiFi() -> (interface: String, info: WiFiInfo)? {
        guard let i = CWWiFiClient.shared().interface(), let name = i.interfaceName, i.powerOn(), i.rssiValue() != 0 else { return nil }
        let ch = i.wlanChannel()
        let band: Double? = {
            switch ch?.channelBand {
            case .band2GHz: return 2.4
            case .band5GHz: return 5
            case .band6GHz: return 6
            default: return nil
            }
        }()
        let width: Int? = {
            switch ch?.channelWidth {
            case .width20MHz: return 20
            case .width40MHz: return 40
            case .width80MHz: return 80
            case .width160MHz: return 160
            default: return nil
            }
        }()
        // The network name needs Location access since macOS 14; without it, nil.
        return (name, WiFiInfo(ssid: i.ssid(), rssi: i.rssiValue(), noise: i.noiseMeasurement(), txRate: i.transmitRate(),
                               channel: ch?.channelNumber, band: band, width: width))
    }

    /// Latency and loss to the router and to the internet, and how long a name lookup takes.
    func test() {
        guard !testing else { return }
        testing = true
        let gateway = link.gateway
        Task.detached(priority: .utility) {
            async let router: (loss: Double, avg: Double?)? = gateway.flatMap { g in
                g.contains(":") ? nil : CheckParse.ping(sh("/sbin/ping", ["-c", "8", "-i", "0.2", "-t", "5", g], timeout: 8))
            }
            async let internet = CheckParse.ping(sh("/sbin/ping", ["-c", "8", "-i", "0.2", "-t", "5", "1.1.1.1"], timeout: 8))
            let t0 = Date()
            let resolved = !sh("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "www.apple.com"], timeout: 6).isEmpty
            let dnsMs = Date().timeIntervalSince(t0) * 1000
            let (r, i) = await (router, internet)
            let h = LinkHealth(routerMs: r?.avg, routerLoss: r?.loss, internetMs: i?.avg, internetLoss: i?.loss,
                               dnsMs: resolved ? dnsMs : nil, dnsOK: resolved, at: Date())
            await MainActor.run {
                self.health = h
                self.testing = false
                self.refresh()
            }
        }
    }

    // MARK: Putting it together

    private func refresh() {
        let procs = processes()
        let paths = Dictionary(procs.map { ($0.pid, $0.path) }, uniquingKeysWith: { a, _ in a })
        // Connections per process now.
        var conns: [Int32: Int] = [:]
        for c in tracker.open { conns[c.pid, default: 0] += 1 }
        var acc: [String: (name: String, pids: [Int32], down: Double, up: Double, tin: UInt64, tout: UInt64, n: Int)] = [:]
        for (pid, t) in traffic {
            let key = paths[pid].map(Model.appKey) ?? "proc:" + t.name
            let name = paths[pid].map { Model.appName(Model.appKey($0)) } ?? t.name
            var a = acc[key] ?? (name, [], 0, 0, 0, 0, 0)
            a.pids.append(pid)
            a.down += rates[pid]?.down ?? 0
            a.up += rates[pid]?.up ?? 0
            a.tin += t.bytesIn
            a.tout += t.bytesOut
            a.n += conns[pid] ?? 0
            acc[key] = a
        }
        apps = acc.map { NetworkAnalysis.AppRow(key: $0.key, name: $0.value.name, pids: $0.value.pids.sorted(), down: $0.value.down,
                                               up: $0.value.up, totalIn: $0.value.tin, totalOut: $0.value.tout, connections: $0.value.n) }
            .filter { $0.totalIn + $0.totalOut > 0 || $0.connections > 0 }
        let now = Date()
        let events = tracker.events.map { e in
            ConnectionTracker.Event(kind: e.kind, at: e.at, pid: e.pid, process: appName(pid: e.pid, fallback: e.process, paths: paths),
                                    host: label(e.host), port: e.port, seconds: e.seconds, rx: e.rx, tx: e.tx)
        }
        problems = ConnectionProblem.group(events, since: now.addingTimeInterval(-3600))
        flows = tracker.flows(since: now.addingTimeInterval(-3600))
        insights = NetworkAnalysis.insights(link: link, health: health, problems: problems, apps: apps, closeWait: closeWait, at: now)
        lookUp(Array(Set(flows.prefix(40).map(\.host) + tracker.events.suffix(60).map(\.host))))
    }

    func appName(pid: Int32, fallback: String, paths: [Int32: String]? = nil) -> String {
        let p = paths?[pid] ?? processes().first { $0.pid == pid }?.path
        return p.map { Model.appName(Model.appKey($0)) } ?? fallback
    }

    /// A host name for an address: from a reverse lookup, else who owns the range, else the address.
    func label(_ host: String) -> String {
        if let n = names[host], !n.isEmpty { return n }
        if host.hasPrefix("17.") { return "Apple (\(host))" }
        if host.hasPrefix("100.64.") || host.hasPrefix("100.65.") { return "VPN tunnel (\(host))" }
        return host
    }

    /// Reverse DNS, a few at a time, each once.
    private func lookUp(_ hosts: [String]) {
        let todo = hosts.filter { names[$0] == nil && !looking.contains($0) }.prefix(12)
        guard !todo.isEmpty else { return }
        looking.formUnion(todo)
        for h in todo {
            Task.detached(priority: .background) {
                let name = NetworkStore.reverse(h)
                await MainActor.run {
                    self.names[h] = name.map { "\($0) (\(h))" } ?? ""
                    self.looking.remove(h)
                }
            }
        }
    }

    nonisolated static func reverse(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let name = String(cString: buf)
        return name == host ? nil : name
    }
}
