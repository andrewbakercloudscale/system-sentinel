import Charts
import SentinelCore
import SwiftUI

/// What has used the CPU over the last half hour to the last week: a stacked chart over time,
/// then the ranking with each one's share, average, peak and when it peaked.
struct TrendsView: View {
    @ObservedObject var model: Model
    @AppStorage("trendRange") private var range = Range.day.rawValue
    @AppStorage("dailyByApp") private var byApp = true

    enum Range: String, CaseIterable {
        case halfHour = "30 min", threeHours = "3 hours", sixHours = "6 hours", day = "24 hours", week = "7 days"

        /// Up to 6 hours comes from the one-minute store, longer from the hourly one.
        var fine: Bool { self == .halfHour || self == .threeHours || self == .sixHours }
        var span: TimeInterval {
            switch self {
            case .halfHour: return 1800
            case .threeHours: return 3 * 3600
            case .sixHours: return 6 * 3600
            case .day: return 24 * 3600
            case .week: return 7 * 24 * 3600
            }
        }
        /// Store buckets per bar, so every range has 24 to 36 bars.
        var fold: Int {
            switch self {
            case .halfHour, .day: return 1
            case .threeHours: return 5
            case .sixHours: return 10
            case .week: return 6
            }
        }
        var barTitle: String {
            switch self {
            case .halfHour: return "CPU per minute"
            case .threeHours: return "CPU per 5 minutes"
            case .sixHours: return "CPU per 10 minutes"
            case .day: return "CPU per hour"
            case .week: return "CPU per 6 hours"
            }
        }
    }

    struct Bar: Identifiable {
        let start: Date
        let key: String
        let value: Double
        var id: String { "\(key)@\(start.timeIntervalSince1970)" }
    }

    /// Everything the screen shows, computed once per render.
    struct Data {
        let range: Range
        let now: Date
        let rows: [DailyUsage.Summary]
        let sampled: TimeInterval
        let total: Double
        let cores: Double
        let colors: [String: Color]
        let bars: [Bar]
        let domain: [String]
        /// The chart's time axis, and how wide one bar is in seconds.
        let start: Date
        let end: Date
        let barSeconds: TimeInterval

        func name(_ key: String) -> String {
            key == "other" ? "Everything else" : rows.first { $0.key == key }?.name ?? key
        }
    }

    var body: some View {
        let d = data()
        VStack(spacing: 10) {
            HStack {
                ChipPicker(options: Range.allCases.map(\.rawValue), selection: $range, color: Theme.trends)
                Spacer()
                Toggle("Group by app", isOn: $byApp).toggleStyle(.switch).controlSize(.mini).font(.caption)
            }
            TrendStats(d: d)
            TrendChart(d: d, byApp: byApp)
            HeaviestCard(d: d, byApp: byApp)
            Text("Averages count only the time System Sentinel was running, so a day it was quit for does not read as idle. 100% in the table is one core; the chart is the whole Mac.")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func data() -> Data {
        let r = Range(rawValue: range) ?? .day
        let now = Date()
        let usage = r.fine ? model.sentinel.recentUsage : model.sentinel.dailyUsage
        let count = Int(r.span) / usage.bucket
        let cores = max(model.cores, 1)
        let group: ((String) -> String)? = byApp ? { Model.appKey($0) } : nil
        let name: ((String) -> String)? = byApp ? { Model.appName($0) } : nil
        let rows: [DailyUsage.Summary] = usage.summaries(at: now, buckets: count, group: group, name: name)
        let topKeys: [String] = rows.prefix(6).map { $0.key }
        let colors = ColorBook.shared.colors(for: topKeys)
        let starts = usage.starts(at: now, count: count)
        let bars = Self.bars(rows: rows, topKeys: topKeys, coverage: usage.coverage(at: now, buckets: count),
                             starts: starts, fold: r.fold, cores: cores)
        return Data(range: r, now: now, rows: rows, sampled: usage.sampled(at: now, buckets: count),
                    total: rows.reduce(0) { $0 + $1.coreSeconds }, cores: cores, colors: colors,
                    bars: bars, domain: topKeys + ["other"],
                    start: Date(timeIntervalSince1970: Double(starts.first ?? 0)),
                    end: Date(timeIntervalSince1970: Double((starts.last ?? 0) + usage.bucket)),
                    barSeconds: Double(usage.bucket * r.fold))
    }

    /// Folds the bucket series into bars of `fold` buckets, each the mean over the time
    /// actually sampled in it, as a share of the whole machine.
    static func bars(rows: [DailyUsage.Summary], topKeys: [String], coverage: [Double], starts: [Int], fold: Int, cores: Double) -> [Bar] {
        let count = starts.count
        let top = Set(topKeys)
        var out: [Bar] = []
        // Group buckets aligned to the end of the range.
        var index = count % fold == 0 ? 0 : count % fold - fold
        while index < count {
            let lo = max(index, 0), hi = min(index + fold, count)
            index += fold
            let cov = coverage[lo..<hi].reduce(0, +)
            guard cov > 0 else { continue }
            let start = Date(timeIntervalSince1970: Double(starts[lo]))
            var other = 0.0
            for row in rows {
                // hourly is percent of one core over each bucket's sampled time; weight it back.
                let cs = (lo..<hi).reduce(0.0) { $0 + row.hourly[$1] / 100 * coverage[$1] }
                let v = cs / cov * 100 / cores
                if top.contains(row.key) { out.append(Bar(start: start, key: row.key, value: v)) } else { other += v }
            }
            out.append(Bar(start: start, key: "other", value: other))
        }
        return out
    }
}

struct StatTile: View {
    let symbol: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            SymbolTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.09)))
    }
}

private struct UsageRow: View {
    let rank: Int
    let row: DailyUsage.Summary
    let share: Double
    let color: Color
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(width: 16)
            IconView(icon: IconCache.shared.icon(for: ProcessSample(pid: 0, uid: 501, cpu: 0, path: row.key)), size: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Fmt.pct(share * 100)).font(.caption.weight(.semibold)).monospacedDigit()
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(color).frame(width: max(3, g.size.width * share))
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            Text(Fmt.pct(row.average)).font(.caption).monospacedDigit().foregroundStyle(Theme.heat(row.average)).frame(width: 48, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Fmt.pct(row.peak)).font(.caption).monospacedDigit().foregroundStyle(Theme.heat(row.peak))
                if let h = row.peakHour {
                    Text(Calendar.current.isDateInToday(h) ? "at \(Fmt.time(h))" : h.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, alignment: .trailing)
            Text(Insights.duration(row.coreSeconds)).font(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.trends.opacity(0.07) : .clear))
        .onHover { hover = $0 }
        .tip(ProcessGuide.note(for: (row.key as NSString).lastPathComponent).map { "\($0.headline). \($0.detail)" } ?? row.key)
    }
}

private struct TrendStats: View {
    let d: TrendsView.Data

    var body: some View {
        let load = d.sampled > 0 ? d.total / d.sampled * 100 / d.cores : 0
        HStack(spacing: 8) {
            StatTile(symbol: "clock.fill", color: Theme.trends, value: Insights.duration(d.sampled), label: "recorded")
            StatTile(symbol: "cpu.fill", color: Tab.overview.color, value: Insights.duration(d.total), label: "CPU time used")
            StatTile(symbol: "gauge.with.dots.needle.50percent", color: Theme.machineHeat(load), value: Fmt.pct(load), label: "average load")
            StatTile(symbol: "crown.fill", color: d.colors[d.rows.first?.key ?? ""] ?? Theme.other,
                     value: d.rows.first?.name ?? "none", label: "top user")
        }
    }
}

private struct TrendChart: View {
    let d: TrendsView.Data
    let byApp: Bool
    /// Drop the grey "Everything else" bars, so the named apps fill the scale.
    @AppStorage("trendsHideOther") private var hideOther = false

    private var bars: [TrendsView.Bar] { hideOther ? d.bars.filter { $0.key != "other" } : d.bars }
    private var domain: [String] { hideOther ? d.domain.filter { $0 != "other" } : d.domain }

    var body: some View {
        Card(title: d.range.barTitle, symbol: "chart.bar.fill", tint: Theme.trends,
             trailing: AnyView(HStack(spacing: 10) {
                 Text("% of whole Mac, stacked by \(byApp ? "app" : "process")").font(.caption2).foregroundStyle(.secondary)
                 Button { hideOther.toggle() } label: {
                     Label(hideOther ? "Show everything else" : "Hide everything else",
                           systemImage: hideOther ? "eye" : "eye.slash")
                         .font(.caption2.weight(.medium))
                         .padding(.horizontal, 7).padding(.vertical, 3)
                         .background(Capsule().fill(hideOther ? Theme.trends.opacity(0.15) : Color.primary.opacity(0.06)))
                 }
                 .buttonStyle(.plain)
                 .tip("Leave out the grey bar of all the smaller processes, so the named apps fill the chart")
             })) {
            if d.bars.isEmpty {
                Text("Nothing recorded yet. This fills in while System Sentinel runs.")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 140)
            } else {
                chart.frame(height: 150)
                Legend(items: domain.map { (d.name($0), d.colors[$0] ?? Theme.other) })
            }
        }
    }

    private var chart: some View {
        // Bars sit in the middle of their slot with a fixed width: the 5 and 10 minute bars
        // have no calendar unit for .ratio to measure against.
        let slots = max(d.end.timeIntervalSince(d.start) / d.barSeconds, 1)
        let width = max(2, 560 / slots * 0.78)
        return Chart(bars) { b in
            BarMark(x: .value("Time", b.start.addingTimeInterval(d.barSeconds / 2)), y: .value("CPU", b.value), width: .fixed(width))
                .foregroundStyle(by: .value("App", b.key))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(domain: domain, range: domain.map { d.colors[$0] ?? Theme.other })
        .chartLegend(.hidden)
        // End padding, so the last time label is not clipped at the edge.
        .chartXScale(domain: d.start...d.end, range: .plotDimension(endPadding: 14))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let x = v.as(Double.self) { Text("\(Int(x))%").font(.system(size: 9)) } }
            }
        }
        .chartXAxis {
            switch d.range {
            case .week:
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated)).font(.system(size: 9))
                }
            case .day:
                AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
                }
            case .sixHours:
                AxisMarks(values: .stride(by: .hour, count: 1)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9))
                }
            case .threeHours:
                AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9))
                }
            case .halfHour:
                AxisMarks(values: .stride(by: .minute, count: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9))
                }
            }
        }
    }
}

private struct HeaviestCard: View {
    let d: TrendsView.Data
    let byApp: Bool

    var body: some View {
        Card(title: "Heaviest users", symbol: "list.number", tint: Theme.trends,
             trailing: AnyView(Text("share of all CPU time").font(.caption2).foregroundStyle(.secondary))) {
            HStack(spacing: 8) {
                Text("").frame(width: 16)
                Text(byApp ? "App" : "Process").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
                Text("avg").frame(width: 48, alignment: .trailing)
                Text("peak").frame(width: 76, alignment: .trailing)
                Text("CPU time").frame(width: 60, alignment: .trailing)
            }
            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            ForEach(Array(d.rows.prefix(15).enumerated()), id: \.element.key) { i, row in
                UsageRow(rank: i + 1, row: row, share: d.total > 0 ? row.coreSeconds / d.total : 0,
                         color: d.colors[row.key] ?? Theme.other)
            }
        }
    }
}
