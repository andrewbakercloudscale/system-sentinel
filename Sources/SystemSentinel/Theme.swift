import AppKit
import SwiftUI

/// Colours, cards and the tab bar shared by every screen.
enum Theme {
    /// Categorical series colours, in a fixed, colour-blind-checked order. An app keeps its
    /// colour across refreshes (see `ColorBook`); an eighth series folds into Other.
    static let series: [Color] = zip(
        ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6"],
        ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9"]
    ).map { Color(light: $0, dark: $1) }

    static let other = Color(light: "#a3a29d", dark: "#6b6a66")

    static let accent = Color(light: "#5b4fd6", dark: "#8f86f0")

    static let heroGradient = LinearGradient(
        colors: [Color(light: "#4f46e5", dark: "#3b33b8"), Color(light: "#9333ea", dark: "#6d28b0")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let cardFill = Color(light: "#ffffff", dark: "#25252a").opacity(0.75)
    static let cardStroke = Color.primary.opacity(0.07)

    /// Status colour for a CPU figure: calm, elevated, high, critical.
    static func heat(_ cpu: Double) -> Color {
        cpu < 10 ? Color(light: "#16a34a", dark: "#22c55e")
            : cpu < 40 ? Color(light: "#ca8a04", dark: "#eab308")
            : cpu < 80 ? Color(light: "#ea580c", dark: "#f97316")
            : Color(light: "#dc2626", dark: "#ef4444")
    }

    /// Heat for a share of the whole machine (100 = every core).
    static func machineHeat(_ load: Double) -> Color {
        heat(load < 15 ? 0 : load < 40 ? 20 : load < 70 ? 50 : 100)
    }
}

/// Free function kept for the views written before `Theme`.
func heat(_ cpu: Double) -> Color { Theme.heat(cpu) }

extension Color {
    init(hex: String) {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255, opacity: 1)
    }

    /// A colour with its own light and dark step, not an automatic flip.
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// Keeps each app on the same colour while the set of top apps shifts, so a chart never
/// repaints Chrome orange because something else overtook it.
@MainActor
final class ColorBook {
    static let shared = ColorBook()
    private var slots: [String: Int] = [:]

    func colors(for keys: [String]) -> [String: Color] {
        var taken: Set<Int> = []
        var out: [String: Int] = [:]
        for k in keys {
            if let s = slots[k], !taken.contains(s) {
                out[k] = s
                taken.insert(s)
            }
        }
        for k in keys where out[k] == nil {
            guard let free = (0..<Theme.series.count).first(where: { !taken.contains($0) }) else { break }
            out[k] = free
            taken.insert(free)
        }
        for (k, s) in out { slots[k] = s }
        return out.mapValues { Theme.series[$0] }
    }
}

/// A rounded panel with a title row.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var tint: Color = Theme.accent
    var trailing: AnyView?
    /// Stretch to the height offered, so cards side by side line up.
    var fill = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
                    }
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke))
    }
}

/// A small coloured capsule label.
struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// A coloured square with a white symbol, for insights and stat tiles.
struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
    }
}

enum Tab: Int, CaseIterable, Identifiable {
    case overview, processes, trends, memory, storage, battery, checkup, events, rules, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .processes: return "Processes"
        case .trends: return "Trends"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .checkup: return "Checkup"
        case .battery: return "Energy"
        case .events: return "Events"
        case .rules: return "Rules"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .processes: return "list.bullet.rectangle.fill"
        case .trends: return "chart.bar.xaxis"
        case .memory: return "memorychip.fill"
        case .storage: return "internaldrive.fill"
        case .checkup: return "stethoscope"
        case .battery: return "bolt.batteryblock.fill"
        case .events: return "bell.badge.fill"
        case .rules: return "slider.horizontal.3"
        case .settings: return "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .overview: return Color(light: "#4f46e5", dark: "#818cf8")
        case .processes: return Color(light: "#2563eb", dark: "#60a5fa")
        case .trends: return Color(light: "#9333ea", dark: "#c084fc")
        case .memory: return Color(light: "#0891b2", dark: "#22d3ee")
        case .storage: return Color(light: "#b45309", dark: "#fbbf24")
        case .checkup: return Color(light: "#db2777", dark: "#f472b6")
        case .battery: return Color(light: "#16a34a", dark: "#4ade80")
        case .events: return Color(light: "#ea580c", dark: "#fb923c")
        case .rules: return Color(light: "#0d9488", dark: "#2dd4bf")
        case .settings: return Color(light: "#64748b", dark: "#94a3b8")
        }
    }
}

/// Icon-over-label tabs, each with its own colour; the selected one fills.
struct TabBar: View {
    @Binding var selection: Tab
    var badges: [Tab: Int] = [:]
    @State private var hover: Tab?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                let on = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 14, weight: .semibold))
                        Text(tab.title).font(.caption.weight(on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Color.white : tab.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(on ? AnyShapeStyle(LinearGradient(colors: [tab.color, tab.color.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                                     : AnyShapeStyle(tab.color.opacity(hover == tab ? 0.14 : 0.06)))
                    )
                    .overlay(alignment: .topTrailing) {
                        if let n = badges[tab], n > 0 {
                            Text("\(n)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.red))
                                .offset(x: -6, y: 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? tab : (hover == tab ? nil : hover) }
                .help(tab.title)
            }
        }
    }
}

enum Fmt {
    static func pct(_ v: Double) -> String { v >= 10 || v == 0 ? "\(Int(v.rounded()))%" : String(format: "%.1f%%", v) }

    static func memory(_ kb: Int) -> String {
        let mb = Double(kb) / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB"
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}
