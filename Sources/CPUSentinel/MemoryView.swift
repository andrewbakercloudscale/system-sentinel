import Charts
import SentinelCore
import SwiftUI

/// Memory and swap: how tight it is now, what happened over the last week, who holds the
/// most and who keeps growing.
struct MemoryView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 10) {
            if let m = model.memory {
                MemoryHero(memory: m, swapSince: MemoryAnalysis.summary(model.memoryHistory.points).swapSince)
                InsightList(model: model, only: model.insights.filter { $0.id == "memory" } + model.memoryInsights,
                            title: "Memory insights")
                MemoryTimeline(model: model)
                LargestApps(model: model)
                Breakdown(memory: m, model: model)
                MemoryGuide()
            } else {
                Card(title: "Memory", symbol: "memorychip.fill", tint: Tab.memory.color) {
                    Text("Reading memory…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func gb(_ b: UInt64) -> String { ReportDocument.bytes(b) }
private func pressureColor(_ p: MemoryStatus.Pressure) -> Color {
    switch p {
    case .normal: return Tab.memory.color
    case .warning: return Color(hex: "#d97706")
    case .critical: return Theme.heat(100)
    }
}

// MARK: Hero

private struct MemoryHero: View {
    let memory: MemoryStatus
    let swapSince: Date?

    var body: some View {
        let m = memory
        let share = Double(m.used) / Double(max(m.total, 1))
        HStack(alignment: .center, spacing: 16) {
            Gauge(value: min(share, 1), in: 0...1) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(share * 100))%").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.white)
            .scaleEffect(1.35)
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 4) {
                Text("Pressure: \(m.pressure.label)").font(.title3.weight(.bold)).foregroundStyle(.white)
                Text("\(gb(m.used)) of \(gb(m.total)) in use, \(gb(m.total > m.used ? m.total - m.used : 0)) available")
                    .font(.callout).foregroundStyle(.white.opacity(0.9))
                if let since = swapSince, m.swapUsed >= MemoryAnalysis.swapNoise {
                    Text("Swapping since \(since.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.callout).foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer()
            VStack(spacing: 2) {
                Text(gb(m.swapUsed)).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit()
                Text("in swap").font(.caption).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private var colors: [Color] {
        switch memory.pressure {
        case .normal: return [Color(hex: "#0e7490"), Color(hex: "#1d4ed8")]
        case .warning: return [Color(hex: "#b45309"), Color(hex: "#c2410c")]
        case .critical: return [Color(hex: "#b91c1c"), Color(hex: "#9f1239")]
        }
    }
}

// MARK: Timeline

private struct MemoryTimeline: View {
    @ObservedObject var model: Model
    @AppStorage("memoryRange") private var range = "6 hours"

    struct Bucket: Identifiable {
        let start: Date
        let used: Double
        let swap: Double
        let pressure: Int
        /// MB a second.
        let swapIn: Double
        let swapOut: Double
        var id: Date { start }
    }

    static let ranges: [(String, TimeInterval, Int)] = [("1 hour", 3600, 60), ("6 hours", 6 * 3600, 300),
                                                       ("24 hours", 86_400, 900), ("7 days", 7 * 86_400, 3600)]

    var body: some View {
        let (_, span, bucket) = Self.ranges.first { $0.0 == range } ?? Self.ranges[1]
        let now = Date()
        let points = model.memoryHistory.since(now.addingTimeInterval(-span))
        let buckets = Self.buckets(points, size: bucket)
        let s = MemoryAnalysis.summary(points)
        let total = Double(model.memory?.total ?? 0) / 1_073_741_824
        Card(title: "Memory and swap over time", symbol: "chart.xyaxis.line", tint: Tab.memory.color,
             trailing: AnyView(ChipPicker(options: Self.ranges.map(\.0), selection: $range, color: Tab.memory.color))) {
            HStack(spacing: 8) {
                StatTile(symbol: "externaldrive.fill", color: Color(hex: "#d97706"), value: gb(s.peakSwap),
                         label: s.peakSwapAt.map { "peak swap, \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" } ?? "peak swap")
                StatTile(symbol: "memorychip", color: Tab.memory.color, value: gb(s.peakUsed), label: "peak in use")
                StatTile(symbol: "gauge.with.dots.needle.67percent", color: s.warningMinutes + s.criticalMinutes > 0 ? Theme.heat(80) : Tab.battery.color,
                         value: Insights.duration(Double(s.warningMinutes + s.criticalMinutes) * 60), label: "under pressure")
            }
            if buckets.count < 2 {
                Text("Collecting: the timeline fills in as CPU Sentinel runs. Readings are kept for 7 days.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                let unit: Calendar.Component = bucket >= 3600 ? .hour : .minute
                Chart {
                    ForEach(buckets.filter { $0.pressure >= MemoryStatus.Pressure.warning.rawValue }) { b in
                        RectangleMark(xStart: .value("Start", b.start), xEnd: .value("End", b.start.addingTimeInterval(Double(bucket))))
                            .foregroundStyle((b.pressure >= MemoryStatus.Pressure.critical.rawValue ? Theme.heat(100) : Color(hex: "#d97706")).opacity(0.14))
                    }
                    ForEach(buckets) { b in
                        AreaMark(x: .value("Time", b.start, unit: unit), y: .value("GB", b.used), series: .value("Series", "In use"), stacking: .unstacked)
                            .foregroundStyle(Tab.memory.color.opacity(0.25))
                        LineMark(x: .value("Time", b.start, unit: unit), y: .value("GB", b.used), series: .value("Series", "In use"))
                            .foregroundStyle(Tab.memory.color)
                        AreaMark(x: .value("Time", b.start, unit: unit), y: .value("GB", b.swap), series: .value("Series", "Swap"), stacking: .unstacked)
                            .foregroundStyle(Color(hex: "#d97706").opacity(0.3))
                        LineMark(x: .value("Time", b.start, unit: unit), y: .value("GB", b.swap), series: .value("Series", "Swap"))
                            .foregroundStyle(Color(hex: "#d97706"))
                    }
                    if total > 0 {
                        RuleMark(y: .value("RAM", total)).foregroundStyle(Color.primary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("\(Int(total.rounded())) GB RAM").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartXScale(domain: now.addingTimeInterval(-span)...now)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let g = v.as(Double.self) { Text("\(Int(g)) GB") } }.font(.system(size: 9))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: span > 86_400 ? .dateTime.weekday(.abbreviated) : .dateTime.hour().minute()).font(.system(size: 9))
                    }
                }
                .frame(height: 140)
                HStack(spacing: 12) {
                    legend(Tab.memory.color, "In use")
                    legend(Color(hex: "#d97706"), "Swap on disk")
                    legend(Color(hex: "#d97706").opacity(0.35), "Under pressure")
                }

                Text("SWAP ACTIVITY").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).kerning(0.5).padding(.top, 4)
                Chart(buckets) { b in
                    BarMark(x: .value("Time", b.start, unit: unit), y: .value("MB/s", b.swapOut), width: .ratio(0.8))
                        .foregroundStyle(by: .value("Direction", "Written to swap"))
                    BarMark(x: .value("Time", b.start, unit: unit), y: .value("MB/s", -b.swapIn), width: .ratio(0.8))
                        .foregroundStyle(by: .value("Direction", "Read back from swap"))
                }
                .chartForegroundStyleScale(["Written to swap": Color(hex: "#d97706"), "Read back from swap": Theme.heat(100)])
                .chartXScale(domain: now.addingTimeInterval(-span)...now)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let x = v.as(Double.self) { Text(String(format: abs(x) < 10 ? "%.1f MB/s" : "%.0f MB/s", abs(x))) } }.font(.system(size: 9))
                    }
                }
                .chartXAxis(.hidden)
                .chartLegend(position: .bottom, spacing: 4)
                .frame(height: 80)
            }
            Text("Swap that sits still is harmless. Bars below the line are memory read back from disk: that is the part that makes a Mac feel slow.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func buckets(_ points: [MemoryHistory.Point], size: Int) -> [Bucket] {
        let groups = Dictionary(grouping: points) { $0.t / size * size }
        let g = 1_073_741_824.0, mb = 1_048_576.0
        return groups.map { start, p in
            let n = Double(p.count)
            return Bucket(start: Date(timeIntervalSince1970: Double(start)),
                          used: p.reduce(0) { $0 + Double($1.used) } / n / g,
                          swap: Double(p.map(\.swap).max() ?? 0) / g,
                          pressure: p.map(\.pressure).max() ?? 0,
                          swapIn: p.reduce(0) { $0 + $1.swapIn } / n / mb,
                          swapOut: p.reduce(0) { $0 + $1.swapOut } / n / mb)
        }
        .sorted { $0.start < $1.start }
    }
}

// MARK: Largest apps

private struct LargestApps: View {
    @ObservedObject var model: Model

    var body: some View {
        let apps = Array(model.memoryApps.prefix(10))
        let total = model.memory?.total ?? 1
        let hourAgo = Self.bytesAgo(model.memoryHistory.points, seconds: 3600)
        Card(title: "Largest apps", symbol: "square.stack.3d.up.fill", tint: Tab.memory.color) {
            if apps.isEmpty {
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(apps) { a in
                HStack(spacing: 10) {
                    IconView(icon: IconCache.shared.icon(for: a.sample), size: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(a.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if a.pids.count > 1 {
                                Text("\(a.pids.count) processes").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            }
                            if let before = hourAgo[a.key], a.bytes > before, a.bytes - before >= 256 << 20 {
                                Pill(text: "+\(gb(a.bytes - before)) in 1 h", symbol: "arrow.up.right", color: Color(hex: "#d97706"))
                            }
                            Spacer(minLength: 4)
                            Text(gb(a.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        ShareBar(share: Double(a.bytes) / Double(max(total, 1)), color: Tab.memory.color)
                    }
                    if a.sample.pid != getpid(), Safety.canKillManually(a.sample) {
                        Button { model.perform(.quit(pids: a.pids, name: a.name)) } label: {
                            Label("Quit", systemImage: "xmark.circle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Theme.heat(100).gradient))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Quit \(a.name) properly, so it can save, and give its \(gb(a.bytes)) back")
                    } else {
                        Color.clear.frame(width: 62, height: 1)
                    }
                }
            }
            Text("Memory as Activity Monitor counts it, added up across each app's processes. Bars are a share of the Mac's \(gb(total)). Apps of other users (system services) may show their resident size instead.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Each app's memory about `seconds` ago, from the timeline's top apps.
    static func bytesAgo(_ points: [MemoryHistory.Point], seconds: TimeInterval) -> [String: UInt64] {
        let t = Int(Date().timeIntervalSince1970 - seconds)
        guard let p = points.last(where: { $0.t <= t }), t - p.t <= 600 else { return [:] }
        return Dictionary(p.apps.map { ($0.key, $0.bytes) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: Breakdown

private struct Breakdown: View {
    let memory: MemoryStatus
    @ObservedObject var model: Model

    var body: some View {
        let m = memory
        let parts: [(String, UInt64, Color, String)] = [
            ("App memory", m.app, Tab.memory.color, "what apps are using"),
            ("Wired", m.wired, Color(hex: "#6366f1"), "the system's own, never moved"),
            ("Compressed", m.compressed, Color(hex: "#d97706"), "idle memory squeezed to fit"),
            ("Cached files", m.cached, Tab.battery.color, "dropped instantly when needed"),
            ("Free", m.free, Color.secondary, "not used at all"),
        ]
        let total = Double(max(m.total, 1))
        let last = model.memoryHistory.points.last
        Card(title: "Where the memory is", symbol: "chart.bar.fill", tint: Tab.memory.color) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2.gradient).frame(width: max(g.size.width * Double(p.1) / total - 1, 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 14)
            VStack(spacing: 4) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 10, height: 10)
                        Text(p.0).font(.callout).frame(width: 110, alignment: .leading)
                        Text(p.3).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(gb(p.1)).font(.callout.weight(.semibold)).monospacedDigit()
                    }
                }
            }
            HStack(spacing: 8) {
                let ratio = m.compressed > 0 ? Double(m.compressedOriginal) / Double(m.compressed) : 0
                StatTile(symbol: "arrow.down.right.and.arrow.up.left", color: Color(hex: "#d97706"),
                         value: ratio >= 1 ? String(format: "%.1f×", ratio) : "–",
                         label: ratio >= 1 ? "\(gb(m.compressedOriginal)) squeezed into \(gb(m.compressed))" : "compression")
                StatTile(symbol: "square.and.arrow.down.fill", color: Color(hex: "#d97706"),
                         value: last.map { String(format: "%.1f MB/s", $0.swapOut / 1_048_576) } ?? "–", label: "written to swap now")
                StatTile(symbol: "square.and.arrow.up.fill", color: Theme.heat(100),
                         value: last.map { String(format: "%.1f MB/s", $0.swapIn / 1_048_576) } ?? "–", label: "read back now")
            }
        }
    }
}

// MARK: Guide

private struct MemoryGuide: View {
    var body: some View {
        Card(title: "How Mac memory works", symbol: "book.fill", tint: Tab.memory.color) {
            VStack(alignment: .leading, spacing: 8) {
                row("gauge.with.dots.needle.50percent", "Pressure is what matters",
                    "macOS keeps memory busy on purpose, so a full-looking bar is normal. Pressure says whether apps get what they ask for.")
                row("arrow.down.right.and.arrow.up.left", "Compression comes first",
                    "When memory runs short, macOS squeezes memory apps are not touching. That costs a little CPU and is usually unnoticeable.")
                row("externaldrive.fill", "Then swap",
                    "If squeezing is not enough, idle memory is written to a swap file on the SSD. Swap that just sits there is harmless; it empties on restart.")
                row("arrow.triangle.2.circlepath", "Reading swap back is the slow part",
                    "When apps need swapped memory back again and again (thrashing), everything waits on the disk. The fix is fewer large apps open at once.")
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolTile(symbol: symbol, color: Tab.memory.color, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
