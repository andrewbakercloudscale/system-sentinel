import SwiftUI
import SentinelCore

private let mapTint = Tab.network.color
private let okColor = Tab.battery.color
private let amber = Color(hex: "#d97706")

/// The DNS map window: type a name, see everything about how it is found and reached.
struct DNSMapView: View {
    @ObservedObject var store: DNSMapStore
    /// Everything at full height with no scrolling, for snapshots.
    var fullLength = false
    @StateObject private var tips = TipCenter()

    var body: some View {
        VStack(spacing: 0) {
            header.padding(14)
            Divider()
            if fullLength { content } else { ScrollView { content } }
        }
        .frame(minWidth: 760, minHeight: fullLength ? nil : 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .tipsAndConfirmations(tips, surface: "dnsmap")
    }

    @ViewBuilder private var content: some View {
                if let r = store.result {
                    VStack(alignment: .leading, spacing: 12) {
                        FindingsCard(result: r, running: store.running)
                        FlowCard(result: r)
                        HStack(alignment: .top, spacing: 12) {
                            MacCard(result: r)
                            ServersCard(result: r)
                        }
                        if !r.isIP {
                            RecordsCard(result: r)
                            HStack(alignment: .top, spacing: 12) {
                                DelegationCard(result: r)
                                AuthorityCard(result: r)
                            }
                        }
                        AddressesCard(result: r)
                        if !r.tunnels.isEmpty { TunnelCard(result: r) }
                        RoutesCard(result: r)
                        if let c = r.certificate { CertCard(cert: c, host: r.query) }
                        CommandsCard(result: r)
                    }
                    .padding(14)
                } else {
                    empty
                }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(mapTint).font(.title3)
                TextField("A name, URL or address: github.com, https://jira.example.com/browse, 10.0.0.5", text: $store.input)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    .onSubmit { store.start() }
                if store.running {
                    Button("Stop") { store.stop() }.tip("Stop the checks still running. What was found is kept")
                } else {
                    Button("Map it") { store.start() }.keyboardShortcut(.defaultAction)
                        .tip("Look the name up every way there is, then ping, connect to and trace every address. About a minute; only reads")
                }
                Button { store.copyReport() } label: { Label("Copy report", systemImage: "doc.on.doc") }
                    .tip("Copy everything found as plain text, ready to paste into a ticket")
                    .disabled(store.result == nil)
            }
            HStack(spacing: 6) {
                if store.running { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        guard let r = store.result else { return "Asks every DNS server, walks down from the root, checks the name's own servers, then pings, connects to and traces every address and server." }
        let n = r.commands.count
        return store.running ? "\(store.step). \(n) checks done, \(store.pending) running." : "\(store.step): \(n) checks on \(r.query)."
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe.badge.chevron.backward").font(.system(size: 40)).foregroundStyle(mapTint)
            Text("Map a name end to end").font(.headline)
            Text("Type the site, service or server that misbehaves and press Return.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 120)
    }
}

// MARK: Pieces

private func toneColor(_ t: MapFinding.Tone) -> Color {
    switch t { case .problem: Theme.heat(100); case .warning: amber; case .note: mapTint; case .ok: okColor }
}

private func toneSymbol(_ t: MapFinding.Tone) -> String {
    switch t { case .problem: "xmark.octagon.fill"; case .warning: "exclamationmark.triangle.fill"; case .note: "info.circle.fill"; case .ok: "checkmark.circle.fill" }
}

private func ms(_ v: Int?) -> String { v.map { "\($0) ms" } ?? "–" }

private func msColor(_ v: Double?) -> Color {
    guard let v else { return .secondary }
    return v < 60 ? okColor : (v < 200 ? amber : Theme.heat(100))
}

private struct Section_: View {
    let title: String
    var body: some View { Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
}

private struct Mono: View {
    let text: String
    var body: some View { Text(text).font(.callout.monospaced()).textSelection(.enabled) }
}

private struct Waiting: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text).font(.caption).foregroundStyle(.secondary) }
    }
}

// MARK: Cards

private struct FindingsCard: View {
    let result: DNSMapResult
    let running: Bool
    var body: some View {
        let list = DNSMap.findings(result)
        Card(title: "What it found", symbol: "stethoscope", tint: mapTint) {
            if list.isEmpty {
                running ? AnyView(Waiting(text: "Checking…")) : AnyView(Text("Nothing stands out.").font(.callout))
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, f in
                Label { Text(f.text).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: toneSymbol(f.tone)).foregroundStyle(toneColor(f.tone)) }
            }
        }
    }
}

/// This Mac → DNS server → name → CNAMEs → addresses, with who runs each address.
private struct FlowCard: View {
    let result: DNSMapResult
    var body: some View {
        Card(title: "The map", symbol: "map", tint: mapTint) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .center, spacing: 6) {
                    Node(kind: "This Mac", value: Model.snapshotDir == nil ? (Host.current().localizedName ?? "Mac") : "MacBook", symbol: "laptopcomputer")
                    if let h = result.hostsEntry {
                        arrow
                        Node(kind: "/etc/hosts", value: h.address, symbol: "doc.text", color: amber)
                    } else if !result.isIP {
                        arrow
                        let dnsRoute = result.routes.first { $0.address == result.resolver?.servers.first }
                        Node(kind: dnsRoute?.onThisMac == true ? "\(dnsRoute?.tunnel ?? "VPN") app, this Mac" : (result.resolver?.supplemental == true ? "VPN DNS" : "DNS server"),
                             value: result.resolver?.servers.first ?? "Bonjour", symbol: "server.rack",
                             detail: result.answers.first { $0.server == result.resolver?.servers.first }.map { ms($0.ms) })
                        ForEach(Array(result.chain.enumerated()), id: \.offset) { i, n in
                            arrow
                            Node(kind: i == 0 ? "Name" : "Alias of", value: n, symbol: i == 0 ? "textformat" : "arrow.turn.down.right")
                        }
                    }
                    arrow
                    VStack(alignment: .leading, spacing: 6) {
                        if result.targets.isEmpty && result.system?.isEmpty == true {
                            Node(kind: "Address", value: "none", symbol: "xmark", color: Theme.heat(100))
                        }
                        if let all = result.system, all.count > result.targets.count {
                            Text("+\(all.count - result.targets.count) more addresses, not traced").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(result.targets, id: \.address) { t in
                            let route = result.routes.first { $0.address == t.address }
                            let open = t.ports.values.contains { $0 >= 0 }
                            Node(kind: result.owners[t.address].map { "\($0.label), \($0.country)" } ?? (DNSMap.isPrivate(t.address) ? "Internal address" : "Address"),
                                 value: t.address, symbol: "network",
                                 color: t.ports.isEmpty ? mapTint : (open ? okColor : Theme.heat(100)),
                                 detail: route.map { r in
                                     let s = r.shown
                                     return r.done ? "\(s.hops.count) hops" + (r.reached ? "" : ", then silent") : "tracing…"
                                 })
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var arrow: some View { Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
}

private struct Node: View {
    let kind: String
    let value: String
    let symbol: String
    var color: Color = mapTint
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(kind, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout.monospaced().weight(.semibold)).lineLimit(1).textSelection(.enabled)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.6)))
    }
}

private struct MacCard: View {
    let result: DNSMapResult
    var body: some View {
        Card(title: "How this Mac looks it up", symbol: "laptopcomputer", tint: mapTint, fill: true) {
            if let sys = result.system {
                HStack {
                    Text("Answer").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(sys.isEmpty ? "nothing" : "\(sys.count) address\(sys.count == 1 ? "" : "es") in \(ms(result.systemMs))")
                        .font(.callout.weight(.semibold)).foregroundStyle(sys.isEmpty ? Theme.heat(100) : .primary)
                }
                if !sys.isEmpty { Mono(text: sys.joined(separator: "  ")).fixedSize(horizontal: false, vertical: true) }
            } else { Waiting(text: "Looking up…") }
            if !result.resolverWhy.isEmpty {
                Text(result.resolverWhy).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let h = result.hostsEntry {
                Label("/etc/hosts overrides it: \(h.address)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(amber)
            }
            if let r = result.resolver, !r.searchDomains.isEmpty {
                Text("Search domains (tried after short names): \(r.searchDomains.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ServersCard: View {
    let result: DNSMapResult
    var body: some View {
        Card(title: "Each DNS server's answer", symbol: "server.rack", tint: mapTint, fill: true) {
            if result.isIP {
                Text("An address: no lookup needed.").font(.caption).foregroundStyle(.secondary)
            } else if result.answers.isEmpty { Waiting(text: "Asking every server…") }
            ForEach(result.answers, id: \.server) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(a.status == nil ? Theme.heat(100) : (a.status == "NOERROR" ? okColor : amber)).frame(width: 8, height: 8)
                        if a.viaHTTPS { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                        Mono(text: a.server)
                        Text(a.scope).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(a.status == nil ? "no answer" : "\(a.status!) · \(ms(a.ms))").font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    if !a.addresses.isEmpty || !a.cnames.isEmpty {
                        Text((a.cnames.map { "→ \($0)" } + [a.addresses.joined(separator: ", ")]).joined(separator: " "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 14)
                    }
                }
            }
        }
    }
}

private struct RecordsCard: View {
    let result: DNSMapResult
    @State private var showAllTXT = false
    var body: some View {
        Card(title: "Records", symbol: "list.bullet.rectangle", tint: mapTint,
             trailing: AnyView(Group {
                 if let z = result.zone {
                     Text("Zone \(z)" + (result.signed.map { $0 ? " · DNSSEC signed" : " · not DNSSEC signed" } ?? ""))
                         .font(.caption).foregroundStyle(.secondary)
                 }
             })) {
            if result.records.isEmpty {
                if result.status == nil { Waiting(text: "Reading A, AAAA, CNAME, MX, TXT, CAA, HTTPS, NS, SOA…") }
                else { Text("No records (\(result.status ?? "")).").font(.callout) }
            }
            let txt = result.records.filter { $0.type == "TXT" }
            let shown = showAllTXT || txt.count <= 4 ? result.records
                : result.records.filter { $0.type != "TXT" || txt.prefix(4).contains($0) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        Text(r.type).font(.caption.weight(.bold)).foregroundStyle(mapTint)
                        Text(r.name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Text(DNSMap.ttl(r.ttl)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(r.value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3)
                    }
                }
            }
            if txt.count > 4 {
                Button(showAllTXT ? "Show fewer TXT records" : "Show all \(txt.count) TXT records (site verifications, SPF mail rules)") { showAllTXT.toggle() }.tip(showAllTXT ? "Show only the first few" : "Show every TXT record")
                    .buttonStyle(.link).font(.caption)
            }
            if let soa = result.soa {
                Text("SOA: \(soa)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct DelegationCard: View {
    let result: DNSMapResult
    var body: some View {
        Card(title: "Walk down from the root", symbol: "arrow.down.to.line", tint: mapTint, fill: true) {
            if result.delegation.isEmpty { Waiting(text: "Following the referrals…") }
            ForEach(Array(result.delegation.enumerated()), id: \.offset) { i, d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(i + 1)").font(.caption.weight(.bold)).frame(width: 16).foregroundStyle(mapTint)
                        Mono(text: d.server).lineLimit(1)
                        Spacer()
                        Text(ms(d.ms)).font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(msColor(d.ms.map(Double.init)))
                    }
                    Text(i == 0 ? "This Mac's server listed the root servers" :
                            d.isNoName ? "Said there is no such name (\(d.zone.isEmpty ? "root" : d.zone) holds no record of it)" :
                            d.isAnswer ? "Answered: " + d.records.filter { $0.type != "NS" }.map { "\($0.type) \($0.value)" }.prefix(3).joined(separator: ", ")
                            : "Handed over \(d.zone) to \(d.nameServers.prefix(3).joined(separator: ", "))" + (d.nameServers.count > 3 ? " +\(d.nameServers.count - 3)" : ""))
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 22).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct AuthorityCard: View {
    let result: DNSMapResult
    var body: some View {
        Card(title: "The name's own servers", symbol: "checkmark.seal", tint: mapTint, fill: true) {
            if result.authorities.isEmpty {
                if result.delegation.isEmpty { Waiting(text: "Waiting for the walk from the root…") }
                else { Text("No name servers found.").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(result.authorities, id: \.name) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(a.status == nil ? Theme.heat(100) : okColor).frame(width: 8, height: 8)
                        Mono(text: a.name).lineLimit(1)
                        Spacer()
                        Text(a.status == nil ? "no answer" : ms(a.ms)).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    Text([a.address, a.serial.map { "serial \($0)" }, a.addresses.isEmpty ? nil : a.addresses.joined(separator: ", ")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).padding(.leading, 14).textSelection(.enabled)
                }
            }
        }
    }
}

private struct AddressesCard: View {
    let result: DNSMapResult
    var body: some View {
        Card(title: "Every address", symbol: "network", tint: mapTint) {
            if result.targets.isEmpty {
                Text(result.system == nil ? "Waiting for the lookup…" : "No addresses to check.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.targets, id: \.address) { t in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Mono(text: t.address).fontWeight(.semibold)
                        if let p = t.ptr { Text(p).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        if t.ports.isEmpty { ProgressView().controlSize(.small) }
                        ForEach(t.ports.sorted { $0.key > $1.key }, id: \.key) { port, v in
                            Pill(text: v >= 0 ? "\(port) open · \(v) ms" : "\(port) closed", color: v >= 0 ? okColor : Theme.heat(100))
                        }
                        if let p = t.pingMs {
                            Pill(text: String(format: "ping %.0f ms", p), color: msColor(p))
                        } else if t.loss == 100 {
                            Pill(text: "no ping reply", color: .secondary)
                        }
                    }
                    Text(owner(t.address)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func owner(_ ip: String) -> String {
        if let o = result.owners[ip] { return "Run by \(o.name ?? "AS\(o.asn)") (AS\(o.asn), \(o.prefix), \(o.country))" }
        return DNSMap.isPrivate(ip) ? "Internal address: on this network or behind the VPN" : "Looking up who runs it…"
    }
}

private struct TunnelCard: View {
    let result: DNSMapResult
    var body: some View {
        Card(title: "Tunnels on this Mac", symbol: "lock.shield", tint: mapTint) {
            Text("Security and VPN apps that carry some traffic in a tunnel. Routers inside a tunnel cannot be traced from here; the tunnel itself can, to the provider's server.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(result.tunnels, id: \.vendor) { t in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(t.vendor).font(.callout.weight(.semibold))
                        Text(t.process).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    ForEach(t.edges, id: \.self) { e in
                        let route = result.routes.first { $0.address == e }
                        HStack(spacing: 8) {
                            Mono(text: e)
                            Text(result.owners[e].map { "\($0.label), \($0.country)" } ?? "").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let r = route, r.done, let last = r.shown.hops.last?.ms {
                                Text("\(r.shown.hops.count) hops, \(Int(last)) ms").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let z = result.zscaler {
                Label(z.throughProxy
                      ? "Web traffic goes through Zscaler's proxy\(z.proxyHost.map { " \($0)" } ?? "")\(z.proxyIP.map { " (\($0))" } ?? ""). Sites see Zscaler's address\(z.publicIP.map { ", \($0)" } ?? "")."
                      : "Web traffic goes straight out, not through Zscaler's proxy. Sites see \(z.publicIP ?? "this network's address"). Zscaler carries only internal names.",
                      systemImage: z.throughProxy ? "arrow.triangle.branch" : "arrow.up.right")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("From ip.zscaler.com").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RoutesCard: View {
    let result: DNSMapResult
    var body: some View {
        Card(title: "Routes", symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: mapTint) {
            Text("Each router on the way, how long it took to reply, and who runs it. Silent hops are routers that do not answer traces, which is normal; the trace stops counting after the last reply.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(result.routes.enumerated()), id: \.offset) { i, r in
                RouteView(route: r, owners: result.owners, expanded: i < result.targets.count && r.tunnel == nil)
            }
        }
    }
}

private struct RouteView: View {
    let route: DNSMapResult.Route
    let owners: [String: NetOwner]
    @State var expanded: Bool

    var body: some View {
        let shown = route.shown
        let maxMs = max(shown.hops.compactMap(\.ms).max() ?? 1, 1)
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                if let t = route.tunnel {
                    Text(route.onThisMac
                         ? "This address is the \(t) app itself, on this Mac (\(route.interface ?? "its tunnel")). It answers here and forwards through its tunnel, so there is no route to trace. The tunnel's own route is under \"\(t) tunnel server\"."
                         : "Traffic to this address leaves by \(route.interface ?? "a tunnel") into the \(t) tunnel, which hides the routers inside it. The tunnel's own route is under \"\(t) tunnel server\".")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(shown.hops, id: \.n) { h in
                    HStack(spacing: 8) {
                        Text("\(h.n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                        Text(h.address ?? "*").font(.caption.monospaced()).frame(width: 150, alignment: .leading).textSelection(.enabled)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 2).fill(msColor(h.ms).opacity(0.7))
                                .frame(width: max(2, g.size.width * CGFloat((h.ms ?? 0) / maxMs)), height: 6)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(width: 120, height: 12)
                        Text(h.ms.map { String(format: "%.1f ms", $0) } ?? "no reply").font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                        Text(hopOwner(h)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if shown.silent > 0 {
                    Text(route.reached ? "" : "Then \(shown.silent) silent hops: the far end or a firewall does not answer traces.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6).padding(.top, 4)
        } label: {
            HStack {
                Text(route.label).font(.callout.weight(.semibold)).lineLimit(1)
                Mono(text: route.address).foregroundStyle(.secondary)
                Spacer()
                if !route.done { Waiting(text: "tracing") }
                else if let t = route.tunnel {
                    Pill(text: route.onThisMac ? "\(t) app on this Mac" : "inside the \(t) tunnel", color: mapTint)
                } else {
                    Text(shown.hops.isEmpty ? "no replies: a VPN tunnel or firewall hides the route" :
                            "\(shown.hops.count) hops" + (route.reached ? ", reached" : ", then silent")
                         + (shown.hops.last?.ms.map { String(format: ", %.0f ms", $0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func hopOwner(_ h: Hop) -> String {
        guard let a = h.address else { return "" }
        if let o = owners[a] { return "\(o.label) · \(o.country)" }
        return DNSMap.isPrivate(a) ? "internal" : ""
    }
}

private struct CertCard: View {
    let cert: DNSMapResult.Certificate
    let host: String
    var body: some View {
        Card(title: "HTTPS certificate", symbol: "lock", tint: mapTint) {
            if let e = cert.error { Label(e, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(Theme.heat(100)) }
            row("Issued to", cert.leaf)
            row("Issued by", cert.issuer)
            row("Root", cert.root.map { $0 + (cert.rootIsSystem ? " (built into macOS)" : " (NOT built into macOS: inspected)") })
            row("Expires", cert.expires.map { $0.formatted(date: .abbreviated, time: .omitted) + " (\(Int($0.timeIntervalSinceNow / 86400)) days)" })
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String?) -> some View {
        if let v {
            HStack(alignment: .firstTextBaseline) {
                Text(k).font(.callout).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                Text(v).font(.callout).textSelection(.enabled)
            }
        }
    }
}

private struct CommandsCard: View {
    let result: DNSMapResult
    @State private var open = false
    var body: some View {
        Card(title: "Every check run (\(result.commands.count))", symbol: "terminal", tint: mapTint) {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(result.commands.enumerated()), id: \.offset) { _, c in
                        CommandRow(command: c)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("The exact commands and their full output, in the order they finished").font(.callout)
            }
        }
    }
}

private struct CommandRow: View {
    let command: DNSMapResult.Command
    @State private var open = false
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(command.output.isEmpty ? "(no output)" : command.output)
                .font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        } label: {
            HStack {
                Text(command.command).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                Spacer()
                Text("\(command.ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
