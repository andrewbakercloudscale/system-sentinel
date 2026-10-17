import Charts
import SentinelCore
import SwiftUI

/// Everything System Sentinel flagged or killed: counts, a week at a glance, then the log.
struct EventsView: View {
    @ObservedObject var model: Model

    struct DayCount: Identifiable {
        let day: Date
        let kind: HistoryEntry.Kind
        let count: Int
        var id: String { "\(kind.rawValue)@\(day.timeIntervalSince1970)" }
    }

    var body: some View {
        let now = Date()
        let cal = Calendar.current
        let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        let all = model.sentinel.history.entries
        let week = all.filter { $0.date >= weekStart }
        let counts = Dictionary(grouping: week, by: \.kind).mapValues(\.count)
        let perDay: [DayCount] = Dictionary(grouping: week) { Pair(day: cal.startOfDay(for: $0.date), kind: $0.kind) }
            .map { DayCount(day: $0.key.day, kind: $0.key.kind, count: $0.value.count) }
        let kinds = HistoryEntry.Kind.allCases

        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach([HistoryEntry.Kind.flagged, .killed, .autoKilled, .killFailed], id: \.self) { k in
                    StatTile(symbol: Self.symbol(k), color: Self.color(k), value: "\(counts[k] ?? 0)", label: Self.label(k).lowercased())
                }
            }
            WeeklyCard(report: model.weekly())
            if !model.impacts.isEmpty { ImpactsCard(impacts: model.impacts) }
            ExportCard(model: model)
            Card(title: "Last 7 days", symbol: "calendar", tint: Tab.events.color) {
                Chart(perDay) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Events", d.count), width: .ratio(0.6))
                        .foregroundStyle(by: .value("Kind", Self.label(d.kind)))
                        .cornerRadius(2)
                }
                .chartForegroundStyleScale(domain: kinds.map(Self.label), range: kinds.map(Self.color))
                .chartLegend(.hidden)
                .chartXScale(domain: weekStart...cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true).font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .frame(height: 90)
                Legend(items: kinds.map { (Self.label($0), Self.color($0)) })
            }
            Card(title: "Log", symbol: "list.bullet.rectangle", tint: Tab.events.color) {
                if all.isEmpty {
                    Text("Nothing flagged or killed yet. A process is flagged when it stays over \(Int(model.threshold))% for \(Model.duration(model.windowSeconds)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let byDay = Dictionary(grouping: all.suffix(60)) { cal.startOfDay(for: $0.date) }
                ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                    Text(Self.dayLabel(day)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                    ForEach(Array(byDay[day]!.reversed().enumerated()), id: \.offset) { _, e in
                        EventRow(entry: e)
                    }
                }
            }
        }
    }

    private struct Pair: Hashable {
        let day: Date
        let kind: HistoryEntry.Kind
    }

    static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    static func label(_ k: HistoryEntry.Kind) -> String {
        switch k {
        case .flagged: return "Flagged"
        case .killed: return "Killed"
        case .autoKilled: return "Auto-killed"
        case .killFailed: return "Kill failed"
        case .rateLimited: return "Held back"
        }
    }

    static func symbol(_ k: HistoryEntry.Kind) -> String {
        switch k {
        case .flagged: return "exclamationmark.triangle.fill"
        case .killed: return "xmark.octagon.fill"
        case .autoKilled: return "bolt.fill"
        case .killFailed: return "xmark.shield.fill"
        case .rateLimited: return "hand.raised.fill"
        }
    }

    static func color(_ k: HistoryEntry.Kind) -> Color {
        switch k {
        case .flagged: return Color(light: "#ea580c", dark: "#fb923c")
        case .killed: return Color(light: "#dc2626", dark: "#f87171")
        case .autoKilled: return Color(light: "#9333ea", dark: "#c084fc")
        case .killFailed: return Color(light: "#475569", dark: "#94a3b8")
        case .rateLimited: return Color(light: "#0d9488", dark: "#2dd4bf")
        }
    }
}

private struct EventRow: View {
    let entry: HistoryEntry

    var body: some View {
        let e = entry
        HStack(alignment: .top, spacing: 10) {
            Text(Fmt.time(e.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            SymbolTile(symbol: EventsView.symbol(e.kind), color: EventsView.color(e.kind), size: 22)
            IconView(icon: IconCache.shared.icon(for: ProcessSample(pid: e.pid, uid: 501, cpu: 0, path: e.path)), size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name).font(.callout.weight(.medium)).lineLimit(1)
                    Pill(text: EventsView.label(e.kind), color: EventsView.color(e.kind))
                }
                if let detail = Self.friendly(e.detail) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(Fmt.pct(e.cpu)).font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Theme.heat(e.cpu)))
        }
        .padding(.vertical, 2)
    }

    /// The engine's detail strings are Swift enum dumps; say them in English.
    static func friendly(_ d: String) -> String? {
        guard !d.isEmpty else { return nil }
        var s = d.replacingOccurrences(of: "as admin: ", with: "As admin: ")
        let map = [
            "terminated": "stopped cleanly", "forceKilled": "force killed after ignoring the polite stop",
            "alreadyGone": "had already exited",
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        if let r = s.range(of: #"failed\("(.*)"\)"#, options: .regularExpression) {
            let inner = s[r].dropFirst(8).dropLast(2)
            s.replaceSubrange(r, with: "failed: \(inner)")
        }
        if let r = s.range(of: #"refused\("(.*)"\)"#, options: .regularExpression) {
            let inner = s[r].dropFirst(9).dropLast(2)
            s.replaceSubrange(r, with: "refused: \(inner)")
        }
        return s
    }
}
