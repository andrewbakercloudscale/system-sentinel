import Foundation

// MARK: DNS map: everything about one name

/// One resource record as `dig` prints it.
public struct DNSRecord: Equatable, Hashable, Sendable {
    public let name: String
    public let ttl: Int
    public let type: String
    public let value: String
    public init(name: String, ttl: Int, type: String, value: String) {
        self.name = name; self.ttl = ttl; self.type = type; self.value = value
    }
}

/// One step of `dig +trace`: the server asked, how long it took, and what it handed back
/// (the next zone's name servers, or the answer).
public struct DelegationStep: Equatable, Sendable {
    public let server: String
    public let address: String
    public let ms: Int?
    public let records: [DNSRecord]
    /// The zone handed over, or the name when this step answered.
    public var zone: String {
        records.first { $0.type == "NS" }?.name ?? records.first?.name ?? ""
    }
    public var isAnswer: Bool { records.contains { !["NS", "RRSIG", "DS", "NSEC", "NSEC3"].contains($0.type) } }
    /// Only a zone's SOA came back: no such name, or no record of that type.
    public var isNoName: Bool { isAnswer && records.allSatisfy { ["SOA", "RRSIG", "NSEC", "NSEC3"].contains($0.type) } }
    public var nameServers: [String] { records.filter { $0.type == "NS" }.map(\.value) }
    public init(server: String, address: String, ms: Int?, records: [DNSRecord]) {
        self.server = server; self.address = address; self.ms = ms; self.records = records
    }
}

/// One line of `traceroute -q 1`: no address when nothing answered at that distance.
public struct Hop: Equatable, Sendable {
    public let n: Int
    public let address: String?
    public let ms: Double?
    public init(n: Int, address: String?, ms: Double?) { self.n = n; self.address = address; self.ms = ms }
}

/// Who runs an address, from Team Cymru's public lookup.
public struct NetOwner: Equatable, Sendable {
    public let asn: Int
    public let prefix: String
    public let country: String
    public var name: String?
    public init(asn: Int, prefix: String, country: String, name: String? = nil) {
        self.asn = asn; self.prefix = prefix; self.country = country; self.name = name
    }
    public var label: String { "AS\(asn)" + (name.map { " \($0)" } ?? "") }
}

extension NetParse {
    /// Records from `dig`: the answer section of a full printout, or every line of a
    /// `+noall +answer` one.
    public static func records(_ s: String) -> [DNSRecord] {
        let sectioned = s.contains(" SECTION:")
        var inAnswer = !sectioned
        var out: [DNSRecord] = []
        for line in s.split(separator: "\n") {
            if line.hasPrefix(";; ANSWER SECTION") { inAnswer = true; continue }
            if line.hasPrefix(";;") && sectioned { inAnswer = false; continue }
            guard inAnswer, !line.hasPrefix(";"), let r = record(line) else { continue }
            out.append(r)
        }
        return out
    }

    static func record(_ line: Substring) -> DNSRecord? {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard f.count >= 5, f[2] == "IN", let ttl = Int(f[1]) else { return nil }
        let type = String(f[3])
        var value = f[4...].joined(separator: " ")
        if ["CNAME", "NS", "PTR", "DNAME"].contains(type), value.hasSuffix(".") { value.removeLast() }
        return DNSRecord(name: trimDot(String(f[0])), ttl: ttl, type: type, value: value)
    }

    static func trimDot(_ s: String) -> String { s.count > 1 && s.hasSuffix(".") ? String(s.dropLast()) : s }

    /// `dig +trace`: records pile up until the "Received … from" line that says who sent them.
    public static func digTrace(_ s: String) -> [DelegationStep] {
        var out: [DelegationStep] = []
        var pending: [DNSRecord] = []
        for line in s.split(separator: "\n") {
            if line.hasPrefix(";; Received"), let from = line.range(of: " from ") {
                // ";; Received 839 bytes from 192.5.5.241#53(f.root-servers.net) in 8 ms"
                let rest = line[from.upperBound...]
                let address = String(rest.prefix { $0 != "#" && $0 != " " })
                var server = address
                if let o = rest.firstIndex(of: "("), let c = rest.firstIndex(of: ")"), o < c {
                    server = trimDot(String(rest[rest.index(after: o)..<c]))
                }
                var ms: Int?
                if let r = rest.range(of: " in ") { ms = Int(rest[r.upperBound...].prefix { $0.isNumber }) }
                out.append(DelegationStep(server: server, address: address, ms: ms, records: pending))
                pending = []
            } else if !line.hasPrefix(";"), let r = record(line) {
                pending.append(r)
            }
        }
        return out
    }

    /// `traceroute -n -q 1`.
    public static func traceroute(_ s: String) -> [Hop] {
        s.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 2, let n = Int(f[0]) else { return nil }
            if f[1] == "*" { return Hop(n: n, address: nil, ms: nil) }
            let ms = f.count >= 3 ? Double(f[2]) : nil
            return Hop(n: n, address: String(f[1]), ms: ms)
        }
    }

    /// Team Cymru's origin TXT: "8075 | 20.64.0.0/10 | US | arin | 2017-10-18".
    public static func cymruOrigin(_ s: String) -> NetOwner? {
        let f = s.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 3, let asn = Int(f[0].split(separator: " ").first ?? "") else { return nil }
        return NetOwner(asn: asn, prefix: f[1], country: f[2])
    }

    /// Team Cymru's AS TXT: "8075 | US | arin | 1997-03-31 | MICROSOFT-CORP-MSN-AS-BLOCK - Microsoft Corporation, US".
    public static func cymruName(_ s: String) -> String? {
        let f = s.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 5, !f[4].isEmpty else { return nil }
        var name = f[4]
        if let dash = name.range(of: " - ") { name = String(name[dash.upperBound...]) }
        if let comma = name.range(of: ", ", options: .backwards), name[comma.upperBound...].count == 2 { name = String(name[..<comma.lowerBound]) }
        return name
    }
}

/// What the map found, worst first.
public struct MapFinding: Equatable, Sendable {
    public enum Tone: Int, Sendable, Comparable {
        case problem, warning, note, ok
        public static func < (a: Tone, b: Tone) -> Bool { a.rawValue < b.rawValue }
    }
    public let tone: Tone
    public let text: String
    public init(_ tone: Tone, _ text: String) { self.tone = tone; self.text = text }
}

/// Everything learned about one name, filled in as the checks finish.
public struct DNSMapResult: Sendable {
    public struct ServerAnswer: Equatable, Sendable {
        public var server: String
        public var scope: String
        public var status: String?
        public var ms: Int?
        public var addresses: [String]
        public var cnames: [String]
        public init(server: String, scope: String, status: String?, ms: Int?, addresses: [String], cnames: [String]) {
            self.server = server; self.scope = scope; self.status = status; self.ms = ms; self.addresses = addresses; self.cnames = cnames
        }
    }
    public struct Authority: Equatable, Sendable {
        public var name: String
        public var address: String?
        public var status: String?
        public var ms: Int?
        public var serial: UInt?
        public var addresses: [String]
        public init(name: String, address: String?, status: String?, ms: Int?, serial: UInt?, addresses: [String]) {
            self.name = name; self.address = address; self.status = status; self.ms = ms; self.serial = serial; self.addresses = addresses
        }
    }
    public struct Target: Equatable, Sendable {
        public var address: String
        public var ptr: String?
        public var pingMs: Double?
        public var loss: Double?
        /// Connect time in ms per port; nil until tried, -1 when refused or timed out.
        public var ports: [Int: Int] = [:]
        public init(address: String) { self.address = address }
    }
    public struct Route: Equatable, Sendable {
        public var label: String
        public var address: String
        public var hops: [Hop] = []
        public var done = false
        public init(label: String, address: String) { self.label = label; self.address = address }
        /// Hops up to the last that answered, and how many silent ones followed it.
        public var shown: (hops: [Hop], silent: Int) {
            guard let last = hops.lastIndex(where: { $0.address != nil }) else { return ([], hops.count) }
            return (Array(hops[...last]), hops.count - last - 1)
        }
        public var reached: Bool { hops.contains { $0.address == address } }
    }
    public struct Certificate: Equatable, Sendable {
        public var leaf: String?
        public var issuer: String?
        public var root: String?
        public var rootIsSystem = true
        public var expires: Date?
        public var error: String?
        public init() {}
    }
    public struct Command: Equatable, Sendable {
        public let command: String
        public let ms: Int
        public let output: String
        public init(command: String, ms: Int, output: String) { self.command = command; self.ms = ms; self.output = output }
    }

    public var query: String
    public var at: Date
    public var hostsEntry: HostsEntry?
    /// The Mac's own lookup (getaddrinfo): nil until done.
    public var system: [String]?
    public var systemMs: Int?
    public var resolver: Resolver?
    public var resolverWhy = ""
    public var answers: [ServerAnswer] = []
    public var records: [DNSRecord] = []
    public var status: String?
    public var zone: String?
    public var soa: String?
    public var signed: Bool?
    public var delegation: [DelegationStep] = []
    public var authorities: [Authority] = []
    public var targets: [Target] = []
    public var routes: [Route] = []
    public var owners: [String: NetOwner] = [:]
    public var certificate: Certificate?
    public var commands: [Command] = []

    public init(query: String, at: Date) { self.query = query; self.at = at }

    public var isIP: Bool { DNSMap.isIP(query) }
    /// The name and each CNAME it points at, in order.
    public var chain: [String] { DNSMap.chain(records, from: query) }
}

public enum DNSMap {
    /// A host from whatever was typed: a URL, host:port, user@host or a bare name.
    public static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("://"), let host = URLComponents(string: s)?.host { s = host }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") { s = String(s[s.index(after: s.startIndex)..<close]) }
        else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        s = s.lowercased()
        if s.hasSuffix(".") { s.removeLast() }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:"))
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ ok.contains($0) }) else { return nil }
        return s
    }

    public static func isIP(_ s: String) -> Bool { bytes(s) != nil }

    static func bytes(_ s: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// Addresses that only mean something inside a network: private, shared (CGNAT, which
    /// VPNs such as Zscaler use), loopback and link-local.
    public static func isPrivate(_ s: String) -> Bool {
        guard let b = bytes(s) else { return false }
        if b.count == 4 {
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 100 && b[1] & 0xc0 == 64) || (b[0] == 169 && b[1] == 254)
        }
        return b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80) || b == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// The DNS name for Team Cymru's origin lookup of an address.
    public static func cymruQuery(_ s: String) -> String? {
        guard let b = bytes(s) else { return nil }
        if b.count == 4 { return b.reversed().map(String.init).joined(separator: ".") + ".origin.asn.cymru.com" }
        let nibbles = b.flatMap { [$0 >> 4, $0 & 0xf] }.reversed().map { String($0, radix: 16) }
        return nibbles.joined(separator: ".") + ".origin6.asn.cymru.com"
    }

    /// Which resolver macOS asks for a name: the most specific split domain that covers it,
    /// else the main one.
    public static func resolver(for name: String, in resolvers: [Resolver]) -> (Resolver?, String) {
        let split = resolvers.filter { r in
            guard let d = r.domain, r.supplemental, !r.servers.isEmpty, !r.mdns else { return false }
            return name == d || name.hasSuffix("." + d)
        }.max { ($0.domain ?? "").count < ($1.domain ?? "").count }
        if let s = split {
            return (s, "\(name) is under \(s.domain ?? ""), which is sent to \(s.servers.joined(separator: ", ")) only (split DNS, usually a VPN)")
        }
        if name.hasSuffix(".local") { return (nil, "Names ending .local are found by Bonjour on this network, not by a DNS server") }
        if let main = resolvers.first(where: { !$0.supplemental && !$0.mdns && !$0.servers.isEmpty }) {
            return (main, "Asked \(main.servers[0]) first" + (main.servers.count > 1 ? ", then \(main.servers.dropFirst().joined(separator: ", ")) if it does not answer" : ""))
        }
        if let any = resolvers.first(where: { $0.domain == nil && !$0.mdns && !$0.servers.isEmpty }) {
            return (any, "Asked \(any.servers.joined(separator: ", ")) (set by a VPN or profile)")
        }
        return (nil, "No DNS server is set up")
    }

    /// The name and each CNAME after it.
    public static func chain(_ records: [DNSRecord], from name: String) -> [String] {
        var out = [name]
        var cur = name
        while let next = records.first(where: { $0.type == "CNAME" && $0.name.lowercased() == cur.lowercased() })?.value,
              !out.contains(next), out.count < 12 {
            out.append(next)
            cur = next
        }
        return out
    }

    public static func ttl(_ s: Int) -> String {
        if s < 120 { return "\(s) s" }
        if s < 7200 { return "\(s / 60) min" }
        if s < 172_800 { return "\(s / 3600) h" }
        return "\(s / 86400) days"
    }

    /// The SOA serial from `+short` output: "ns hostmaster 1656468023 43200 …".
    public static func serial(_ soa: String) -> UInt? {
        let f = soa.split(separator: " ")
        return f.count >= 3 ? UInt(f[2]) : nil
    }

    // MARK: Findings

    public static func findings(_ r: DNSMapResult, now: Date = Date()) -> [MapFinding] {
        var out: [MapFinding] = []
        let name = r.query
        if let h = r.hostsEntry {
            out.append(.init(.warning, "/etc/hosts sends \(name) to \(h.address) on this Mac, whatever DNS says"))
        }
        if r.status == "NXDOMAIN" {
            out.append(.init(.problem, "\(name) does not exist in DNS (NXDOMAIN): check the spelling, or it is only known inside a network you are not on"))
        } else if let s = r.status, s != "NOERROR" {
            out.append(.init(.problem, "The DNS server returned \(s) for \(name)" + (s == "SERVFAIL" ? ": its name servers are broken or not answering" : "")))
        }
        if let sys = r.system, sys.isEmpty, r.answers.contains(where: { !$0.addresses.isEmpty }) {
            out.append(.init(.problem, "DNS servers answer, but the Mac's own lookup fails: a VPN, profile or filter is in the way"))
        }
        if r.resolver?.supplemental == true, let d = r.resolver?.domain {
            out.append(.init(.note, "Looked up by the VPN's servers only (split DNS for \(d)): off the VPN it will not resolve"))
        }
        for a in r.answers where a.status == nil {
            out.append(.init(.warning, "\(a.server) did not answer within 2 seconds"))
        }
        // Servers that answer differently.
        let answered = r.answers.filter { $0.status != nil }
        let statuses = Set(answered.compactMap(\.status))
        if statuses.count > 1 {
            let say = answered.map { "\($0.server) \($0.status ?? "")" }.joined(separator: ", ")
            out.append(.init(.warning, "DNS servers disagree on whether \(name) exists: \(say). The name is visible only from some networks"))
        } else {
            let sets = answered.filter { !$0.addresses.isEmpty }
            let privateOnes = sets.filter { $0.addresses.allSatisfy(isPrivate) }
            if !privateOnes.isEmpty, privateOnes.count < sets.count {
                out.append(.init(.warning, "\(privateOnes.map(\.server).joined(separator: ", ")) give\(privateOnes.count == 1 ? "s" : "") an internal address and the others a public one: which you reach depends on the server asked"))
            } else if sets.count > 1, Set(sets.map { Set($0.addresses) }).count > 1 {
                out.append(.init(.note, "Servers give different addresses. Normal for a CDN, which answers with the copy nearest each server"))
            }
        }
        let addresses = r.system ?? r.records.filter { $0.type == "A" || $0.type == "AAAA" }.map(\.value)
        if !addresses.isEmpty, addresses.allSatisfy(isPrivate), !r.isIP {
            out.append(.init(.note, "Resolves to an internal address (\(addresses[0])): reachable only on that network or over the VPN"))
        }
        if let short = r.records.filter({ ["A", "AAAA", "CNAME"].contains($0.type) }).map(\.ttl).min(), short <= 60 {
            out.append(.init(.note, "Short cache time (\(ttl(short))): the address changes often, typical of a CDN or failover"))
        }
        let quiet = r.authorities.filter { $0.address != nil && $0.status == nil }
        if !quiet.isEmpty, quiet.count < r.authorities.count {
            out.append(.init(.warning, "Name server\(quiet.count == 1 ? "" : "s") \(quiet.map(\.name).joined(separator: ", ")) did not answer: lookups that pick \(quiet.count == 1 ? "it" : "them") are slow or fail"))
        } else if !quiet.isEmpty {
            out.append(.init(.problem, "None of \(name)'s own name servers answered from here"))
        }
        // Two DNS providers keep their own serials; only different answers matter then.
        let serials = Set(r.authorities.compactMap(\.serial))
        let authAnswers = Set(r.authorities.filter { $0.status == "NOERROR" }.map { Set($0.addresses) })
        if authAnswers.count > 1 {
            out.append(.init(.warning, "\(name)'s own name servers give different answers" + (serials.count > 1 ? " (zone serials \(serials.sorted().map(String.init).joined(separator: ", ")))" : "")
                             + ": a recent change has not reached all of them, or they are out of sync"))
        } else if serials.count > 1 {
            out.append(.init(.note, "The name servers come from more than one DNS provider (their serials differ, their answers match)"))
        }
        let tried = r.targets.filter { $0.ports.count == 2 }
        if !tried.isEmpty {
            let open = tried.filter { $0.ports.values.contains { $0 >= 0 } }
            if open.isEmpty {
                out.append(.init(.problem, "No address accepts connections on 443 or 80: the service is down, or a firewall is in the way"))
            } else if open.count < tried.count {
                out.append(.init(.warning, "\(tried.count - open.count) of \(tried.count) addresses refuse connections: some visits will fail"))
            }
            if tried.allSatisfy({ $0.loss == 100 }), !open.isEmpty {
                out.append(.init(.note, "Ping is blocked, but connections work. Common and harmless"))
            }
        }
        if let c = r.certificate {
            if let e = c.error { out.append(.init(.problem, "HTTPS fails: \(e)")) }
            if !c.rootIsSystem, let root = c.root {
                out.append(.init(.warning, "HTTPS is decrypted on the way by \(root): command-line tools need its certificate"))
            }
            if let exp = c.expires {
                let days = Int(exp.timeIntervalSince(now) / 86400)
                if days < 0 { out.append(.init(.problem, "The certificate expired \(-days) days ago")) }
                else if days < 14 { out.append(.init(.warning, "The certificate expires in \(days) days")) }
            }
        }
        out.sort { $0.tone < $1.tone }
        // All well: say so first, notes after.
        if out.allSatisfy({ $0.tone == .note }), let sys = r.system, !sys.isEmpty {
            let ms = r.systemMs.map { " in \($0) ms" } ?? ""
            out.insert(.init(.ok, "\(name) resolves to \(sys.count) address\(sys.count == 1 ? "" : "es")\(ms)" + (tried.isEmpty ? "" : " and accepts connections")), at: 0)
        }
        return out
    }

    // MARK: Report

    /// Plain text of everything, for pasting into a ticket.
    public static func report(_ r: DNSMapResult) -> String {
        var s = "DNS map of \(r.query), \(ISO8601DateFormatter().string(from: r.at))\n\n"
        s += "FINDINGS\n" + findings(r).map { "- \($0.text)" }.joined(separator: "\n") + "\n\n"
        s += "THIS MAC\n- Lookup: " + (r.system.map { $0.isEmpty ? "failed" : $0.joined(separator: ", ") } ?? "not run")
        s += r.systemMs.map { " (\($0) ms)" } ?? ""
        s += "\n- \(r.resolverWhy)\n"
        if let h = r.hostsEntry { s += "- /etc/hosts: \(h.names.joined(separator: " ")) -> \(h.address)\n" }
        s += "\nEACH DNS SERVER\n"
        for a in r.answers {
            s += "- \(a.server) (\(a.scope)): \(a.status ?? "no answer")" + (a.ms.map { ", \($0) ms" } ?? "")
            s += a.addresses.isEmpty ? "\n" : " -> \(a.addresses.joined(separator: ", "))\n"
        }
        s += "\nRECORDS\n" + r.records.map { "- \($0.name) \(ttl($0.ttl)) \($0.type) \($0.value)" }.joined(separator: "\n") + "\n"
        if let z = r.zone { s += "- Zone \(z)" + (r.signed.map { $0 ? ", DNSSEC signed" : ", not DNSSEC signed" } ?? "") + "\n" }
        if !r.delegation.isEmpty {
            s += "\nDELEGATION\n"
            for d in r.delegation {
                s += "- \(d.server) (\(d.address))" + (d.ms.map { " \($0) ms" } ?? "")
                s += d.isNoName ? ": no such name\n" : d.isAnswer ? ": answered\n" : ": sent to \(d.zone) at \(d.nameServers.prefix(4).joined(separator: ", "))\n"
            }
        }
        if !r.authorities.isEmpty {
            s += "\nNAME SERVERS\n"
            for a in r.authorities {
                s += "- \(a.name) \(a.address ?? "?"): \(a.status ?? "no answer")" + (a.ms.map { ", \($0) ms" } ?? "")
                s += (a.serial.map { ", serial \($0)" } ?? "") + "\n"
            }
        }
        if !r.targets.isEmpty {
            s += "\nADDRESSES\n"
            for t in r.targets {
                s += "- \(t.address)" + (t.ptr.map { " (\($0))" } ?? "") + (r.owners[t.address].map { ", \($0.label), \($0.country)" } ?? "")
                s += t.pingMs.map { String(format: ", ping %.0f ms", $0) } ?? (t.loss == 100 ? ", no ping reply" : "")
                for (p, ms) in t.ports.sorted(by: { $0.key > $1.key }) { s += ms >= 0 ? ", \(p) open \(ms) ms" : ", \(p) closed" }
                s += "\n"
            }
        }
        for route in r.routes {
            s += "\nROUTE TO \(route.label) (\(route.address))\n"
            let shown = route.shown
            for h in shown.hops {
                s += String(format: "%3d  ", h.n) + (h.address ?? "*")
                s += h.ms.map { String(format: "  %.1f ms", $0) } ?? ""
                s += h.address.flatMap { r.owners[$0] }.map { "  \($0.label)" } ?? ""
                s += "\n"
            }
            if shown.silent > 0 { s += "     then \(shown.silent) hops with no reply\n" }
        }
        if let c = r.certificate {
            s += "\nHTTPS\n- " + (c.error ?? "\(c.leaf ?? "?"), issued by \(c.issuer ?? "?"), root \(c.root ?? "?")") + "\n"
        }
        return s
    }
}
