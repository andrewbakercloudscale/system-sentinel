import AppKit
import Charts
import SentinelCore
import SwiftUI

/// The first screen: how busy the Mac is, who is responsible, and what it means.
struct OverviewView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 10) {
            Hero(model: model)
            HStack(alignment: .top, spacing: 10) {
                NowDonut(model: model).frame(width: 290)
                LastHourChart(model: model)
            }
            InsightList(model: model)
        }
    }
}

/// The big number, on the gradient.
private struct Hero: View {
    @ObservedObject var model: Model

    var body: some View {
        let load = model.machineLoad
        let busyCores = model.totalCPU / 100
        HStack(alignment: .center, spacing: 16) {
            Gauge(value: min(load, 100), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(load))%").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Gradient(colors: [.green, .yellow, .orange, .red]))
            .scaleEffect(1.35)
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 4) {
                Text(headline(load)).font(.title3.weight(.bold)).foregroundStyle(.white)
                Text(String(format: "%.1f of %d cores busy", busyCores, Int(model.cores)))
                    .font(.callout).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 6) {
                    ThermalChip(state: model.thermal)
                    if ProcessInfo.processInfo.isLowPowerModeEnabled {
                        HeroChip(text: "Low Power", symbol: "leaf.fill")
                    }
                    if !model.flagged.isEmpty {
                        HeroChip(text: "\(model.flagged.count) flagged", symbol: "exclamationmark.triangle.fill")
                    }
                }
            }
            Spacer()
            HStack(spacing: 14) {
                Stat(label: "1 min", value: model.machineAverage(60))
                Stat(label: "15 min", value: model.machineAverage(900))
                Stat(label: "1 hour", value: model.machineAverage(3600))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.heroGradient))
        .overlay(alignment: .bottomTrailing) {
            if model.recordedMinutes < 60 {
                Text("\(Int(model.recordedMinutes)) min recorded so far")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).padding(6)
            }
        }
    }

    private func headline(_ load: Double) -> String {
        load < 15 ? "Running cool" : load < 40 ? "Moderately busy" : load < 70 ? "Working hard" : "Flat out"
    }

    private struct Stat: View {
        let label: String
        let value: Double
        var body: some View {
            VStack(spacing: 2) {
                Text("\(Int(value.rounded()))%").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(label).font(.caption2).foregroundStyle(.white.opacity(0.75))
            }
            .frame(minWidth: 44)
            .padding(.vertical, 6).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
            .help("Average share of the whole Mac over the last \(label)")
        }
    }
}

private struct HeroChip: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.18)))
    }
}

private struct ThermalChip: View {
    let state: ProcessInfo.ThermalState
    var body: some View {
        switch state {
        case .nominal: HeroChip(text: "Cool", symbol: "thermometer.low")
        case .fair: HeroChip(text: "Warm", symbol: "thermometer.medium")
        case .serious: HeroChip(text: "Hot, throttling", symbol: "thermometer.high")
        case .critical: HeroChip(text: "Overheating", symbol: "thermometer.sun.fill")
        @unknown default: EmptyView()
        }
    }
}

/// Who is using the CPU right now, by app, as a share of what is in use.
private struct NowDonut: View {
    @ObservedObject var model: Model

    struct Slice: Identifiable {
        let key: String
        let name: String
        let cpu: Double
        var id: String { key }
    }

    var body: some View {
        let slices = Self.slices(model.sentinel.latest)
        let colors = ColorBook.shared.colors(for: slices.map(\.key).filter { $0 != "other" })
        let total = slices.reduce(0) { $0 + $1.cpu }
        Card(title: "Right now", symbol: "chart.pie.fill", tint: Tab.overview.color) {
            HStack(alignment: .center, spacing: 10) {
                Chart(slices) { s in
                    SectorMark(angle: .value("CPU", s.cpu), innerRadius: .ratio(0.62), angularInset: 1.2)
                        .cornerRadius(3)
                        .foregroundStyle(colors[s.key] ?? Theme.other)
                }
                .chartLegend(.hidden)
                .frame(width: 92, height: 92)
                .overlay {
                    VStack(spacing: 0) {
                        Text(String(format: "%.1f", total / 100)).font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("cores").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(slices) { s in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(colors[s.key] ?? Theme.other).frame(width: 8, height: 8)
                            Text(s.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text(Fmt.pct(total > 0 ? s.cpu / total * 100 : 0)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.caption2)
                    }
                }
            }
        }
    }

    static func slices(_ samples: [ProcessSample]) -> [Slice] {
        var byApp: [String: Double] = [:]
        for s in samples where s.cpu > 0 { byApp[Model.appKey(s.path), default: 0] += s.cpu }
        let sorted = byApp.sorted { $0.value > $1.value }
        var out = sorted.prefix(5).map { Slice(key: $0.key, name: Model.appName($0.key), cpu: $0.value) }
        let rest = sorted.dropFirst(5).reduce(0) { $0 + $1.value }
        if rest > 0 { out.append(Slice(key: "other", name: "Everything else", cpu: rest)) }
        return out
    }
}

/// The last hour, stacked by the apps that used most of it.
private struct LastHourChart: View {
    @ObservedObject var model: Model

    struct Point: Identifiable {
        let time: Date
        let key: String
        let name: String
        let value: Double
        var id: String { "\(key)@\(time.timeIntervalSince1970)" }
    }

    var body: some View {
        let now = Date()
        let buckets = 60
        let window: TimeInterval = 3600
        let hist = model.sentinel.cpuHistory
        let cores = max(model.cores, 1)
        let stacked = hist.stacked(over: window, buckets: buckets, at: now, key: Model.appKey)
        let totals = hist.sparkline(nil, over: window, buckets: buckets, at: now)
        let topKeys = stacked.sorted { $0.value.reduce(0, +) > $1.value.reduce(0, +) }.prefix(5).map(\.key)
        let colors = ColorBook.shared.colors(for: topKeys)
        let width = window / Double(buckets)
        let start = now.addingTimeInterval(-window)
        let recordedFrom = now.addingTimeInterval(-hist.recorded(at: now))
        let points: [Point] = (0..<buckets).flatMap { i -> [Point] in
            let t = start.addingTimeInterval(Double(i) * width + width / 2)
            guard t >= recordedFrom.addingTimeInterval(-width) else { return [] }
            var used = 0.0
            var row = topKeys.map { k -> Point in
                let v = stacked[k]?[i] ?? 0
                used += v
                return Point(time: t, key: k, name: Model.appName(k), value: v / cores)
            }
            row.append(Point(time: t, key: "other", name: "Other", value: max(totals[i] - used, 0) / cores))
            return row
        }
        let domain = topKeys + ["other"]
        Card(title: "Last hour, by app", symbol: "chart.xyaxis.line", tint: Tab.overview.color,
             trailing: AnyView(Text("% of whole Mac").font(.caption2).foregroundStyle(.secondary))) {
            if points.isEmpty {
                Text("Collecting. The chart fills in over the next few minutes.")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 120)
            } else {
                Chart(points) { p in
                    AreaMark(x: .value("Time", p.time), y: .value("CPU", p.value), stacking: .standard)
                        .foregroundStyle(by: .value("App", p.key))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(domain: domain, range: domain.map { colors[$0] ?? Theme.other })
                .chartLegend(.hidden)
                .chartXScale(domain: start...now)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.system(size: 9)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute, count: 15)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9))
                    }
                }
                .frame(height: 104)
                Legend(items: domain.map { ($0 == "other" ? "Other" : Model.appName($0), colors[$0] ?? Theme.other) })
            }
        }
    }
}

/// Swatch and name for each series, wrapped onto as many lines as needed.
struct Legend: View {
    let items: [(String, Color)]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 8, height: 8)
                    Text(item.0).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when out of room.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += line + 4; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + 4; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

/// The plain-English findings, most urgent first.
private struct InsightList: View {
    @ObservedObject var model: Model
    /// Which insights are open. Kept by id, since the list is rebuilt every 5 seconds.
    @State private var open: Set<String> = []
    /// Snapshots open the first `--expand` insights (all by default), to review the full text.
    private func expandAll(_ i: Insight) -> Bool {
        guard Model.snapshotDir != nil else { return false }
        return (model.insights.firstIndex { $0.id == i.id } ?? 0) < Model.snapshotExpand
    }

    var body: some View {
        Card(title: "Insights", symbol: "sparkles", tint: Tab.trends.color) {
            if model.insights.isEmpty {
                Text("Nothing to report yet. Insights appear as CPU Sentinel learns this Mac's patterns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(model.insights) { i in
                    InsightCard(model: model, insight: i, expanded: Binding(
                        get: { expandAll(i) || open.contains(i.id) },
                        set: { if $0 { open.insert(i.id) } else { open.remove(i.id) } }))
                }
            }
        }
    }
}

func toneColor(_ t: Insight.Tone) -> Color {
    switch t {
    case .good: return Theme.heat(0)
    case .info: return Color(light: "#2563eb", dark: "#60a5fa")
    case .warning: return Theme.heat(50)
    case .critical: return Theme.heat(100)
    }
}

/// One finding: headline and summary, opening to the full story, every process involved
/// (what it is, who started it, buttons to act on it) and the steps to fix it.
private struct InsightCard: View {
    @ObservedObject var model: Model
    let insight: Insight
    @Binding var expanded: Bool

    var body: some View {
        let i = insight
        let color = toneColor(i.tone)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SymbolTile(symbol: i.symbol, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(i.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(i.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if i.expandable {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Label(expanded ? "Less" : "More", systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(color)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(color.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("What this means and what to do")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if i.expandable { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } }

            if expanded {
                if let why = i.why {
                    Section("What is happening") {
                        Text(why).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !i.related.isEmpty {
                    Section(i.related.count == 1 ? "The process" : "The processes involved") {
                        VStack(spacing: 6) {
                            ForEach(i.related) { r in RelatedRow(model: model, related: r) }
                        }
                    }
                }
                if !i.steps.isEmpty {
                    Section("What to do") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(i.steps.enumerated()), id: \.offset) { n, step in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(n + 1)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                        .frame(width: 16, height: 16).background(Circle().fill(color))
                                    Text(step).font(.caption).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                ExplainButton { model.explain(i) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.07)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9).fill(color).frame(width: 3)
        }
    }

    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder var content: Content
        init(_ title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }
        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).kerning(0.5)
                content
            }
            .padding(.leading, 36)
        }
    }
}

/// A process inside an insight: what it is, who started it, its CPU, and what to do with it.
private struct RelatedRow: View {
    @ObservedObject var model: Model
    let related: Insight.Related

    var body: some View {
        let s = related.sample
        HStack(alignment: .top, spacing: 8) {
            IconView(icon: IconCache.shared.icon(for: s), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.displayName).font(.caption.weight(.semibold))
                    Text(Fmt.pct(s.cpu)).font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.heat(s.cpu)))
                    if s.isRoot { Pill(text: "root", color: Tab.settings.color) }
                }
                if let about = related.about {
                    Text(about).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let parent = related.parent {
                    Label("started by \(parent)", systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button { model.explain(s) } label: {
                Image(systemName: "sparkles").foregroundStyle(Tab.trends.color)
            }
            .buttonStyle(.plain)
            .help("Explain \(s.name) with ChatGPT")
            if let app = NSRunningApplication(processIdentifier: s.pid), app.bundleURL != nil, app.activationPolicy == .regular {
                Button { app.activate() } label: { Image(systemName: "eye.fill").foregroundStyle(Tab.processes.color) }
                    .buttonStyle(.plain)
                    .help("Bring \(s.name) to the front")
            }
            if s.pid == getpid() {
                EmptyView()
            } else if Safety.canKillManually(s) {
                KillButton(isRoot: s.isRoot) { model.kill(s) }
            } else {
                SudoButton(model: model, sample: s)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
    }
}
