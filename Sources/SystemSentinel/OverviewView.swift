import AppKit
import Charts
import SentinelCore
import SwiftUI

/// How busy the Mac is and who is responsible. What is wrong is on Checkup, with a line
/// here pointing at it.
struct OverviewView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 10) {
            LookAtBanner(model: model)
            Hero(model: model)
            // Same height side by side; each opens a larger, live version when clicked.
            HStack(alignment: .top, spacing: 10) {
                NowDonut(model: model).frame(width: 290)
                    .modifier(ZoomOnClick(kind: .now, model: model))
                LastHourChart(model: model)
                    .modifier(ZoomOnClick(kind: .lastHour, model: model))
            }
            .fixedSize(horizontal: false, vertical: true)
            CoresCard(model: model)
            MemoryCard(model: model)
        }
    }
}

/// "3 things to look at", linking to Checkup, where they are listed with their fixes.
private struct LookAtBanner: View {
    @ObservedObject var model: Model
    @State private var hover = false

    var body: some View {
        let a = model.attention()
        if a.count > 0 {
            let color = a.problems > 0 ? Theme.heat(100) : Color(hex: "#d97706")
            let first = a.symptoms.first?.check.title ?? a.insights.first?.title ?? a.checks.first?.title ?? ""
            Button { model.goTab = Tab.checkup.title } label: {
                HStack(spacing: 10) {
                    Image(systemName: "stethoscope").font(.title3.weight(.semibold)).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(a.count) thing\(a.count == 1 ? "" : "s") to look at").font(.callout.weight(.semibold))
                        Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Label("Checkup", systemImage: "arrow.right.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(color)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(hover ? 0.16 : 0.1)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.4)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .tip("Open Checkup: each one with what to do and a Fix it button")
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
                    .font(.caption2).foregroundStyle(.white.opacity(0.85)).padding(6)
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
            .tip("Average share of the whole Mac over the last \(label)")
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
struct NowDonut: View {
    @ObservedObject var model: Model
    /// The larger version in its own window: more apps, a bigger ring, cores per app.
    var zoomed = false

    struct Slice: Identifiable {
        let key: String
        let name: String
        let cpu: Double
        var id: String { key }
    }

    var body: some View {
        let slices = Self.slices(model.sentinel.latest, top: zoomed ? 7 : 5)
        let colors = ColorBook.shared.colors(for: slices.map(\.key).filter { $0 != "other" })
        let total = slices.reduce(0) { $0 + $1.cpu }
        let ring: CGFloat = zoomed ? 260 : 92
        Card(title: "Right now", symbol: "chart.pie.fill", tint: Tab.overview.color,
             trailing: zoomed ? AnyView(Text("share of CPU in use").font(.caption).foregroundStyle(.secondary)) : AnyView(ZoomHint()),
             fill: true) {
            HStack(alignment: .center, spacing: zoomed ? 28 : 10) {
                Chart(slices) { s in
                    SectorMark(angle: .value("CPU", s.cpu), innerRadius: .ratio(0.62), angularInset: zoomed ? 2 : 1.2)
                        .cornerRadius(zoomed ? 5 : 3)
                        .foregroundStyle(colors[s.key] ?? Theme.other)
                }
                .chartLegend(.hidden)
                .frame(width: ring, height: ring)
                .overlay {
                    VStack(spacing: 0) {
                        Text(String(format: "%.1f", total / 100)).font(.system(size: zoomed ? 40 : 16, weight: .bold, design: .rounded))
                        Text("cores").font(.system(size: zoomed ? 14 : 9)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: zoomed ? 9 : 4) {
                    ForEach(slices) { s in
                        HStack(spacing: zoomed ? 8 : 5) {
                            RoundedRectangle(cornerRadius: 2).fill(colors[s.key] ?? Theme.other)
                                .frame(width: zoomed ? 12 : 8, height: zoomed ? 12 : 8)
                            Text(s.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            if zoomed {
                                Text(String(format: "%.2f cores", s.cpu / 100)).foregroundStyle(.secondary).monospacedDigit()
                                    .frame(width: 90, alignment: .trailing)
                            }
                            Text(Fmt.pct(total > 0 ? s.cpu / total * 100 : 0)).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: zoomed ? 56 : nil, alignment: .trailing)
                        }
                        .font(zoomed ? .body : .caption2)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    static func slices(_ samples: [ProcessSample], top: Int = 5) -> [Slice] {
        var byApp: [String: Double] = [:]
        for s in samples where s.cpu > 0 { byApp[Model.appKey(s.path), default: 0] += s.cpu }
        let sorted = byApp.sorted { $0.value > $1.value }
        var out = sorted.prefix(top).map { Slice(key: $0.key, name: Model.appName($0.key), cpu: $0.value) }
        let rest = sorted.dropFirst(top).reduce(0) { $0 + $1.value }
        if rest > 0 { out.append(Slice(key: "other", name: "Everything else", cpu: rest)) }
        return out
    }
}

/// "Click to zoom", in the corner of a chart card.
struct ZoomHint: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            .tip("Click to open a larger version")
    }
}

/// The last hour, stacked by the apps that used most of it.
struct LastHourChart: View {
    @ObservedObject var model: Model
    /// The larger version in its own window: more apps, finer buckets, hover for values.
    var zoomed = false
    @State private var selected: Date?

    struct Point: Identifiable {
        let time: Date
        let key: String
        let name: String
        let value: Double
        var id: String { "\(key)@\(time.timeIntervalSince1970)" }
    }

    /// The stacked series: live history where there is some, before it the saved per-minute
    /// store, so a relaunch does not blank the chart.
    private func series(zoomed: Bool) -> (points: [Point], topKeys: [String], gaps: [ClosedRange<Date>]) {
        let now = Date()
        let buckets = zoomed ? 120 : 60
        let window: TimeInterval = 3600
        let hist = model.sentinel.cpuHistory
        let cores = max(model.cores, 1)
        let stacked = hist.stacked(over: window, buckets: buckets, at: now, key: Model.appKey)
        let totals = hist.sparkline(nil, over: window, buckets: buckets, at: now)
        let width = window / Double(buckets)
        let start = now.addingTimeInterval(-window)
        let recordedFrom = now.addingTimeInterval(-hist.recorded(at: now))
        // The live history starts empty at launch; before it, use the saved per-minute store.
        let minutes = model.sentinel.recentUsage
        let minuteStarts = minutes.starts(at: now, count: 61)
        let minuteRows = minutes.summaries(at: now, buckets: 61, group: Model.appKey, name: Model.appName)
        let minuteByKey = Dictionary(minuteRows.map { ($0.key, $0.hourly) }, uniquingKeysWith: { a, _ in a })
        let minuteTotals = minuteStarts.indices.map { m in minuteRows.reduce(0) { $0 + $1.hourly[m] } }
        let minuteCoverage = minutes.coverage(at: now, buckets: 61)
        func savedMinute(_ t: Date) -> Int? {
            guard t < recordedFrom, let m = minuteStarts.firstIndex(of: minutes.start(t)), minuteCoverage[m] >= 15 else { return nil }
            return m
        }
        func value(_ k: String, _ i: Int, _ t: Date) -> Double {
            if let m = savedMinute(t) { return minuteByKey[k]?[m] ?? 0 }
            return stacked[k]?[i] ?? 0
        }
        let times = (0..<buckets).map { start.addingTimeInterval(Double($0) * width + width / 2) }
        let keys = Set(stacked.keys).union(minuteByKey.keys)
        let weight = Dictionary(keys.map { k in (k, times.indices.reduce(0) { $0 + value(k, $1, times[$1]) }) }, uniquingKeysWith: +)
        let topKeys = weight.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(zoomed ? 7 : 5).map(\.key)
        let measured = times.map { savedMinute($0) != nil || $0 >= recordedFrom.addingTimeInterval(-width) }
        // Stretches with nothing recorded (the app was not running, or the Mac was asleep).
        // The area drops to zero across them rather than bridging the gap with a made-up curve.
        var gaps: [ClosedRange<Date>] = []
        var edges = Set<Int>()
        var i = 0
        while i < buckets {
            guard !measured[i] else { i += 1; continue }
            var j = i
            while j + 1 < buckets, !measured[j + 1] { j += 1 }
            gaps.append(times[i].addingTimeInterval(-width / 2)...times[j].addingTimeInterval(width / 2))
            if i > 0 { edges.insert(i) }
            if j + 1 < buckets { edges.insert(j) }
            i = j + 1
        }
        let points: [Point] = (0..<buckets).flatMap { i -> [Point] in
            let t = times[i]
            let saved = savedMinute(t)
            if edges.contains(i) {
                return (topKeys + ["other"]).map { Point(time: t, key: $0, name: $0 == "other" ? "Other" : Model.appName($0), value: 0) }
            }
            guard measured[i] else { return [] }
            var used = 0.0
            var row = topKeys.map { k -> Point in
                let v = value(k, i, t)
                used += v
                return Point(time: t, key: k, name: Model.appName(k), value: v / cores)
            }
            let total = saved.map { minuteTotals[$0] } ?? totals[i]
            row.append(Point(time: t, key: "other", name: "Other", value: max(total - used, 0) / cores))
            return row
        }
        return (points, topKeys, gaps.filter { $0.upperBound.timeIntervalSince($0.lowerBound) >= 3 * 60 })
    }

    /// Whole times every `every` minutes, leaving out any within a few minutes of now.
    private func axisTimes(start: Date, now: Date, every: Int) -> [Date] {
        let cal = Calendar.current
        var t = cal.dateInterval(of: .hour, for: start)?.start ?? start
        var out: [Date] = []
        while t <= now {
            if t >= start, now.timeIntervalSince(t) >= Double(every) * 60 / 3 { out.append(t) }
            t = t.addingTimeInterval(Double(every) * 60)
        }
        return out
    }

    var body: some View {
        let (points, topKeys, gaps) = series(zoomed: zoomed)
        let now = Date()
        let window: TimeInterval = 3600
        let start = now.addingTimeInterval(-window)
        let colors = ColorBook.shared.colors(for: topKeys)
        let domain = topKeys + ["other"]
        // The hovered moment: the nearest bucket's values, for the tooltip.
        let hovered: [Point] = selected.flatMap { sel in
            points.min { abs($0.time.timeIntervalSince(sel)) < abs($1.time.timeIntervalSince(sel)) }
                .map { near in points.filter { $0.time == near.time } }
        } ?? []
        Card(title: "Last hour, by app", symbol: "chart.xyaxis.line", tint: Tab.overview.color,
             trailing: AnyView(HStack(spacing: 8) {
                 Text(zoomed ? "% of whole Mac · hover for values" : "% of whole Mac").font(zoomed ? .caption : .caption2).foregroundStyle(.secondary)
                 if !zoomed { ZoomHint() }
             }), fill: true) {
            if points.isEmpty {
                Text("Collecting. The chart fills in over the next few minutes.")
                    .font(.caption).foregroundStyle(.secondary).frame(height: zoomed ? 400 : 120)
            } else {
                Chart {
                    ForEach(gaps, id: \.lowerBound) { g in
                        RectangleMark(xStart: .value("From", g.lowerBound), xEnd: .value("To", g.upperBound))
                            .foregroundStyle(Color.primary.opacity(0.05))
                            .annotation(position: .overlay, alignment: .center) {
                                if g.upperBound.timeIntervalSince(g.lowerBound) >= (zoomed ? 6 : 12) * 60 {
                                    Text("Not recording").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                    }
                    ForEach(points) { p in
                        AreaMark(x: .value("Time", p.time), y: .value("CPU", p.value), stacking: .standard)
                            .foregroundStyle(by: .value("App", p.key))
                            .interpolationMethod(.monotone)
                    }
                    if let t = hovered.first?.time {
                        RuleMark(x: .value("Time", t))
                            .foregroundStyle(Color.primary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: t > now.addingTimeInterval(-window / 2) ? .leading : .trailing, alignment: .top) {
                                HoverCard(time: t, rows: hovered.reversed().map { ($0.key == "other" ? "Other" : $0.name, colors[$0.key] ?? Theme.other, $0.value) })
                            }
                    }
                }
                .chartForegroundStyleScale(domain: domain, range: domain.map { colors[$0] ?? Theme.other })
                .chartLegend(.hidden)
                .chartXScale(domain: start...now, range: .plotDimension(endPadding: zoomed ? 18 : 10))
                .chartOverlay { proxy in
                    // Hover, not click: the small card's click opens the zoomed window.
                    if zoomed {
                        GeometryReader { geo in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let at):
                                        guard let frame = proxy.plotFrame else { return }
                                        selected = proxy.value(atX: at.x - geo[frame].origin.x, as: Date.self)
                                    case .ended: selected = nil
                                    }
                                }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: zoomed ? 6 : 3)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.system(size: zoomed ? 11 : 9)) } }
                    }
                }
                .chartXAxis {
                    // No label hard against the right edge, where it would be cut to "…".
                    AxisMarks(values: axisTimes(start: start, now: now, every: zoomed ? 5 : 15)) { _ in
                        if zoomed { AxisGridLine().foregroundStyle(Color.primary.opacity(0.05)) }
                        AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: zoomed ? 11 : 9))
                    }
                }
                .frame(height: zoomed ? nil : 104)
                .frame(maxHeight: zoomed ? .infinity : nil)
                Legend(items: domain.map { ($0 == "other" ? "Other" : Model.appName($0), colors[$0] ?? Theme.other) })
            }
        }
    }
}

/// The values at the hovered moment, top series first.
private struct HoverCard: View {
    let time: Date
    let rows: [(String, Color, Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(time.formatted(date: .omitted, time: .shortened)).font(.caption.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(r.1).frame(width: 8, height: 8)
                    Text(r.0).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f%%", r.2)).monospacedDigit()
                }
                .font(.caption2)
            }
            Divider()
            HStack {
                Text("Total").font(.caption2.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f%%", rows.reduce(0) { $0 + $1.2 })).font(.caption2.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(8)
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }
}

/// A chart from the Overview in its own resizable window, kept live.
@MainActor
enum ChartZoom {
    enum Kind: String { case now = "Right now", lastHour = "Last hour, by app" }
    private static var windows: [Kind: NSWindow] = [:]

    static func show(_ kind: Kind, model: Model) {
        if windows[kind] == nil {
            let root = Group {
                switch kind {
                case .now: NowDonut(model: model, zoomed: true)
                case .lastHour: LastHourChart(model: model, zoomed: true)
                }
            }
            .padding(14)
            .frame(minWidth: 640, minHeight: 420)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "System Sentinel: \(kind.rawValue)"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(kind == .now ? NSSize(width: 760, height: 440) : NSSize(width: 960, height: 600))
            w.setFrameAutosaveName("SystemSentinelZoom-\(kind)")
            if !w.setFrameUsingName("SystemSentinelZoom-\(kind)") { w.center() }
            windows[kind] = w
        }
        NSApp.activate(ignoringOtherApps: true)
        windows[kind]?.makeKeyAndOrderFront(nil)
    }
}

/// Makes a card a button that opens its zoomed window, with a pointing hand on hover.
struct ZoomOnClick: ViewModifier {
    let kind: ChartZoom.Kind
    let model: Model

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { ChartZoom.show(kind, model: model) }
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .tip("Click to open a larger version")
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
struct InsightList: View {
    @ObservedObject var model: Model
    /// Show these instead of the Overview's list.
    var only: [Insight]?
    var title = "Insights"
    private var live: [Insight] { only ?? model.insights }
    private var items: [Insight] { held?.items ?? live }
    /// Which insights are open. Kept by id, since the list is rebuilt every 5 seconds.
    @State private var open: Set<String> = []
    /// The list as it stood when you started reading. The list is rebuilt every 5 seconds and
    /// findings come, go and change order, which moved the text under the pointer; while the
    /// pointer is on the list or an insight is open, it holds still.
    @State private var held: (items: [Insight], at: Date)?
    @State private var hovering = false
    private var reading: Bool { Model.snapshotDir == nil && (hovering || !open.isEmpty) }
    /// Snapshots open the first `--expand` insights (all by default), to review the full text.
    private func expandAll(_ i: Insight) -> Bool {
        guard Model.snapshotDir != nil else { return false }
        return (items.firstIndex { $0.id == i.id } ?? 0) < Model.snapshotExpand
    }

    var body: some View {
        Card(title: title, symbol: "sparkles", tint: Tab.trends.color) {
            if items.isEmpty {
                Text("Nothing to report yet. Insights appear as System Sentinel learns this Mac's patterns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(items) { i in
                    InsightCard(model: model, insight: i, expanded: Binding(
                        get: { expandAll(i) || open.contains(i.id) },
                        set: { if $0 { open.insert(i.id) } else { open.remove(i.id) } }))
                }
            }
        }
        // In the title row, over the layout rather than in it: a line appearing above the
        // text would move it, the very thing holding still is for.
        .overlay(alignment: .topTrailing) {
            if let held, held.items != live {
                Button { self.held = (live, Date()) } label: {
                    Label("Held while you read · Show latest", systemImage: "pause.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Tab.trends.color)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Tab.trends.color.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .tip("Newer findings since \(held.at.formatted(date: .omitted, time: .shortened)) are waiting. They show when you move the pointer away and close any open insight.")
                .padding(.top, 10).padding(.trailing, 12)
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: reading) { _, now in held = now ? (live, Date()) : nil }
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
struct InsightCard: View {
    @ObservedObject var model: Model
    let insight: Insight
    @Binding var expanded: Bool
    /// Shows an Ignore button, for the Checkup list.
    var onIgnore: (() -> Void)?

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
                if let onIgnore { IgnoreButton(subject: !i.related.isEmpty, action: onIgnore) }
                if i.expandable {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Label(expanded ? "Less" : "More", systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(color)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(color.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .tip("What this means and what to do")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if i.expandable { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } }
            if !i.fixes.isEmpty {
                FixButtons(model: model, fixes: i.fixes).padding(.leading, 36)
            }

            if expanded {
                if let about = i.about {
                    Section("What it is") {
                        Text(about).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let why = i.why {
                    Section("What is happening") {
                        Text(why).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !i.related.isEmpty {
                    Section(i.related.count == 1 ? "The process" : "The processes involved") {
                        VStack(spacing: 6) {
                            ForEach(i.related) { r in RelatedRow(model: model, related: r, force: i.offersForceKill) }
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
    /// The polite kill already failed: offer Force kill instead.
    var force = false

    var body: some View {
        let s = related.sample
        HStack(alignment: .top, spacing: 8) {
            IconView(icon: IconCache.shared.icon(for: s), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(related.title ?? s.displayName).font(.caption.weight(.semibold))
                    // A memory insight shows memory; CPU there would read as the wrong number.
                    if let bytes = related.memoryBytes {
                        Text(ReportDocument.bytes(bytes)).font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Tab.memory.color))
                            .tip("Memory it holds: in RAM plus compressed or in swap")
                    } else {
                        Text(Fmt.pct(s.cpu)).font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.heat(s.cpu)))
                            .tip("CPU now; 100% is one core")
                    }
                    if s.isRoot { Pill(text: "root", symbol: "lock.fill", color: Color(hex: "#b45309")) }
                }
                if let about = related.about {
                    Text(about).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let parent = related.parent {
                    Label("started by \(parent)", systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button { model.explain(s) } label: {
                Image(systemName: "sparkles").foregroundStyle(Tab.trends.color)
            }
            .buttonStyle(.plain)
            .tip("Explain \(s.name) with ChatGPT")
            if let app = NSRunningApplication(processIdentifier: s.pid), app.bundleURL != nil, app.activationPolicy == .regular {
                Button { app.activate() } label: { Image(systemName: "eye.fill").foregroundStyle(Tab.processes.color) }
                    .buttonStyle(.plain)
                    .tip("Bring \(s.name) to the front")
            }
            if s.pid == getpid() {
                EmptyView()
            } else if let pids = related.pids, let name = related.title, Safety.canKillManually(s) {
                // The row is the whole app, so its button quits the whole app.
                Button { model.confirmAndPerform(.quit(pids: pids, name: name)) } label: {
                    Label("Quit", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.heat(100)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .tip("Quit \(name), all \(pids.count) processes. Asks first.")
            } else if force {
                ForceKillButton(model: model, sample: s)
            } else if Safety.canKillManually(s) {
                KillButton(model: model, sample: s)
            } else {
                SudoButton(model: model, sample: s)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
    }
}
