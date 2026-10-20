import AppKit
import Charts
import SentinelCore
import SwiftUI

/// Battery and energy: what the Mac draws, which apps cost the most, what keeps it awake,
/// and how the battery is wearing.
struct BatteryView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 10) {
            if let b = model.battery, b.present {
                BatteryHero(battery: b, eta: model.batteryETA())
                PowerChart(model: model)
            } else {
                Card(title: "No battery", symbol: "powerplug.fill", tint: Tab.battery.color) {
                    Text("This Mac runs on mains power only, so there is no battery or power draw to show. Energy use by app and sleep blockers still apply.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            EnergyCard(model: model)
            SleepBlockersCard(model: model)
            SleepCard(report: model.sleepReport)
            DisplaysCard(model: model)
            NetworkDiskCard(model: model)
            if let b = model.battery, b.present {
                HealthCard(battery: b)
                HealthTrendCard(model: model)
            }
            TodayCard(lines: model.daySummary())
        }
    }
}

// MARK: Hero

private struct BatteryHero: View {
    let battery: BatteryStatus
    let eta: BatteryETA?

    var body: some View {
        let b = battery
        HStack(alignment: .center, spacing: 16) {
            Gauge(value: Double(b.percent), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(b.percent)%").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Gradient(colors: [.red, .orange, .yellow, .green]))
            .scaleEffect(1.35)
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.title3.weight(.bold)).foregroundStyle(.white)
                Text(subline).font(.callout).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 6) {
                    if b.lowPowerMode { chip("Low Power", "leaf.fill") }
                    if let a = b.adapterWatts, !b.onBattery { chip("\(a) W charger", "powerplug.fill") }
                    if let t = b.temperature { chip(String(format: "%.0f°C", t), "thermometer.medium") }
                }
            }
            Spacer()
            VStack(spacing: 2) {
                Text(b.watts.map { String(format: "%.1f", $0) } ?? "–")
                    .font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit()
                Text("watts now").font(.caption2).foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(
            LinearGradient(colors: [Color(hex: "#15803d"), Color(hex: "#0f766e")], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private var headline: String {
        let b = battery
        if b.onBattery {
            return eta.map { "Empty in \(Insights.duration(Double($0.minutes) * 60))" } ?? "On battery"
        }
        if b.charging { return b.minutesToFull.map { "Full in \(Insights.duration(Double($0) * 60))" } ?? "Charging" }
        return b.fullyCharged || b.percent >= 100 ? "Charged, on power" : "On power, not charging"
    }

    private var subline: String {
        let b = battery
        if b.onBattery, let e = eta { return "Around \(BatteryETABanner.clock(e.minutes)), \(BatteryETABanner.basis(e))" }
        if b.onBattery { return "Running on battery" }
        if !b.charging && b.percent < 100 { return "macOS is holding the charge to protect the battery" }
        return "Plugged in"
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.18)))
    }
}

// MARK: Power chart

struct PowerChart: View {
    @ObservedObject var model: Model
    @AppStorage("powerRange") private var range = "6 hours"

    struct Bar: Identifiable {
        let start: Date
        let watts: Double
        let onBattery: Bool
        var id: Date { start }
    }

    static let ranges: [(String, TimeInterval, Int)] = [("1 hour", 3600, 60), ("6 hours", 6 * 3600, 600),
                                                       ("24 hours", 86_400, 1800), ("7 days", 7 * 86_400, 4 * 3600)]

    var body: some View {
        let (_, span, bucket) = Self.ranges.first { $0.0 == range } ?? Self.ranges[1]
        let now = Date()
        let points = model.powerHistory.since(now.addingTimeInterval(-span))
        let bars = Self.bars(points, bucket: bucket)
        let summary = BatterySummary.from(points)
        Card(title: "Power draw", symbol: "bolt.fill", tint: Tab.battery.color,
             trailing: AnyView(ChipPicker(options: Self.ranges.map(\.0), selection: $range, color: Tab.battery.color))) {
            BatteryETABanner(model: model)
            HStack(spacing: 8) {
                StatTile(symbol: "bolt.fill", color: Tab.battery.color, value: summary.averageWatts.map { String(format: "%.1f W", $0) } ?? "–", label: "average")
                StatTile(symbol: "arrow.up.to.line", color: Theme.heat(80), value: summary.peakWatts.map { String(format: "%.0f W", $0) } ?? "–", label: "peak")
                StatTile(symbol: "battery.50percent", color: Color(hex: "#d97706"), value: Insights.duration(Double(summary.batteryMinutes) * 60), label: "on battery")
                StatTile(symbol: "chart.line.downtrend.xyaxis", color: Theme.trends, value: summary.drainPerHour.map { String(format: "%.0f%%/h", $0) } ?? "–", label: "drain on battery")
            }
            if bars.isEmpty {
                Text("Collecting: the chart fills in as System Sentinel runs. Readings are kept for 7 days.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart(bars) { b in
                    BarMark(x: .value("Time", b.start, unit: bucket >= 3600 ? .hour : .minute),
                            y: .value("Watts", b.watts), width: .ratio(0.85))
                        .foregroundStyle(by: .value("Source", b.onBattery ? "On battery" : "Plugged in"))
                        .cornerRadius(2)
                }
                .chartForegroundStyleScale(["On battery": Color(hex: "#d97706"), "Plugged in": Tab.battery.color])
                .chartXScale(domain: now.addingTimeInterval(-span)...now)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let w = v.as(Double.self) { Text("\(Int(w)) W") } }.font(.system(size: 9))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: span > 86_400 ? .dateTime.weekday(.abbreviated) : .dateTime.hour().minute()).font(.system(size: 9))
                    }
                }
                .chartLegend(position: .bottom, spacing: 4)
                .frame(height: 120)
            }
            Text("The whole Mac's draw, screen included. A MacBook idles at 2 to 5 W; video calls and builds reach 20 to 40 W.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RightNowPower(model: model)
        }
    }

    static func bars(_ points: [PowerHistory.Point], bucket: Int) -> [Bar] {
        let groups: [Int: [PowerHistory.Point]] = Dictionary(grouping: points) { (p: PowerHistory.Point) -> Int in p.t / bucket * bucket }
        var out: [Bar] = []
        for (start, p) in groups {
            let watts = p.reduce(0.0) { $0 + $1.watts } / Double(p.count)
            let battery = p.filter(\.onBattery).count * 2 > p.count
            out.append(Bar(start: Date(timeIntervalSince1970: Double(start)), watts: watts, onBattery: battery))
        }
        return out.sorted { $0.start < $1.start }
    }
}

// MARK: Time left

/// When the battery runs out, big, with how it was worked out and the other estimates.
struct BatteryETABanner: View {
    @ObservedObject var model: Model

    var body: some View {
        if let b = model.battery, b.present {
            if let e = model.batteryETA() {
                let urgent = e.minutes < 60
                let color = urgent ? Theme.heat(100) : e.minutes < 180 ? Color(hex: "#d97706") : Tab.battery.color
                HStack(alignment: .center, spacing: 12) {
                    SymbolTile(symbol: urgent ? "battery.0percent" : "battery.75percent", color: color, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Battery empty in \(Insights.duration(Double(e.minutes) * 60))")
                            .font(.title2.weight(.bold)).foregroundStyle(color)
                        Text("Around \(Self.clock(e.minutes)) · \(b.percent)% left · \(Self.basis(e))")
                            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Text(others(e)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
            } else if b.onBattery {
                Text("On battery: the time left appears once there is a reading.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    SymbolTile(symbol: b.charging ? "battery.100percent.bolt" : "powerplug.fill", color: Tab.battery.color, size: 32)
                    Text(b.charging ? (b.minutesToFull.map { "Plugged in: full in \(Insights.duration(Double($0) * 60))" } ?? "Plugged in, charging")
                                    : "Plugged in at \(b.percent)%: no battery countdown while on power")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tab.battery.color.opacity(0.08)))
            }
        }
    }

    static func clock(_ minutes: Int) -> String {
        let t = Date().addingTimeInterval(Double(minutes) * 60)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(t) ? "HH:mm" : Calendar.current.isDateInTomorrow(t) ? "'tomorrow' HH:mm" : "EEE HH:mm"
        return f.string(from: t)
    }

    static func basis(_ e: BatteryETA) -> String {
        switch e.basis {
        case .recentPace: return "at your last hour's pace"
        case .macOS: return "macOS's estimate"
        case .currentDraw: return "at the current draw"
        }
    }

    private func others(_ e: BatteryETA) -> String {
        var parts: [String] = []
        if e.basis != .currentDraw, let c = e.currentDraw { parts.append("at this moment's draw \(Insights.duration(Double(c) * 60))") }
        if e.basis != .macOS, let m = e.macOS { parts.append("macOS says \(Insights.duration(Double(m) * 60))") }
        let tail = parts.isEmpty ? "" : "Other estimates: " + parts.joined(separator: ", ") + ". "
        return tail + "The last hour's pace is steadiest: the draw changes every second, and macOS's figure lags after busy spells."
    }
}

// MARK: Right now

/// The apps drawing the most power right now, live, under the chart.
private struct RightNowPower: View {
    @ObservedObject var model: Model

    var body: some View {
        let rows = Array(model.energy.prefix(5))
        let total = model.energy.reduce(0) { $0 + $1.power }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Tab.battery.color)
                Text(model.battery?.watts.map { String(format: "Right now: %.1f W. Drawing the most:", $0) } ?? "Drawing the most right now:")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let at = model.energyAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("updated \(max(0, Int(ctx.date.timeIntervalSince(at))))s ago · every 15 s")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if rows.isEmpty {
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { r in
                let share = total > 0 ? r.power / total : 0
                let sample = r.pids.first.flatMap(model.sample(pid:))
                HStack(spacing: 8) {
                    IconView(icon: IconCache.shared.icon(for: sample ?? ProcessSample(pid: 0, uid: 501, cpu: 0, path: r.key)), size: 20)
                    HStack(spacing: 6) {
                        Text(r.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        if r.pids.count > 1 { Text("\(r.pids.count) processes").font(.caption).foregroundStyle(.secondary).fixedSize() }
                    }
                    .frame(width: 230, alignment: .leading)
                    ShareBar(share: share, color: Tab.battery.color)
                    Spacer(minLength: 6)
                    Text(watts(share) ?? String(format: "impact %.0f", r.power))
                        .font(.callout.weight(.semibold)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        .tip(String(format: "Energy Impact %.1f: %.0f%% of everything drawing power now", r.power, share * 100))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Tab.battery.color.opacity(0.07)))
    }

    private func watts(_ share: Double) -> String? {
        guard let w = model.battery?.watts else { return nil }
        let appW = BatteryMath.appWatts(share: share, totalWatts: w)
        return appW < 0.1 ? "<0.1 W" : String(format: "~%.1f W", appW)
    }
}

// MARK: Energy by app

private struct EnergyCard: View {
    @ObservedObject var model: Model
    @AppStorage("energyRange") private var range = "Now"

    var body: some View {
        Card(title: "Energy by app", symbol: "flame.fill", tint: Tab.battery.color,
             trailing: AnyView(ChipPicker(options: ["Now", "24 hours", "7 days"], selection: $range, color: Tab.battery.color))) {
            if range == "Now" { now } else { history(hours: range == "7 days" ? 24 * 7 : 24) }
            Text("Watts and watt-hours are estimates: the Mac's measured draw above idle, split by each app's Energy Impact (Activity Monitor's unitless score for CPU, wakeups, graphics and disk). Wakeups are times a second the app interrupts the chip's rest.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var now: some View {
        let rows = Array(model.energy.prefix(10))
        let total = model.energy.reduce(0) { $0 + $1.power }
        if rows.isEmpty {
            Text("Reading energy use (refreshed every 30 seconds)…").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(rows) { r in
            let share = total > 0 ? r.power / total : 0
            let sample = r.pids.first.flatMap(model.sample(pid:))
            HStack(spacing: 10) {
                IconView(icon: IconCache.shared.icon(for: sample ?? ProcessSample(pid: 0, uid: 501, cpu: 0, path: r.key)), size: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(r.name).font(.callout.weight(.medium)).lineLimit(1)
                        if r.pids.count > 1 { Text("\(r.pids.count) processes").font(.caption2).foregroundStyle(.secondary) }
                        if r.name.contains("Chrome"), ChromeTabs.isRunning { ChromeTabsButton() }
                    }
                    ShareBar(share: share, color: Tab.battery.color)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    if let w = watts(share) {
                        Text(w).font(.callout.weight(.semibold)).monospacedDigit()
                        Text(minutes(share) ?? String(format: "impact %.1f", r.power))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(String(format: "%.1f", r.power)).font(.callout.weight(.semibold)).monospacedDigit()
                        Text("energy impact").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, alignment: .trailing)
                .tip(String(format: "Estimated power draw. Energy Impact %.1f (Activity Monitor's unitless score).", r.power))
                Text("\(Int(r.wakeups))/s").font(.caption).monospacedDigit()
                    .foregroundStyle(r.wakeups >= 150 ? Theme.heat(90) : .secondary)
                    .frame(width: 52, alignment: .trailing)
                    .tip("Idle wakeups per second")
            }
        }
    }

    /// The app's estimated draw, "~1.2 W"; nil when the Mac reports no watts.
    private func watts(_ share: Double) -> String? {
        guard let w = model.battery?.watts else { return nil }
        let appW = BatteryMath.appWatts(share: share, totalWatts: w)
        return appW < 0.1 ? "<0.1 W" : String(format: "~%.1f W", appW)
    }

    /// On battery, how many minutes of each hour's charge the app costs.
    private func minutes(_ share: Double) -> String? {
        guard let b = model.battery, b.onBattery, let w = b.watts else { return nil }
        let appW = BatteryMath.appWatts(share: share, totalWatts: w)
        return "\(Int(BatteryMath.minutesPerHour(appWatts: appW, watts: w))) min/h of battery"
    }

    /// "~4.2 Wh" (or "~120 mWh"): the app's share of the energy drawn over the period.
    private func energy(_ wh: Double) -> String {
        wh < 1 ? String(format: "~%.0f mWh", wh * 1000) : String(format: "~%.1f Wh", wh)
    }

    @ViewBuilder
    private func history(hours: Int) -> some View {
        let rows = Array(model.energySummaries(hours: hours).prefix(10))
        let total = model.energySummaries(hours: hours).reduce(0) { $0 + $1.coreSeconds }
        let drawn = BatteryMath.appEnergy(model.powerHistory.since(Date().addingTimeInterval(-Double(hours) * 3600)))
        if rows.isEmpty {
            Text("No energy history yet: it builds up as System Sentinel runs.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(rows, id: \.key) { r in
            HStack(spacing: 10) {
                IconView(icon: IconCache.shared.icon(for: ProcessSample(pid: 0, uid: 501, cpu: 0, path: r.key)), size: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.name).font(.callout.weight(.medium)).lineLimit(1)
                    ShareBar(share: total > 0 ? r.coreSeconds / total : 0, color: Tab.battery.color)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    if drawn > 0, total > 0 {
                        Text(energy(drawn * r.coreSeconds / total)).font(.callout.weight(.semibold)).monospacedDigit()
                        Text(String(format: "impact %.1f", r.average)).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(String(format: "%.1f", r.average)).font(.callout.weight(.semibold)).monospacedDigit()
                        Text("average impact").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, alignment: .trailing)
                .tip(String(format: "Estimated energy used over the period, from its share of Energy Impact and the Mac's measured draw. Average Energy Impact %.1f (Activity Monitor's unitless score).", r.average))
                Text(Fmt.pct(total > 0 ? r.coreSeconds / total * 100 : 0)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                    .tip("Share of all energy over the period")
            }
        }
    }
}

struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.gradient).frame(width: max(g.size.width * min(share, 1), 2))
            }
        }
        .frame(height: 5)
    }
}

// MARK: Sleep blockers

private struct SleepBlockersCard: View {
    @ObservedObject var model: Model

    var body: some View {
        Card(title: "Keeping your Mac awake", symbol: "moon.zzz.fill", tint: Color(hex: "#6366f1")) {
            if model.blockers.isEmpty {
                Text("Nothing is stopping your Mac from sleeping.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.blockers) { b in
                let sample = model.sample(pid: b.pid)
                HStack(spacing: 10) {
                    Image(systemName: b.kind == .display ? "display" : "moon.zzz")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: "#6366f1")).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(b.name).font(.callout.weight(.medium))
                            if let who = b.onBehalfOf {
                                Text("for \(who)\(b.onBehalfOfPID.map { " (pid \($0))" } ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(detail(b)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let since = b.since {
                        let held = Date().timeIntervalSince(since)
                        Pill(text: held >= 86_400 ? "\(Int(held / 86_400))d \(Int(held.truncatingRemainder(dividingBy: 86_400) / 3600))h" : Model.duration(held),
                             symbol: "clock", color: held >= 3600 ? Theme.heat(85) : .secondary)
                    }
                    if let s = sample, s.name == "caffeinate" {
                        if model.killing.contains(s.pid) {
                            BusyButton(title: "Releasing…")
                        } else {
                            sleepButton("Let it sleep") { model.confirmDecaffeinate([s]) }
                                .tip("Stops this caffeinate only. \(b.onBehalfOf.map { "\($0) keeps running." } ?? "")")
                        }
                    } else if let s = sample, Safety.canKillManually(s) {
                        KillButton(model: model, sample: s)
                    }
                }
            }
            let caffeinates = model.blockers.compactMap { model.sample(pid: $0.pid) }.filter { $0.name == "caffeinate" }
            if caffeinates.count > 1 {
                HStack {
                    Spacer()
                    if caffeinates.contains(where: { model.killing.contains($0.pid) }) {
                        BusyButton(title: "Releasing…")
                    } else {
                        sleepButton("Let the Mac sleep: stop all \(caffeinates.count) caffeinates", filled: true) { model.confirmDecaffeinate(caffeinates) }
                            .tip("Stop every caffeinate holding the Mac awake. What they were started for keeps running. Asks first")
                    }
                }
            }
            if !model.blockers.isEmpty {
                Text("Let it sleep stops only the caffeinate, which exists just to keep the Mac awake; the tool it was started for carries on. Apps (video calls, players, downloads) release their hold when they finish.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sleepButton(_ title: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        let tint = Color(hex: "#6366f1")
        return Button(action: action) {
            Label(title, systemImage: "moon.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(filled ? .white : tint)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.13))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ b: SleepBlocker) -> String {
        var parts = [b.kind.meaning]
        if b.reason != b.name, !b.reason.isEmpty { parts.append(b.reason) }
        if let t = b.timeout { parts.append("ends after \(Model.duration(Double(t)))") }
        parts.append("pid \(b.pid)")
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: Health

private struct HealthCard: View {
    let battery: BatteryStatus

    var body: some View {
        let b = battery
        Card(title: "Battery health", symbol: "heart.fill", tint: Color(hex: "#e11d48")) {
            HStack(spacing: 8) {
                StatTile(symbol: "battery.100percent", color: healthColor,
                         value: (b.appleMaxPercent.map(Double.init) ?? b.health).map { "\(Int($0))%" } ?? "–", label: "maximum capacity")
                StatTile(symbol: "arrow.triangle.2.circlepath", color: Tab.processes.color,
                         value: b.cycleCount.map { c in b.designCycles.map { "\(c) / \($0)" } ?? "\(c)" } ?? "–", label: "charge cycles")
                StatTile(symbol: b.condition == "Normal" || b.condition == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                         color: b.condition == "Normal" || b.condition == nil ? Tab.battery.color : Theme.heat(90),
                         value: b.condition ?? "Normal", label: "macOS says")
            }
            if let m = b.maxCapacity, let d = b.designCapacity {
                Text(b.appleMaxPercent != nil
                     ? "Holds \(m) mAh of the \(d) mAh it held new. Maximum capacity is the figure System Settings shows (Battery > Battery Health); Apple's calculation runs a few points above the raw charge."
                     : "Holds \(m) mAh of the \(d) mAh it held new.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(advice, id: \.self) { a in
                    Label(a, systemImage: "lightbulb.fill").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var healthColor: Color {
        guard let h = battery.health else { return .secondary }
        return h >= 90 ? Tab.battery.color : h >= 80 ? Color(hex: "#d97706") : Theme.heat(100)
    }

    private var advice: [String] {
        var out = ["Keep Optimised Battery Charging on (System Settings > Battery > Battery Health): it holds the charge at 80% when the Mac is usually plugged in."]
        if let t = battery.temperature, t >= 35 { out.append("The battery is warm. Heat wears batteries fastest: keep vents clear and avoid charging in a hot place.") }
        if let h = battery.health, h < 80 { out.append("Under 80% Apple considers the battery consumed; it can be replaced under warranty or AppleCare.") }
        if let c = battery.cycleCount, let d = battery.designCycles, c * 10 >= d * 8 { out.append("\(c) of \(d) design cycles used: expect runtime to fall from here.") }
        return out
    }
}

// MARK: Today

private struct TodayCard: View {
    let lines: [String]

    var body: some View {
        Card(title: "Today in brief", symbol: "text.quote", tint: Theme.trends) {
            if lines.isEmpty {
                Text("A summary appears after about ten minutes of recording.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(lines, id: \.self) { l in
                Label(l, systemImage: "circle.fill").labelStyle(BulletLabel()).font(.callout)
            }
        }
    }

    struct BulletLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.trends).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                configuration.title.fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Cores (Overview)

/// Each core's load, efficiency cores then performance cores.
struct CoresCard: View {
    @ObservedObject var model: Model
    /// The core clicked on; clicking it again, or the other kind, changes or closes the list.
    @State private var selected: Int?

    var body: some View {
        if let load = model.coreLoad {
            Card(title: "Cores", symbol: "cpu", tint: Tab.overview.color,
                 trailing: AnyView(HStack(spacing: 10) {
                     if let e = load.efficiencyAverage { avg("Efficiency", e, Self.eColor) }
                     if let p = load.performanceAverage { avg("Performance", p, Self.pColor) }
                 })) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(load.perCore.enumerated()), id: \.offset) { i, v in
                        let eff = i < load.efficiencyCount
                        VStack(spacing: 3) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
                                RoundedRectangle(cornerRadius: 3).fill((eff ? Self.eColor : Self.pColor).gradient)
                                    .frame(height: max(36 * v / 100, 1))
                            }
                            .frame(height: 36)
                            Text(eff ? "E" : "P").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .opacity(selected.map { ($0 < load.efficiencyCount) == eff ? 1 : 0.35 } ?? 1)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = selected == i ? nil : i }
                        .tip("\(eff ? "Efficiency" : "Performance") core \(i): \(Int(v))% busy. Click for the apps on this kind of core.")
                    }
                }
                if let h = selected, h < load.perCore.count {
                    clusterList(efficiency: h < load.efficiencyCount, core: h, busy: load.perCore[h], load: load)
                } else {
                    Label("Click a core to see which apps are running on that kind of core.", systemImage: "cursorarrow.click")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(caption(load)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .tip("Which app is on which core is not something macOS reports: each app's threads hop between cores many times a second. Background-priority work (Spotlight, Photos, backups, updates) is kept on the E cores; what you are using goes to the P cores. The Processes tab shows which apps are busy.")
            }
        }
    }

    private func clusterList(efficiency eff: Bool, core: Int, busy: Double, load: CoreLoad) -> some View {
        let apps = eff ? model.clusterApps.efficiency : model.clusterApps.performance
        let count = eff ? load.efficiencyCount : load.perCore.count - load.efficiencyCount
        let color = eff ? Self.eColor : Self.pColor
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(eff ? "Efficiency" : "Performance") core \(core) is \(Int(busy))% busy. Running on the \(count) \(eff ? "efficiency" : "performance") cores now:")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button { selected = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).tip("Close")
            }
            if apps.isEmpty {
                Text("Nothing measurable in the last few seconds.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(apps) { a in
                HStack(spacing: 8) {
                    IconView(icon: IconCache.shared.icon(for: a.sample), size: 18)
                    Text(a.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(String(format: a.cpu >= 10 ? "%.0f%%" : "%.1f%%", a.cpu)).font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(color)
                }
            }
            Text("macOS reports per app how much ran on each kind of core, not on which single core: threads move between the \(count) many times a second. 100% is one full core.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }

    static let eColor = Color(light: "#0891b2", dark: "#22d3ee")
    static let pColor = Color(light: "#c2410c", dark: "#fb923c")

    private func avg(_ label: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(label) \(Int(v))%").font(.caption2.weight(.semibold)).monospacedDigit()
        }
    }

    private func caption(_ l: CoreLoad) -> String {
        guard l.efficiencyCount > 0, let p = l.performanceAverage, let e = l.efficiencyAverage else {
            return "Load on each core over the last 5 seconds."
        }
        if p >= 50 { return "The performance cores are busy: that is heavy foreground work, and where most of the power goes." }
        if e >= 50, p < 25 { return "Mostly efficiency cores: background work, which macOS runs cheaply." }
        return "macOS puts background work on the efficiency cores (E) and demanding work on the performance cores (P), which draw several times the power. Apps hop between cores many times a second, so apps are shown per kind of core."
    }
}

// MARK: Background items (Rules)

struct BackgroundItemsCard: View {
    @ObservedObject var model: Model
    @State private var showAll = false

    var body: some View {
        let running = Dictionary(model.sentinel.latest.map { ($0.path, $0) }, uniquingKeysWith: { a, b in a.cpu >= b.cpu ? a : b })
        let usage = Dictionary(model.sentinel.dailyUsage.summaries(at: Date()).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let items = model.backgroundItems.sorted { a, b in
            let x = usage[a.processPath ?? ""]?.coreSeconds ?? 0, y = usage[b.processPath ?? ""]?.coreSeconds ?? 0
            return x != y ? x > y : a.label.lowercased() < b.label.lowercased()
        }
        let shown = showAll ? items : Array(items.prefix(8))
        Card(title: "Starts by itself", symbol: "power.circle.fill", tint: Theme.rules,
             trailing: AnyView(FooterButton(title: "Login Items", symbol: "gearshape", color: Theme.rules) {
                 NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
             })) {
            Text("Launch agents and daemons installed by apps. They run in the background, often at login and around the clock, and are a common source of battery drain. Remove the ones you do not want with the bin, or turn them off in System Settings > General > Login Items & Extensions > Allow in the Background.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if items.isEmpty {
                Text("None found.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown) { item in
                let live = item.processPath.flatMap { running[$0] }
                let day = item.processPath.flatMap { usage[$0] }
                HStack(spacing: 10) {
                    IconView(icon: IconCache.shared.icon(for: ProcessSample(pid: 0, uid: 501, cpu: 0, path: item.program ?? item.plist)), size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(item.vendor).font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Pill(text: scope(item.scope), color: item.scope == .system ? Theme.heat(80) : Theme.rules)
                            if item.runAtLoad { Pill(text: "at login", color: .secondary) }
                            if item.keepAlive { Pill(text: "always on", color: .secondary) }
                            if let i = item.interval { Pill(text: "every \(Model.duration(Double(i)))", color: .secondary) }
                            if item.disabled { Pill(text: "disabled", color: .secondary) }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(live.map { "running · \(Fmt.pct($0.cpu))" } ?? (item.processPath == nil ? "script" : "not running"))
                            .font(.caption.weight(live == nil ? .regular : .semibold))
                            .foregroundStyle(live == nil ? .secondary : .primary)
                        if let d = day { Text("24 h avg \(Fmt.pct(d.average))").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plist)]) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .tip("Reveal \(item.plist) in Finder")
                    Button { model.confirmRemove(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .tip("Stop it and move it to the Trash")
                }
            }
            if items.count > 8 {
                Button(showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }
                    .tip(showAll ? "Show only the top few" : "Show every one")
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private func scope(_ s: BackgroundItem.Scope) -> String {
        switch s {
        case .user: return "you"
        case .allUsers: return "all users"
        case .system: return "system, root"
        }
    }
}

// MARK: Weekly report (Events)

struct WeeklyCard: View {
    let report: WeeklyReport

    var body: some View {
        Card(title: "Your week", symbol: "calendar.badge.clock", tint: Tab.events.color) {
            if report.hoursWatched < 1 {
                Text("The weekly report fills in after a few hours of recording.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    StatTile(symbol: "cpu", color: Tab.overview.color, value: String(format: "%.1f", report.coreHours), label: "core-hours used")
                    StatTile(symbol: "eye.fill", color: Theme.trends, value: String(format: "%.0f h", report.hoursWatched), label: "watched")
                    StatTile(symbol: "battery.50percent", color: Color(hex: "#d97706"), value: String(format: "%.1f h", report.batteryHours), label: "on battery")
                    StatTile(symbol: "bolt.fill", color: Tab.battery.color, value: report.averageWatts.map { String(format: "%.1f W", $0) } ?? "–", label: "average draw")
                }
                ForEach(Array(report.apps.enumerated()), id: \.offset) { i, a in
                    HStack {
                        Text("\(i + 1).").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
                        Text(a.name).font(.callout).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f core-h", a.coreHours)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(Fmt.pct(a.share)).font(.caption.weight(.semibold)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                if let d = report.busiestDay {
                    Text("Busiest day: \(d.formatted(.dateTime.weekday(.wide))), \(String(format: "%.1f", report.busiestDayCoreHours)) core-hours. \(report.flagged) flagged, \(report.killed) killed this week.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
