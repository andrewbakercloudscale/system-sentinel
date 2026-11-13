import Foundation

/// Security, data loss prevention and monitoring software that inspects what the Mac does as
/// it happens. Usually invisible; when one falls behind it can slow or freeze the whole Mac,
/// and an Endpoint Security client that stops answering can end in a kernel panic.
public struct SecurityAgent: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Comparable {
        case dlp = "data loss prevention"
        case edr = "endpoint protection"
        case monitoring = "activity monitoring"
        case zeroTrust = "zero trust network"
        case vpn = "VPN"
        case unknown = "security extension"

        /// Inspects files as they are written, so the kind most likely to stall the Mac.
        var rank: Int { [.dlp: 0, .edr: 1, .monitoring: 2, .unknown: 3, .zeroTrust: 4, .vpn: 5][self]! }
        public static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
    }

    public var name: String
    public var kind: Kind
    /// Has an Endpoint Security extension: macOS waits for it on every file and program opened.
    public var endpointSecurity = false
    /// Has a network extension: it sees all traffic.
    public var networkFilter = false
    /// CPU now, in percent of one core, across its processes.
    public var cpu: Double = 0
    public var id: String { name }

    /// Could make the Mac slow, freeze or panic: anything but a plain VPN or zero trust tunnel.
    public var suspect: Bool { endpointSecurity || [.dlp, .edr, .monitoring, .unknown].contains(kind) }

    /// "CrowdStrike Falcon: endpoint protection, sees every file and program opened, 12% CPU now".
    public var line: String {
        var parts = [kind.rawValue]
        if endpointSecurity { parts.append("sees every file and program opened") }
        if networkFilter { parts.append("filters network traffic") }
        if cpu >= 1 { parts.append("\(Int(cpu.rounded()))% CPU now") }
        return "\(name): " + parts.joined(separator: ", ")
    }
}

public enum SecurityAgents {
    /// Products by a piece of their bundle id or process name (lowercased).
    static let known: [(match: [String], name: String, kind: SecurityAgent.Kind)] = [
        (["avasecurity", "ava.reveal", "avareveal", "ava-reveal", "ava_reveal"], "Ava Reveal", .dlp),
        (["forcepoint", "websense", "fpneo"], "Forcepoint", .dlp),
        (["code42", "incydr"], "Code42 Incydr", .dlp),
        (["digitalguardian", "dgagent", "com.dg."], "Digital Guardian", .dlp),
        (["symantec", "edpa"], "Symantec DLP", .dlp),
        (["netskope", "stagentsvc"], "Netskope", .dlp),
        (["crowdstrike", "falcond"], "CrowdStrike Falcon", .edr),
        (["sentinelone", "sentineld", "sentinelagent"], "SentinelOne", .edr),
        (["wdav", "com.microsoft.wdav", "microsoft defender"], "Microsoft Defender", .edr),
        (["jamf.protect", "jamfprotect"], "Jamf Protect", .edr),
        (["mcafee", "trellix"], "Trellix (McAfee)", .edr),
        (["sophos"], "Sophos", .edr),
        (["carbonblack", "cbagentd"], "Carbon Black", .edr),
        (["paloaltonetworks", "cortex xdr", "com.paloaltonetworks.cortex"], "Cortex XDR", .edr),
        (["elastic-endpoint", "co.elastic.endpoint"], "Elastic Endpoint", .edr),
        (["ampdaemon", "com.cisco.endpoint", "cisco.amp"], "Cisco Secure Endpoint", .edr),
        (["eset"], "ESET", .edr),
        (["kaspersky"], "Kaspersky", .edr),
        (["tanium"], "Tanium", .monitoring),
        (["teramind"], "Teramind", .monitoring),
        (["activtrak"], "ActivTrak", .monitoring),
        (["zscaler"], "Zscaler", .zeroTrust),
        (["cloudflare warp", "warp-svc", "com.cloudflare.1dot1dot1dot1"], "Cloudflare WARP", .zeroTrust),
        (["tailscale"], "Tailscale", .vpn),
        (["globalprotect", "pangps"], "GlobalProtect", .vpn),
        (["vpnagentd", "acvpnagent", "anyconnect"], "Cisco Secure Client", .vpn),
        (["openvpn"], "OpenVPN", .vpn),
        (["wireguard"], "WireGuard", .vpn),
        (["nordvpn"], "NordVPN", .vpn),
        (["fortitray", "forticlient", "fortivpn"], "FortiClient", .vpn),
    ]

    /// A known product named in `text`. A pattern must start a word ("eset" matches ESET or
    /// com.eset, never the middle of PasscodeSettings or Reset).
    static func product(_ text: String) -> (name: String, kind: SecurityAgent.Kind)? {
        let t = text.lowercased()
        func starts(_ p: String) -> Bool {
            var from = t.startIndex
            while let r = t.range(of: p, range: from..<t.endIndex) {
                if r.lowerBound == t.startIndex || !t[t.index(before: r.lowerBound)].isLetter { return true }
                from = t.index(after: r.lowerBound)
            }
            return false
        }
        return known.first { $0.match.contains(where: starts) }.map { ($0.name, $0.kind) }
    }

    /// macOS's own programs, which no third-party agent lives among.
    static func isApple(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// `systemextensionsctl list`: the active Endpoint Security and network extensions, as
    /// (category, bundle id, name). Rows marked waiting to uninstall are left out.
    public static func systemExtensions(_ s: String) -> [(category: String, bundleID: String, name: String)] {
        var category = ""
        var out: [(category: String, bundleID: String, name: String)] = []
        for line in s.split(separator: "\n").map(String.init) {
            if line.hasPrefix("--- ") {
                category = line.contains("endpoint_security") ? "endpoint_security" : line.contains("network_extension") ? "network_extension" : "other"
                continue
            }
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5, f[0] == "*", f[1] == "*" else { continue }
            let bundleID = f[3].components(separatedBy: " (").first ?? f[3]
            out.append((category, bundleID, f[4]))
        }
        return out
    }

    /// The agents on this Mac, from its system extensions and running processes (with their
    /// CPU now), worst kind first. An Endpoint Security extension from an unknown vendor is
    /// listed by its own name, so a product missing from the table is still found.
    public static func find(extensions: String, processes: [(name: String, cpu: Double)]) -> [SecurityAgent] {
        var by: [String: SecurityAgent] = [:]
        for e in systemExtensions(extensions) where e.category != "other" {
            let p = product(e.bundleID + " " + e.name)
            let name = p?.name ?? e.name
            var a = by[name] ?? SecurityAgent(name: name, kind: p?.kind ?? .unknown)
            if e.category == "endpoint_security" { a.endpointSecurity = true } else { a.networkFilter = true }
            by[name] = a
        }
        for proc in processes where !isApple(proc.name) {
            guard let p = product(proc.name) else { continue }
            var a = by[p.name] ?? SecurityAgent(name: p.name, kind: p.kind)
            a.cpu += proc.cpu
            by[p.name] = a
        }
        return by.values.sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    /// What to say beside a kernel panic or freeze when agents that inspect files are here.
    public static func suspectNote(_ agents: [SecurityAgent]) -> String? {
        let s = agents.filter(\.suspect)
        guard !s.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: s.map(\.name))
        return "\(names) \(s.count == 1 ? "inspects" : "inspect") files and programs as they are used. macOS waits for \(s.count == 1 ? "it" : "them") on every file opened; one that falls behind (many files written at once, such as exporting PDFs, unzipping or a build) can freeze the Mac until it restarts itself."
    }
}
