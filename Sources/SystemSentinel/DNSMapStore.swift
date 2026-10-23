import AppKit
import Network
import SentinelCore
import Security
import SwiftUI

/// Maps one name end to end: how this Mac looks it up, what every DNS server says, its
/// records, the delegation from the root, its own name servers, every address it points at
/// (owner, ping, open ports, route) and the routes to the DNS servers themselves. Every
/// command run is kept with its output.
@MainActor
final class DNSMapStore: ObservableObject {
    static let shared = DNSMapStore()

    @Published var input = UserDefaults.standard.string(forKey: "dnsMapLast") ?? ""
    @Published private(set) var result: DNSMapResult?
    @Published private(set) var running = false
    @Published private(set) var step = ""
    @Published private(set) var pending = 0
    private var generation = 0
    private var task: Task<Void, Never>?

    func start() {
        guard let name = DNSMap.normalize(input) else { step = "Type a name, URL or address"; return }
        UserDefaults.standard.set(input, forKey: "dnsMapLast")
        task?.cancel()
        generation += 1
        let gen = generation
        result = DNSMapResult(query: name, at: Date())
        running = true
        pending = 0
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.map(name, gen: gen)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.running = false
                self.step = "Done"
            }
        }
    }

    func stop() {
        task?.cancel()
        generation += 1
        running = false
        step = "Stopped"
    }

    func copyReport() {
        guard let r = result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DNSMap.report(r), forType: .string)
    }

    // MARK: Running

    /// Applies a change to the result, unless a newer map has started.
    private func update(_ gen: Int, _ f: @escaping (inout DNSMapResult) -> Void) async {
        await MainActor.run {
            guard self.generation == gen, var r = self.result else { return }
            f(&r)
            self.result = r
        }
    }

    private func say(_ gen: Int, _ s: String) async {
        await MainActor.run { if self.generation == gen { self.step = s } }
    }

    /// Runs a command, logs it with its output and how long it took.
    private nonisolated func run(_ gen: Int, _ path: String, _ args: [String], timeout: TimeInterval = 10) async -> String {
        await MainActor.run { if self.generation == gen { self.pending += 1 } }
        let t0 = Date()
        let out = sh(path, args, timeout: timeout)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let line = ([URL(fileURLWithPath: path).lastPathComponent] + args.map { $0.contains(" ") ? "'\($0)'" : $0 }).joined(separator: " ")
        await MainActor.run { if self.generation == gen { self.pending -= 1 } }
        await update(gen) { $0.commands.append(.init(command: line, ms: ms, output: out.trimmingCharacters(in: .whitespacesAndNewlines))) }
        return out
    }

    private nonisolated func dig(_ gen: Int, _ args: [String], timeout: TimeInterval = 6) async -> String {
        await run(gen, "/usr/bin/dig", args, timeout: timeout)
    }

    private nonisolated func map(_ name: String, gen: Int) async {
        let isIP = DNSMap.isIP(name)
        await say(gen, "Looking it up the way the Mac does")

        // 1. How this Mac looks it up.
        let resolvers = NetParse.resolvers(await run(gen, "/usr/sbin/scutil", ["--dns"], timeout: 4))
        let (resolver, why) = isIP ? (nil, "An address: nothing to look up, mapped directly") : DNSMap.resolver(for: name, in: resolvers)
        let hosts = NetParse.hosts((try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? "")
        let t0 = Date()
        let system = NetworkStore.resolve(name).addresses
        let systemMs = Int(Date().timeIntervalSince(t0) * 1000)
        await update(gen) {
            $0.resolver = resolver
            $0.resolverWhy = why
            $0.hostsEntry = hosts.first { $0.names.contains(name) }
            $0.system = system
            $0.systemMs = systemMs
        }
        if Task.isCancelled { return }

        var addresses = system
        if !isIP {
            // 2. Every configured server, the records, and the walk down from the root.
            await say(gen, "Asking every DNS server, reading records, walking down from the root")
            var serverList: [(String, String)] = []
            for r in resolvers where !r.mdns {
                let scope = r.supplemental ? (r.domain.map { "only for \($0)" } ?? "VPN") : "main"
                for s in r.servers where !serverList.contains(where: { $0.0 == s }) && serverList.count < 8 { serverList.append((s, scope)) }
            }
            for extra in ["1.1.1.1", "8.8.8.8"] where !serverList.contains(where: { $0.0 == extra }) {
                serverList.append((extra, "public, for comparison"))
            }
            let servers = serverList
            async let answers: [DNSMapResult.ServerAnswer] = withTaskGroup(of: (Int, DNSMapResult.ServerAnswer).self) { g in
                for (i, s) in servers.enumerated() {
                    g.addTask {
                        let out = await self.dig(gen, ["@\(s.0)", name, "A", "+time=2", "+tries=1"])
                        let d = NetParse.dig(out)
                        let cn = NetParse.records(out).filter { $0.type == "CNAME" }.map(\.value)
                        return (i, .init(server: s.0, scope: s.1, status: d?.status, ms: d?.ms, addresses: d?.addresses ?? [], cnames: cn))
                    }
                }
                var out: [(Int, DNSMapResult.ServerAnswer)] = []
                for await x in g { out.append(x) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            // Asked of the server macOS would use for this name, so split names go to the VPN.
            let via = resolver?.servers.first.map { ["@\($0)"] } ?? []
            async let records: ([DNSRecord], String?) = withTaskGroup(of: (Int, [DNSRecord], String?).self) { g in
                let types = ["A", "AAAA", "CNAME", "MX", "TXT", "CAA", "HTTPS", "NS", "SOA"]
                for (i, t) in types.enumerated() {
                    g.addTask {
                        let out = await self.dig(gen, via + [name, t, "+time=3", "+tries=1"])
                        return (i, NetParse.records(out).filter { $0.type == t || (t == "A" && $0.type == "CNAME") }, t == "A" ? NetParse.dig(out)?.status : nil)
                    }
                }
                var all: [(Int, [DNSRecord], String?)] = []
                for await x in g { all.append(x) }
                var seen = Set<DNSRecord>()
                let recs = all.sorted { $0.0 < $1.0 }.flatMap(\.1).filter { seen.insert($0).inserted }
                return (recs, all.compactMap(\.2).first)
            }
            async let trace = dig(gen, ["+trace", "+nodnssec", name, "A"], timeout: 25)
            async let cloudflare = doh(gen, "Cloudflare", "https://cloudflare-dns.com/dns-query", name)
            async let google = doh(gen, "Google", "https://dns.google/resolve", name)
            let a = await answers + [await cloudflare, await google]
            await update(gen) { $0.answers = a }
            let (recs, status) = await records
            await update(gen) { $0.records = recs; $0.status = status }
            let steps = NetParse.digTrace(await trace)
            await update(gen) { $0.delegation = steps }
            if Task.isCancelled { return }

            for r in recs where (r.type == "A" || r.type == "AAAA") && !addresses.contains(r.value) { addresses.append(r.value) }

            // 3. The zone's own name servers, asked directly.
            let referral = steps.last { !$0.nameServers.isEmpty && $0.zone != "." }
            if let zone = referral?.zone {
                await say(gen, "Asking \(zone)'s own name servers")
                async let soa = dig(gen, [zone, "SOA", "+short", "+time=3", "+tries=1"])
                async let ds = dig(gen, [zone, "DS", "+short", "+time=3", "+tries=1"])
                let nss = Array((referral?.nameServers ?? []).prefix(8))
                let auth: [DNSMapResult.Authority] = await withTaskGroup(of: (Int, DNSMapResult.Authority).self) { g in
                    for (i, ns) in nss.enumerated() {
                        g.addTask {
                            let ip = await self.dig(gen, [ns, "A", "+short", "+time=2", "+tries=1"])
                                .split(separator: "\n").map(String.init).first { DNSMap.isIP($0) }
                            guard let ip else { return (i, .init(name: ns, address: nil, status: nil, ms: nil, serial: nil, addresses: [])) }
                            async let q = self.dig(gen, ["@\(ip)", name, "A", "+norecurse", "+time=2", "+tries=1"])
                            async let s = self.dig(gen, ["@\(ip)", zone, "SOA", "+short", "+norecurse", "+time=2", "+tries=1"])
                            let d = NetParse.dig(await q)
                            let serial = DNSMap.serial(await s.trimmingCharacters(in: .whitespacesAndNewlines))
                            return (i, .init(name: ns, address: ip, status: d?.status, ms: d?.ms, serial: serial, addresses: d?.addresses ?? []))
                        }
                    }
                    var out: [(Int, DNSMapResult.Authority)] = []
                    for await x in g { out.append(x) }
                    return out.sorted { $0.0 < $1.0 }.map(\.1)
                }
                let soaText = await soa.trimmingCharacters(in: .whitespacesAndNewlines)
                let signed = !(await ds).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                await update(gen) {
                    $0.zone = zone
                    $0.soa = soaText.isEmpty ? nil : soaText
                    $0.signed = signed
                    $0.authorities = auth
                }
            }
        } else {
            addresses = [name]
        }
        if Task.isCancelled { return }

        // 4. Every address: who runs it, ping, ports, and the route to it. Then routes to the
        // DNS servers and name servers.
        await say(gen, "Checking each address and tracing every route")
        let targets = Array(addresses.prefix(6))
        await update(gen) { r in r.targets = targets.map { DNSMapResult.Target(address: $0) } }
        let snapshot = await MainActor.run { self.result }
        var routes: [(String, String)] = targets.map { ("\(name) \($0)", $0) }
        for a in snapshot?.answers ?? [] where !a.viaHTTPS && a.scope != "public, for comparison" && !routes.contains(where: { $0.1 == a.server }) && routes.count < targets.count + 4 {
            routes.append(("DNS server \(a.server)", a.server))
        }
        for a in (snapshot?.authorities ?? []).prefix(3) {
            if let ip = a.address, !routes.contains(where: { $0.1 == ip }) { routes.append(("Name server \(a.name)", ip)) }
        }
        // Tunnel apps (Zscaler, VPNs): what hides inside them cannot be traced, but the
        // tunnel itself can, to the provider's server it connects to.
        let conns = NetParse.netstat(await run(gen, "/usr/sbin/netstat", ["-anv", "-p", "tcp"], timeout: 6))
            + NetParse.netstat(await run(gen, "/usr/sbin/netstat", ["-anv", "-p", "udp"], timeout: 6))
        let tunnels = DNSMap.tunnels(conns)
        for t in tunnels {
            for e in t.edges.prefix(2) where !routes.contains(where: { $0.1 == e }) { routes.append(("\(t.vendor) tunnel server", e)) }
        }
        let routeList = routes
        await update(gen) { r in
            r.tunnels = tunnels
            r.routes = routeList.map { DNSMapResult.Route(label: $0.0, address: $0.1) }
        }
        await owners(tunnels.flatMap(\.edges), gen: gen)
        let vendor = tunnels.first?.vendor ?? "VPN"
        if tunnels.contains(where: { $0.vendor == "Zscaler" }) {
            let page = await fetch(gen, "https://ip.zscaler.com/")
            if let z = NetParse.zscalerPage(page) { await update(gen) { $0.zscaler = z } }
        }

        let certificate: Task<DNSMapResult.Certificate?, Never>? = isIP ? nil : Task { await CertProbe.inspect(name) }
        await withTaskGroup(of: Void.self) { g in
            for t in targets {
                g.addTask { await self.probe(t, gen: gen) }
            }
            // A handful of routes at a time: each can take 20 seconds when the far end is silent.
            var started = 0
            func next(_ g: inout TaskGroup<Void>) {
                guard started < routeList.count else { return }
                let (_, ip) = routeList[started]
                started += 1
                g.addTask { await self.trace(ip, tunnel: vendor, gen: gen) }
            }
            for _ in 0..<min(5, routeList.count) { next(&g) }
            while await g.next() != nil { next(&g) }
        }
        if let c = await certificate?.value { await update(gen) { $0.certificate = c } }
    }

    /// Reverse name, owner, ping and connect times for one address.
    private nonisolated func probe(_ ip: String, gen: Int) async {
        async let ptr = dig(gen, ["-x", ip, "+short", "+time=2", "+tries=1"])
        async let ping = run(gen, ip.contains(":") ? "/sbin/ping6" : "/sbin/ping", ["-c", "4", "-i", "0.2"] + (ip.contains(":") ? [] : ["-t", "5"]) + [ip], timeout: 8)
        async let p443 = Self.connect(ip, 443)
        async let p80 = Self.connect(ip, 80)
        await owners([ip], gen: gen)
        let name = (await ptr).split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let p = CheckParse.ping(await ping)
        let ports = [443: await p443, 80: await p80]
        await update(gen) { r in
            guard let i = r.targets.firstIndex(where: { $0.address == ip }) else { return }
            r.targets[i].ptr = name.flatMap { $0.hasPrefix(";") ? nil : $0 }
            r.targets[i].pingMs = p?.avg
            r.targets[i].loss = p?.loss ?? 100
            r.targets[i].ports = ports
        }
    }

    private nonisolated func trace(_ ip: String, tunnel: String, gen: Int) async {
        let six = ip.contains(":")
        let via = NetParse.routeGet(await run(gen, "/sbin/route", ["-n", "get", six ? "-inet6" : "-inet", ip], timeout: 4))
        if DNSMap.isTunnelInterface(via.interface) {
            await update(gen) { r in
                for i in r.routes.indices where r.routes[i].address == ip {
                    r.routes[i].interface = via.interface
                    r.routes[i].tunnel = tunnel
                    r.routes[i].onThisMac = via.gateway == ip
                    r.routes[i].done = true
                }
            }
            return
        }
        await update(gen) { r in for i in r.routes.indices where r.routes[i].address == ip { r.routes[i].interface = via.interface } }
        let out = await run(gen, six ? "/usr/sbin/traceroute6" : "/usr/sbin/traceroute", ["-n", "-w", "1", "-q", "1", "-m", "20", ip], timeout: 45)
        let hops = NetParse.traceroute(out)
        await update(gen) { r in
            for i in r.routes.indices where r.routes[i].address == ip {
                r.routes[i].hops = hops
                r.routes[i].done = true
            }
        }
        await owners(hops.compactMap(\.address), gen: gen)
    }

    /// One DNS-over-HTTPS lookup, logged like the commands.
    private nonisolated func doh(_ gen: Int, _ label: String, _ endpoint: String, _ name: String) async -> DNSMapResult.ServerAnswer {
        let t0 = Date()
        let body = await fetch(gen, "\(endpoint)?name=\(name)&type=A", accept: "application/dns-json")
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let d = NetParse.dohJSON(Data(body.utf8))
        return .init(server: label, scope: "over HTTPS, skips the DNS here", status: d?.status, ms: d == nil ? nil : ms,
                     addresses: d?.addresses ?? [], cnames: d?.cnames ?? [], viaHTTPS: true)
    }

    /// A GET with no cookies or cache, logged like the commands.
    private nonisolated func fetch(_ gen: Int, _ url: String, accept: String? = nil) async -> String {
        guard let u = URL(string: url) else { return "" }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: u)
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        let t0 = Date()
        var out: String
        do {
            let (data, resp) = try await session.data(for: req)
            out = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)\n" + (String(data: data, encoding: .utf8) ?? "")
        } catch {
            out = "failed: \(error.localizedDescription)"
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let shown = out.count > 4000 ? String(out.prefix(4000)) + "…" : out
        await update(gen) { $0.commands.append(.init(command: "GET \(url)", ms: ms, output: shown)) }
        return out.hasPrefix("HTTP 200\n") ? String(out.dropFirst(9)) : ""
    }

    /// Looks up who runs each public address not already known.
    private nonisolated func owners(_ ips: [String], gen: Int) async {
        let known = await MainActor.run { Set(self.result?.owners.keys.map { $0 } ?? []) }
        let todo = Array(Set(ips.filter { !DNSMap.isPrivate($0) && !known.contains($0) }))
        guard !todo.isEmpty else { return }
        let found: [(String, NetOwner)] = await withTaskGroup(of: (String, NetOwner)?.self) { g in
            for ip in todo {
                g.addTask {
                    guard let q = DNSMap.cymruQuery(ip),
                          var o = NetParse.cymruOrigin(sh("/usr/bin/dig", [q, "TXT", "+short", "+time=2", "+tries=1"], timeout: 5)) else { return nil }
                    o.name = await Self.asName(o.asn)
                    return (ip, o)
                }
            }
            var out: [(String, NetOwner)] = []
            for await x in g { if let x { out.append(x) } }
            return out
        }
        await update(gen) { r in for (ip, o) in found { r.owners[ip] = o } }
    }

    private static let asNames = ASNameCache()

    nonisolated static func asName(_ asn: Int) async -> String? {
        if let n = await asNames.get(asn) { return n }
        let n = NetParse.cymruName(sh("/usr/bin/dig", ["AS\(asn).asn.cymru.com", "TXT", "+short", "+time=2", "+tries=1"], timeout: 5))
        await asNames.set(asn, n)
        return n
    }

    /// Connect time in ms, or -1 when refused or nothing answered in 3 seconds.
    nonisolated static func connect(_ ip: String, _ port: UInt16) async -> Int {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let t0 = Date()
            let once = Once()
            let finish: (Int) -> Void = { ms in
                guard once.fire() else { return }
                conn.cancel()
                cont.resume(returning: ms)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Int(Date().timeIntervalSince(t0) * 1000))
                case .failed, .waiting: finish(-1)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(-1) }
        }
    }
}

private actor ASNameCache {
    private var names: [Int: String?] = [:]
    func get(_ asn: Int) -> String?? { names[asn] }
    func set(_ asn: Int, _ name: String?) { names[asn] = name }
}

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// The certificate a name presents over HTTPS, and whether the Mac trusts it.
final class CertProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private var chain: [SecCertificate] = []

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        }
        completionHandler(.performDefaultHandling, nil)
    }

    static func inspect(_ host: String) async -> DNSMapResult.Certificate? {
        guard let url = URL(string: "https://\(host)/") else { return nil }
        let probe = CertProbe()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: cfg, delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        var c = DNSMapResult.Certificate()
        do { _ = try await session.data(for: req) } catch {
            let e = error as NSError
            // No HTTPS at all is not a certificate problem.
            if probe.chain.isEmpty { return nil }
            c.error = e.localizedDescription
        }
        guard let leaf = probe.chain.first else { return nil }
        c.leaf = SecCertificateCopySubjectSummary(leaf) as String?
        if probe.chain.count > 1 { c.issuer = SecCertificateCopySubjectSummary(probe.chain[1]) as String? }
        if let root = probe.chain.last {
            c.root = SecCertificateCopySubjectSummary(root) as String?
            var anchors: CFArray?
            SecTrustCopyAnchorCertificates(&anchors)
            let system = Set(((anchors as? [SecCertificate]) ?? []).map { SecCertificateCopyData($0) as Data })
            c.rootIsSystem = system.contains(SecCertificateCopyData(root) as Data)
        }
        if let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
           let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
           let n = entry[kSecPropertyKeyValue] as? NSNumber {
            c.expires = Date(timeIntervalSinceReferenceDate: n.doubleValue)
        }
        return c
    }
}

/// The map in its own window, which stays open while you work.
@MainActor
enum DNSMapWindow {
    private static var window: NSWindow?

    static func show(_ name: String? = nil) {
        let store = DNSMapStore.shared
        if let name { store.input = name }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: DNSMapView(store: store)))
            w.title = "DNS map"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 920, height: 760))
            w.setFrameAutosaveName("DNSMapWindow")
            if !w.setFrameUsingName("DNSMapWindow") { w.center() }
            w.dropContentOnClose { window = nil }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if name != nil { store.start() }
    }
}
