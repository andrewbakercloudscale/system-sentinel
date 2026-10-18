import Charts
import SentinelCore
import SwiftUI

/// Network: is the connection good, what is wrong with it, and who is using it, down to
/// which app talks to which host and which connections keep failing.
struct NetworkView: View {
    @ObservedObject var model: Model
    @ObservedObject var store: NetworkStore

    var body: some View {
        VStack(spacing: 10) {
            NetworkHero(store: store)
            if !store.insights.isEmpty {
                InsightList(model: model, only: store.insights, title: "Network issues")
            }
            ThroughputChart(store: store)
            HStack(alignment: .top, spacing: 10) {
                LinkCard(store: store)
                QualityCard(store: store)
            }
            TopApps(model: model, store: store)
            TopHosts(store: store)
            ProblemsCard(model: model, store: store)
        }
    }
}

private let netTint = Tab.network.color

private func bytes(_ b: UInt64) -> String { ReportDocument.bytes(b) }

// MARK: Hero

private struct NetworkHero: View {
    @ObservedObject var store: NetworkStore

    var body: some View {
        let now = store.throughput.latest
        let tone = store.insights.map(\.tone).max() ?? .good
        HStack(spacing: 16) {
            Image(systemName: store.link.wifi != nil ? "wifi" : (store.link.interface == nil ? "wifi.slash" : "network"))
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white).frame(width: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict(tone)).font(.title3.weight(.bold)).foregroundStyle(.white)
                Text(summary).font(.callout).foregroundStyle(.white.opacity(0.92)).lineLimit(2)
            }
            Spacer()
            HStack(spacing: 14) {
                speed("arrow.down", now?.down)
                speed("arrow.up", now?.up)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: colors(tone), startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func speed(_ symbol: String, _ v: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Label(v.map(IORow.rate) ?? "–", systemImage: symbol)
                .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit()
            Text(symbol == "arrow.down" ? "download" : "upload").font(.caption).foregroundStyle(.white.opacity(0.85))
        }
    }

    private var summary: String {
        let l = store.link
        var parts = [l.kind]
        if let w = l.wifi { parts.append("\(w.quality.label.lowercased()) signal"); if let b = w.band { parts.append("\(b == 2.4 ? "2.4" : String(Int(b))) GHz") } }
        if let v = l.vpn { parts.append("via \(v)") }
        parts.append("\(store.openCount) connections")
        return parts.joined(separator: " · ")
    }

    private func verdict(_ t: Insight.Tone) -> String {
        if store.link.interface == nil { return "Offline" }
        switch t {
        case .critical: return "Connection problem"
        case .warning: return "Connection is struggling"
        default: return "Connection is healthy"
        }
    }

    private func colors(_ t: Insight.Tone) -> [Color] {
        switch t {
        case .critical: return [Color(hex: "#dc2626"), Color(hex: "#9f1239")]
        case .warning: return [Color(hex: "#d97706"), Color(hex: "#b45309")]
        default: return [Color(hex: "#0284c7"), Color(hex: "#075985")]
        }
    }
}

// MARK: Speed over time

private struct ThroughputChart: View {
    @ObservedObject var store: NetworkStore

    var body: some View {
        let pts = store.throughput.points
        let since = Date().addingTimeInterval(-3600)
        let peak = store.throughput.peak(since: since)
        Card(title: "Speed, last hour", symbol: "chart.xyaxis.line", tint: netTint,
             trailing: AnyView(Text(peak.map { "peak ↓ \(IORow.rate($0.down))  ↑ \(IORow.rate($0.up))" } ?? "").font(.caption).foregroundStyle(.secondary))) {
            if pts.count < 3 {
                Text("Measuring. The chart fills in over the next minutes.").font(.caption).foregroundStyle(.secondary).frame(height: 110)
            } else {
                Chart {
                    ForEach(pts, id: \.at) { p in
                        AreaMark(x: .value("Time", p.at), y: .value("MB/s", p.down / 1_000_000), series: .value("Way", "Download"))
                            .foregroundStyle(netTint.opacity(0.35)).interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.at), y: .value("MB/s", p.down / 1_000_000), series: .value("Way", "Download"))
                            .foregroundStyle(netTint).interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.at), y: .value("MB/s", p.up / 1_000_000), series: .value("Way", "Upload"))
                            .foregroundStyle(Color(hex: "#d97706")).interpolationMethod(.monotone)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(d < 1 ? String(format: "%.1f MB/s", d) : "\(Int(d)) MB/s").font(.system(size: 9)) } }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9)) } }
                .frame(height: 110)
                HStack(spacing: 14) {
                    Label("Download", systemImage: "circle.fill").foregroundStyle(netTint)
                    Label("Upload", systemImage: "circle.fill").foregroundStyle(Color(hex: "#d97706"))
                    Spacer()
                    Text("Wi-Fi and Ethernet, every 3 s").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

// MARK: The link

private struct LinkCard: View {
    @ObservedObject var store: NetworkStore

    var body: some View {
        let l = store.link
        Card(title: "Connection", symbol: "point.3.connected.trianglepath.dotted", tint: netTint, fill: true) {
            if let w = l.wifi {
                HStack(spacing: 10) {
                    SignalBars(quality: w.quality)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(w.quality.label) Wi-Fi\(w.ssid.map { ": \($0)" } ?? "")").font(.callout.weight(.semibold))
                        Text("Signal \(w.rssi) dBm · noise \(w.noise) dBm · \(w.snr) dB clear").font(.caption).foregroundStyle(.secondary)
                    }
                }
                row("Link speed", "\(Int(w.txRate)) Mbit/s")
                if let c = w.channel { row("Channel", "\(c)\(w.band.map { " · \($0 == 2.4 ? "2.4" : String(Int($0))) GHz" } ?? "")\(w.width.map { " · \($0) MHz wide" } ?? "")") }
            }
            row("Type", l.kind + (l.interface.map { " (\($0))" } ?? ""))
            row("This Mac", l.address ?? "–")
            row("Router", l.gateway ?? "–")
            row("DNS", l.dns.isEmpty ? "–" : l.dns.prefix(3).joined(separator: ", "))
            row("VPN or proxy", l.vpn ?? "none seen")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(v).font(.caption.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct SignalBars: View {
    let quality: WiFiInfo.Quality
    var body: some View {
        let color: Color = quality >= .good ? Tab.battery.color : (quality == .fair ? Color(hex: "#d97706") : Theme.heat(100))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1.5).fill(i <= quality.rawValue ? color : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: CGFloat(6 + i * 5))
            }
        }
        .frame(width: 26, height: 22, alignment: .bottom)
    }
}

private struct QualityCard: View {
    @ObservedObject var store: NetworkStore

    var body: some View {
        let h = store.health
        Card(title: "Quality", symbol: "waveform.path.ecg", tint: netTint,
             trailing: AnyView(Group {
                 if store.testing { BusyButton(title: "Testing…") }
                 else { RowButton(title: "Test now", symbol: "arrow.clockwise", color: netTint) { store.test(full: true) } }
             }), fill: true) {
            if let h {
                metric("To the router", ms: h.routerMs, loss: h.routerLoss, good: 10, bad: 50,
                       hint: "Inside your home or office: Wi-Fi or cable.")
                metric("To the internet", ms: h.internetMs, loss: h.internetLoss, good: 40, bad: 150,
                       hint: "All the way out, through the provider\(store.link.vpn.map { " and \($0)" } ?? "").")
                HStack {
                    dot(h.dnsOK ? ((h.dnsMs ?? 0) < 100 ? .good : ((h.dnsMs ?? 0) < 300 ? .fair : .poor)) : .poor)
                    Text("Name lookup").font(.callout.weight(.semibold))
                    Spacer()
                    Text(h.dnsOK ? "\(Int(h.dnsMs ?? 0)) ms" : "failing").font(.callout.weight(.bold)).monospacedDigit()
                }
                if let i = h.interfaceMTU {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            dot(h.pathMTU == nil ? .fair : (h.fragments ? ((h.pathMTU ?? 0) < 1400 ? .poor : .fair) : .good))
                            Text("Largest packet").font(.callout.weight(.semibold))
                            Spacer()
                            Text(h.pathMTU.map { "\(String($0)) of \(String(i)) bytes" } ?? "not measured").font(.callout.weight(.bold)).monospacedDigit()
                        }
                        Text(h.pathMTU == nil ? "Pings marked do-not-split got no answer at any size."
                             : h.fragments ? "Bigger packets get split or dropped on the way: big transfers can stall."
                             : "Full-size packets cross whole: no fragmentation.")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                    }
                }
                Text("Tested \(RelativeDateTimeFormatter().localizedString(for: h.at, relativeTo: Date())); again every 3 minutes (packet size every 30).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Testing latency and loss…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, ms: Double?, loss: Double?, good: Double, bad: Double, hint: String) -> some View {
        let q: WiFiInfo.Quality = {
            guard let ms, let loss else { return .poor }
            if loss >= 5 || ms >= bad { return .poor }
            if loss > 0 || ms >= good { return .fair }
            return .good
        }()
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                dot(q)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Text(ms.map { "\(Int($0.rounded())) ms" } ?? "no answer").font(.callout.weight(.bold)).monospacedDigit()
                Text(loss.map { "\(Int($0))% loss" } ?? "").font(.caption).foregroundStyle((loss ?? 0) > 0 ? Theme.heat(100) : .secondary)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
        }
    }

    private func dot(_ q: WiFiInfo.Quality) -> some View {
        Circle().fill(q >= .good ? Tab.battery.color : (q == .fair ? Color(hex: "#d97706") : Theme.heat(100))).frame(width: 9, height: 9)
    }
}

// MARK: Who is using it

private struct TopApps: View {
    @ObservedObject var model: Model
    @ObservedObject var store: NetworkStore
    @AppStorage("networkSort") private var sort = "Now"
    @State private var open: String?
    @State private var showAll = false
    static let sorts = ["Now", "Received", "Sent", "Connections"]

    var body: some View {
        let rows = store.apps.sorted { a, b in
            switch sort {
            case "Received": return a.totalIn > b.totalIn
            case "Sent": return a.totalOut > b.totalOut
            case "Connections": return a.connections > b.connections
            default: return a.down + a.up > b.down + b.up || (a.down + a.up == b.down + b.up && a.totalIn + a.totalOut > b.totalIn + b.totalOut)
            }
        }
        Card(title: "Top talkers", symbol: "person.2.wave.2.fill", tint: netTint,
             trailing: AnyView(Text("\(rows.count) apps").font(.caption).foregroundStyle(.secondary))) {
            ChipPicker(options: Self.sorts, selection: $sort, color: netTint)
            HStack {
                Text("APP").frame(maxWidth: .infinity, alignment: .leading)
                Text("NOW ↓").frame(width: 70, alignment: .trailing)
                Text("NOW ↑").frame(width: 70, alignment: .trailing)
                Text("RECEIVED").frame(width: 76, alignment: .trailing)
                Text("SENT").frame(width: 70, alignment: .trailing)
                Text("CONN.").frame(width: 46, alignment: .trailing)
            }
            .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            ForEach(rows.prefix(showAll ? 60 : 12), id: \.key) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Button { open = open == r.key ? nil : r.key } label: { row(r) }.buttonStyle(.plain)
                    if open == r.key { detail(r) }
                }
            }
            if rows.count > 12 {
                Button(showAll ? "Show fewer" : "Show all \(rows.count)") { showAll.toggle() }.buttonStyle(.link).font(.caption)
            }
            Text("Received and sent count from when each process started, like Activity Monitor; now is the last 10 seconds. Click an app for the hosts it talks to.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ r: NetworkAnalysis.AppRow) -> some View {
        let sample = r.pids.compactMap(model.sample(pid:)).first
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let s = sample { IconView(icon: IconCache.shared.icon(for: s), size: 18) }
                else { Image(systemName: "gearshape").frame(width: 18).foregroundStyle(.secondary) }
                Text(r.name).font(.callout).lineLimit(1)
                Image(systemName: open == r.key ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(IORow.rate(r.down)).frame(width: 70, alignment: .trailing)
            Text(IORow.rate(r.up)).frame(width: 70, alignment: .trailing)
                .foregroundStyle(r.up >= 1_000_000 ? Color(hex: "#d97706") : .primary)
            Text(bytes(r.totalIn)).frame(width: 76, alignment: .trailing)
            Text(bytes(r.totalOut)).frame(width: 70, alignment: .trailing)
            Text("\(r.connections)").frame(width: 46, alignment: .trailing)
        }
        .font(.caption.weight(.medium)).monospacedDigit()
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func detail(_ r: NetworkAnalysis.AppRow) -> some View {
        let pids = Set(r.pids)
        let hosts = store.flows.filter { pids.contains($0.pid) }.prefix(8)
        let conns = store.tracker.open.filter { pids.contains($0.pid) }
        VStack(alignment: .leading, spacing: 3) {
            if hosts.isEmpty {
                Text("\(conns.count) open connection\(conns.count == 1 ? "" : "s"), no data moved in the last hour.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(hosts), id: \.host) { f in
                HStack {
                    Text(store.label(f.host)).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Text("↓ \(bytes(f.rx))  ↑ \(bytes(f.tx))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let s = r.pids.compactMap(model.sample(pid:)).first, s.pid != getpid(), Safety.canKillManually(s) {
                FixButtons(model: model, fixes: [.quit(pids: r.pids, name: r.name)])
            }
        }
        .padding(8).padding(.leading, 18)
        .background(RoundedRectangle(cornerRadius: 8).fill(netTint.opacity(0.06)))
    }
}

private struct TopHosts: View {
    @ObservedObject var store: NetworkStore

    var body: some View {
        var acc: [String: (rx: UInt64, tx: UInt64, apps: Set<String>)] = [:]
        for f in store.flows {
            var a = acc[f.host] ?? (0, 0, [])
            a.rx += f.rx; a.tx += f.tx
            a.apps.insert(store.appName(pid: f.pid, fallback: f.process))
            acc[f.host] = a
        }
        let rows = acc.sorted { $0.value.rx + $0.value.tx > $1.value.rx + $1.value.tx }.prefix(10)
        return Card(title: "Where the data goes, last hour", symbol: "globe", tint: netTint) {
            if rows.isEmpty { Text("Measuring…").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(rows), id: \.key) { host, v in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.label(host)).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text(v.apps.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("↓ \(bytes(v.rx))").frame(width: 80, alignment: .trailing)
                    Text("↑ \(bytes(v.tx))").frame(width: 80, alignment: .trailing)
                }
                .font(.caption.weight(.medium)).monospacedDigit()
            }
            Text("Counted from each connection's own byte counters, so traffic through a VPN shows its real destination where the VPN keeps it visible.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Failing connections

private struct ProblemsCard: View {
    @ObservedObject var model: Model
    @ObservedObject var store: NetworkStore

    var body: some View {
        let list = store.problems
        Card(title: "Connections that failed, last hour", symbol: "exclamationmark.arrow.triangle.2.circlepath", tint: netTint,
             trailing: AnyView(Text(list.isEmpty ? "none" : "\(list.reduce(0) { $0 + $1.count }) in \(list.count) places")
                .font(.caption.weight(.semibold)).foregroundStyle(list.isEmpty ? Tab.battery.color : Color(hex: "#d97706")))) {
            if list.isEmpty {
                Text("No secure connection has dropped within seconds and nothing has gone unanswered. Checked every 3 seconds.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list.prefix(12)) { p in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: p.kind == .shortTLS ? "lock.slash.fill" : "network.slash")
                        .foregroundStyle(p.count >= 8 ? Color(hex: "#d97706") : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(p.process) → \(p.host):\(p.port)").font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text(p.kind == .shortTLS ? "Secure connection dropped within seconds, almost nothing received" : "Tried to connect, no answer")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("×\(p.count)").font(.callout.weight(.bold)).monospacedDigit()
                    Text(RelativeDateTimeFormatter().localizedString(for: p.last, relativeTo: Date())).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
            Text("A secure (TLS) connection that closes before any data arrives usually means a refused handshake: an untrusted certificate (often a VPN or proxy inspecting traffic), a blocked address, a wrong clock, or a server turning the app away. One or two are normal; dozens to the same place are not.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
