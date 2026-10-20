import AppKit
import Charts
import SentinelCore
import SwiftUI

/// An mtr-style route test: trace the route once, then ping every hop once a second, so loss
/// and delay at each step build up over a minute, or up to an hour to catch trouble that comes
/// and goes. Done with macOS's own `traceroute` and
/// `ping`, because real mtr needs root.
@MainActor
final class MTRStore: ObservableObject {
    static let shared = MTRStore()

    @Published var input = "1.1.1.1"
    @Published private(set) var target = ""
    @Published private(set) var address: String?
    @Published private(set) var hops: [MTRHop] = []
    @Published private(set) var owners: [String: NetOwner] = [:]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rounds = 0
    @Published private(set) var started: Date?
    /// Set when the route leaves through a VPN or Zscaler tunnel, whose inside a trace cannot see.
    @Published private(set) var tunnel: String?
    /// The target's answer each round, for the over-time chart and the minute-by-minute windows.
    @Published private(set) var samples: [MTRSample] = []
    @AppStorage("mtrDuration") var duration = "1 min"
    /// Rounds the running test will do, fixed when it starts.
    @Published private(set) var planned = 60

    enum Phase: Equatable { case idle, resolving, tracing, pinging, failed(String) }

    static let durations = ["1 min", "5 min", "15 min", "1 hour"]
    static func seconds(_ d: String) -> Int {
        switch d { case "5 min": 300; case "15 min": 900; case "1 hour": 3600; default: 60 }
    }
    private var generation = 0

    var running: Bool { phase == .resolving || phase == .tracing || phase == .pinging }

    var verdict: MTR.Verdict? { MTR.verdict(hops, isPrivate: DNSMap.isPrivate) }
    var windows: [MTRWindow] { MTR.windows(samples) }
    var timeline: MTR.Verdict? { MTR.timeline(windows) }

    func start() {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        generation += 1
        let gen = generation
        target = name
        address = nil
        hops = []
        rounds = 0
        samples = []
        planned = Self.seconds(duration)
        tunnel = nil
        started = Date()
        phase = .resolving
        let rounds = planned
        Task.detached(priority: .utility) { await self.run(name, rounds: rounds, gen: gen) }
    }

    func stop() {
        generation += 1
        if running { phase = .idle }
    }

    var reportText: String {
        MTR.report(target: target, address: address, hops: hops, owners: owners, at: started ?? Date())
            + (verdict.map { "\n\($0.title). \($0.detail)\n" } ?? "")
            + MTR.timelineReport(windows)
            + (timeline.map { "\n\($0.title). \($0.detail)\n" } ?? "")
    }

    private func current(_ gen: Int) -> Bool { gen == generation }

    private nonisolated func run(_ name: String, rounds total: Int, gen: Int) async {
        let ip = DNSMap.isIP(name) ? name : NetworkStore.resolve(name).addresses.first { !$0.contains(":") } ?? NetworkStore.resolve(name).addresses.first
        guard let ip else {
            await MainActor.run { if self.current(gen) { self.phase = .failed("Could not look up \(name).") } }
            return
        }
        let six = ip.contains(":")
        let via = NetParse.routeGet(sh("/sbin/route", ["-n", "get", six ? "-inet6" : "-inet", ip], timeout: 4))
        let tunnelled = DNSMap.isTunnelInterface(via.interface)
        await MainActor.run {
            guard self.current(gen) else { return }
            self.address = ip
            self.tunnel = tunnelled ? via.interface : nil
            self.phase = .tracing
        }

        let trace = NetParse.traceroute(sh(six ? "/usr/sbin/traceroute6" : "/usr/sbin/traceroute", ["-n", "-w", "1", "-q", "1", "-m", "30", ip], timeout: 60))
        var traced = MTR.hops(from: trace)
        if traced.last?.address != ip { traced.append(MTRHop(n: (traced.last?.n ?? 0) + 1, address: ip)) }
        let hops = traced
        await MainActor.run {
            guard self.current(gen) else { return }
            self.hops = hops
            self.phase = .pinging
        }
        Task.detached(priority: .utility) { await self.lookUpOwners(hops.compactMap(\.address), gen: gen) }

        let end = hops.last?.n
        for _ in 0..<total {
            let t0 = Date()
            guard await MainActor.run(body: { self.current(gen) }) else { return }
            let results: [Int: Double?] = await withTaskGroup(of: (Int, Double?).self) { g in
                for h in hops {
                    guard let a = h.address else { continue }
                    g.addTask {
                        let out = six ? sh("/sbin/ping6", ["-n", "-c", "1", a], timeout: 2)
                                      : sh("/sbin/ping", ["-n", "-c", "1", "-W", "1000", a], timeout: 2)
                        return (h.n, MTR.pingMS(out))
                    }
                }
                var r: [Int: Double?] = [:]
                for await (n, ms) in g { r[n] = ms }
                return r
            }
            await MainActor.run {
                guard self.current(gen) else { return }
                for i in self.hops.indices { if let r = results[self.hops[i].n] { self.hops[i].record(r) } }
                if let end, let r = results[end] { self.samples.append(MTRSample(at: t0, ms: r)) }
                self.rounds += 1
            }
            let wait = 1 - Date().timeIntervalSince(t0)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        await MainActor.run { if self.current(gen) { self.phase = .idle } }
    }

    private nonisolated func lookUpOwners(_ ips: [String], gen: Int) async {
        let todo = Array(Set(ips.filter { !DNSMap.isPrivate($0) }))
        let found: [(String, NetOwner)] = await withTaskGroup(of: (String, NetOwner)?.self) { g in
            for ip in todo {
                g.addTask {
                    guard let q = DNSMap.cymruQuery(ip),
                          var o = NetParse.cymruOrigin(sh("/usr/bin/dig", [q, "TXT", "+short", "+time=2", "+tries=1"], timeout: 5)) else { return nil }
                    o.name = await DNSMapStore.asName(o.asn)
                    return (ip, o)
                }
            }
            var out: [(String, NetOwner)] = []
            for await x in g { if let x { out.append(x) } }
            return out
        }
        await MainActor.run {
            guard self.current(gen) else { return }
            for (ip, o) in found { self.owners[ip] = o }
        }
    }
}

/// The route test on the Network tab.
struct MTRCard: View {
    @ObservedObject var store = MTRStore.shared
    @State private var copied = false
    private let tint = Tab.network.color

    var body: some View {
        Card(title: "Route test (mtr)", symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", tint: tint,
             trailing: AnyView(trailing)) {
            HStack(spacing: 8) {
                TextField("Name or address, e.g. 1.1.1.1 or zoom.us", text: $store.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !store.running { store.start() } }
                    .disabled(store.running)
                ForEach(["1.1.1.1", "8.8.8.8", "apple.com"], id: \.self) { t in
                    Button(t) { store.input = t; store.start() }
                        .buttonStyle(.bordered).tint(tint).disabled(store.running)
                }
            }
            HStack(spacing: 8) {
                Text("Run for").font(.callout).foregroundStyle(.secondary)
                ChipPicker(options: MTRStore.durations, selection: $store.duration, color: tint)
                    .disabled(store.running)
                    .tip("Longer tests catch loss and jitter that come and go, and show when it happened")
                Spacer()
            }
            if store.hops.isEmpty {
                Text(intro).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if let v = store.verdict { verdict(v) }
                table
                if store.samples.count >= 2 { overTime }
            }
            if let t = store.tunnel {
                Text("This route leaves through a tunnel (\(t)), such as Zscaler or a VPN. The hops inside it are hidden, so the trace shows little; the last row still measures the whole way to the target.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let why) = store.phase {
                Text(why).font(.callout).foregroundStyle(Theme.heat(100))
            }
        }
    }

    private var intro: String {
        "Traces the route to a server, then pings every hop once a second, for a minute or up to an hour: loss, delay and jitter at each step, like mtr, and a chart of when it happened. Loss that starts at one hop and carries on to the end is where the problem is."
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if !store.hops.isEmpty {
                RowButton(title: copied ? "Copied" : "Copy report", symbol: copied ? "checkmark" : "doc.on.doc", color: Tab.trends.color) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.reportText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .tip("Copy the table as text, for your provider or IT")
            }
            if store.running {
                RowButton(title: status, symbol: "stop.fill", color: Theme.heat(100)) { store.stop() }
                    .tip("Stop the test")
            } else {
                RowButton(title: store.hops.isEmpty ? "Run" : "Run again", symbol: "play.fill", color: tint, filled: true) { store.start() }
                    .tip("Trace the route, then ping each hop once a second for \(store.duration == "1 hour" ? "an hour" : store.duration)")
            }
        }
    }

    private var status: String {
        switch store.phase {
        case .resolving: return "Looking up…"
        case .tracing: return "Tracing…"
        case .pinging: return "Stop  \(clock(store.rounds)) / \(clock(store.planned))"
        default: return "Stop"
        }
    }

    private func clock(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The target's delay each second, with lost pings as red ticks along the top, so a burst
    /// of trouble shows where it happened in a long test.
    @ViewBuilder
    private var overTime: some View {
        let pts = store.samples
        let top = max(10, (pts.compactMap(\.ms).max() ?? 10) * 1.1)
        let lost = pts.filter { $0.ms == nil }.count
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("To \(store.target), over time").font(.callout.weight(.semibold))
                Spacer()
                Text(lost == 0 ? "No pings lost" : "\(lost) of \(pts.count) pings lost")
                    .font(.callout).foregroundStyle(lost == 0 ? Theme.heat(0) : Theme.heat(100))
            }
            Chart {
                ForEach(pts, id: \.at) { p in
                    if let ms = p.ms {
                        LineMark(x: .value("Time", p.at), y: .value("ms", ms))
                            .foregroundStyle(tint).interpolationMethod(.monotone)
                    } else {
                        RuleMark(x: .value("Time", p.at), yStart: .value("ms", top * 0.85), yEnd: .value("ms", top))
                            .foregroundStyle(Theme.heat(100)).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) ms").font(.caption) } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.caption) } }
            .frame(height: 110)
            HStack(spacing: 14) {
                Label("Delay to the target", systemImage: "circle.fill").foregroundStyle(tint)
                Label("Lost ping", systemImage: "circle.fill").foregroundStyle(Theme.heat(100))
                Spacer()
            }
            .font(.callout)
            if let t = store.timeline { verdict(t) }
        }
    }

    private func verdict(_ v: MTR.Verdict) -> some View {
        let color: Color = switch v.tone {
        case .good: Theme.heat(0)
        case .info: tint
        case .warning: Color(hex: "#d97706")
        case .bad: Theme.heat(100)
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: v.tone == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.title).font(.callout.weight(.semibold))
                Text(v.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                Text("#").gridColumnAlignment(.trailing)
                Text("Host").gridColumnAlignment(.leading)
                Text("Loss"); Text("Sent"); Text("Last"); Text("Avg"); Text("Best"); Text("Worst"); Text("Jitter")
            }
            .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(store.hops) { h in
                GridRow {
                    Text("\(h.n)").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(h.address ?? "no answer").font(.callout.monospaced())
                            .foregroundStyle(h.address == nil ? .secondary : .primary)
                        if let a = h.address {
                            Text(store.owners[a]?.label ?? (DNSMap.isPrivate(a) ? "Your network" : ""))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(h.sent == 0 ? "-" : String(format: "%.0f%%", h.loss))
                        .fontWeight(.semibold).foregroundStyle(lossColor(h))
                    Text(h.address == nil ? "-" : "\(h.sent)").foregroundStyle(.secondary)
                    ms(h.last); ms(h.average).fontWeight(.semibold); ms(h.best); ms(h.worst); ms(h.jitter)
                }
                .font(.callout).monospacedDigit()
            }
        }
    }

    private func ms(_ v: Double?) -> Text {
        Text(v.map { $0 < 10 ? String(format: "%.1f", $0) : String(format: "%.0f", $0) } ?? "-")
    }

    private func lossColor(_ h: MTRHop) -> Color {
        guard h.sent > 0 else { return .secondary }
        return h.loss == 0 ? Theme.heat(0) : h.loss < 10 ? Color(hex: "#d97706") : Theme.heat(100)
    }
}
