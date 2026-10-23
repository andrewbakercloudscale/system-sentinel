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
                CleanUp(model: model, memory: m)
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
    /// The swap bar clicked, to show who moved in or out of RAM then.
    @State private var picked: Date?

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
                                                       ("24 hours", 86_400, 900), ("7 days", 7 * 86_400, 3600),
                                                       ("14 days", 14 * 86_400, 3 * 3600), ("28 days", 28 * 86_400, 6 * 3600)]

    var body: some View {
        let offered = Self.ranges.filter { $0.1 <= Double(model.retentionDays) * 86_400 }
        let (_, span, bucket) = offered.first { $0.0 == range } ?? offered[1]
        let now = Date()
        let points = model.memoryHistory.since(now.addingTimeInterval(-span))
        let buckets = Self.buckets(points, size: bucket)
        let s = MemoryAnalysis.summary(points)
        let total = Double(model.memory?.total ?? 0) / 1_073_741_824
        Card(title: "Memory and swap over time", symbol: "chart.xyaxis.line", tint: Tab.memory.color,
             trailing: AnyView(ChipPicker(options: offered.map(\.0), selection: $range, color: Tab.memory.color))) {
            HStack(spacing: 8) {
                StatTile(symbol: "externaldrive.fill", color: Color(hex: "#d97706"), value: gb(s.peakSwap),
                         label: s.peakSwapAt.map { "peak swap, \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" } ?? "peak swap")
                StatTile(symbol: "memorychip", color: Tab.memory.color, value: gb(s.peakUsed), label: "peak in use")
                StatTile(symbol: "gauge.with.dots.needle.67percent", color: s.warningMinutes + s.criticalMinutes > 0 ? Theme.heat(80) : Tab.battery.color,
                         value: Insights.duration(Double(s.warningMinutes + s.criticalMinutes) * 60), label: "under pressure")
            }
            if buckets.count < 2 {
                Text("Collecting: the timeline fills in as System Sentinel runs. Readings are kept for \(model.retentionDays) days.")
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
                        AxisValueLabel(format: span > 7 * 86_400 ? .dateTime.day().month(.abbreviated) : span > 86_400 ? .dateTime.weekday(.abbreviated) : .dateTime.hour().minute()).font(.system(size: 9))
                    }
                }
                .frame(height: 140)
                HStack(spacing: 12) {
                    legend(Tab.memory.color, "In use")
                    legend(Color(hex: "#d97706"), "Swap on disk")
                    legend(Color(hex: "#d97706").opacity(0.35), "Under pressure")
                }

                Text("SWAP ACTIVITY").sectionLabel().padding(.top, 4)
                Chart {
                    if let picked {
                        RectangleMark(xStart: .value("Start", picked), xEnd: .value("End", picked.addingTimeInterval(Double(bucket))))
                            .foregroundStyle(Color.primary.opacity(0.1))
                    }
                    ForEach(buckets) { b in
                        BarMark(x: .value("Time", b.start, unit: unit), y: .value("MB/s", b.swapOut), width: .ratio(0.8))
                            .foregroundStyle(by: .value("Direction", "Written to swap"))
                        BarMark(x: .value("Time", b.start, unit: unit), y: .value("MB/s", -b.swapIn), width: .ratio(0.8))
                            .foregroundStyle(by: .value("Direction", "Read back from swap"))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { g in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { loc in
                                guard let plot = proxy.plotFrame else { return }
                                let x = loc.x - g[plot].origin.x
                                guard let d: Date = proxy.value(atX: x) else { return }
                                let start = Date(timeIntervalSince1970: Double(Int(d.timeIntervalSince1970) / bucket * bucket))
                                picked = picked == start ? nil : start
                            }
                            .onContinuousHover { phase in
                                if case .active = phase { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                    }
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
                if let picked {
                    SwapMoment(start: picked, size: bucket, bucket: buckets.first { $0.start == picked },
                               moved: MemoryAnalysis.moved(points, from: Int(picked.timeIntervalSince1970),
                                                           to: Int(picked.timeIntervalSince1970) + bucket)) { self.picked = nil }
                }
            }
            Text("Swap that sits still is harmless. Bars below the line are memory read back from disk: that is the part that makes a Mac feel slow. Click a bar to see which apps moved in or out of RAM then.")
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

/// Who moved out of RAM, or back in, around a clicked swap bar.
private struct SwapMoment: View {
    let start: Date
    let size: Int
    let bucket: MemoryTimeline.Bucket?
    let moved: [MemoryAnalysis.Moved]
    let close: () -> Void

    var body: some View {
        let end = start.addingTimeInterval(Double(size))
        let fmt: Date.FormatStyle = size >= 3600 ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute()
        let out = moved.filter { $0.delta > 0 }, back = moved.filter { $0.delta < 0 }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(start.formatted(fmt)) to \(end.formatted(.dateTime.hour().minute()))").font(.callout.weight(.semibold))
                if let b = bucket {
                    Text(String(format: "%.1f MB/s written, %.1f MB/s read back", b.swapOut, b.swapIn))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            if moved.isEmpty {
                Text("None of the largest apps moved 64 MB or more in or out of RAM then. Smaller apps and macOS itself are not tracked per minute.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !out.isEmpty { group("Pushed out of RAM", symbol: "arrow.down.to.line", color: Color(hex: "#d97706"), out) }
            if !back.isEmpty { group("Back into RAM, or quit", symbol: "arrow.up.to.line", color: Theme.heat(100), back) }
            if !moved.isEmpty {
                Text("macOS counts swap for the whole Mac only, so this is each app's memory outside RAM: compressed and swapped together.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }

    private func group(_ title: String, symbol: String, color: Color, _ items: [MemoryAnalysis.Moved]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            ForEach(items, id: \.key) { m in
                HStack {
                    Text(m.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(gb(UInt64(m.delta.magnitude))).font(.callout.weight(.semibold)).monospacedDigit()
                }
            }
        }
    }
}

// MARK: Largest apps

private struct LargestApps: View {
    @ObservedObject var model: Model

    @AppStorage("memorySort") private var sort = "Total"

    var body: some View {
        let all = sort == "Total" ? model.memoryApps : model.memoryApps.sorted { $0.outOfRAM > $1.outOfRAM }
        let apps = Array(all.prefix(8))
        let total = model.memory?.total ?? 1
        let hourAgo = Self.bytesAgo(model.memoryHistory.points, seconds: 3600)
        Card(title: "Memory by app", symbol: "square.stack.3d.up.fill", tint: Tab.memory.color,
             trailing: AnyView(ChipPicker(options: ["Total", "Compressed or in swap"], selection: $sort, color: Tab.memory.color))) {
            HStack(spacing: 12) {
                legend(Tab.memory.color, "In RAM")
                legend(Color(hex: "#d97706"), "Compressed or in swap")
            }
            if apps.isEmpty {
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(apps) { a in
                row(a, total: total, before: hourAgo[a.key])
            }
            Text("Memory as Activity Monitor counts it, added up across each app's processes; bars are a share of the Mac's \(gb(total)). macOS reports swap for the whole Mac only, so each app's compressed and swapped memory is shown together. System services may show less than they hold.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func row(_ a: Model.MemoryApp, total: UInt64, before: UInt64?) -> some View {
        let inRAM = a.bytes > a.outOfRAM ? a.bytes - a.outOfRAM : 0
        let vm = Model.isVM(a.key)
        let host = vm ? model.vmHost() : nil
        HStack(alignment: .top, spacing: 10) {
            IconView(icon: IconCache.shared.icon(for: host?.sample ?? a.sample), size: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(a.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if a.pids.count > 1 {
                        Text("\(a.pids.count) processes").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    if let before, a.bytes > before, a.bytes - before >= 256 << 20 {
                        Pill(text: "+\(gb(a.bytes - before)) in 1 h", symbol: "arrow.up.right", color: Color(hex: "#d97706"))
                    }
                    if let rule = model.memoryRules.rules[model.ruleTarget(a).key] {
                        Pill(text: rule.label, symbol: "bolt.fill", color: Theme.heat(100))
                    }
                    Spacer(minLength: 4)
                    Text(gb(a.bytes)).font(.callout.weight(.bold)).monospacedDigit()
                }
                GeometryReader { g in
                    let w = g.size.width
                    HStack(spacing: 0) {
                        Rectangle().fill(Tab.memory.color.gradient).frame(width: w * Double(inRAM) / Double(max(total, 1)))
                        Rectangle().fill(Color(hex: "#d97706").gradient).frame(width: w * Double(a.outOfRAM) / Double(max(total, 1)))
                        Spacer(minLength: 0)
                    }
                    .frame(width: w)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(Capsule())
                }
                .frame(height: 6)
                HStack(spacing: 10) {
                    Label("\(gb(inRAM)) in RAM", systemImage: "memorychip").foregroundStyle(Tab.memory.color)
                    Label("\(gb(a.outOfRAM)) compressed or in swap", systemImage: "externaldrive.fill").foregroundStyle(Color(hex: "#d97706"))
                    if let t = model.started(a.pids) {
                        Label("running \(Self.age(t))", systemImage: "clock").foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.medium))
                Text(model.memoryAbout(a)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            quitButton(a, host: host)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.03)))
    }

    @ViewBuilder
    private func quitButton(_ a: Model.MemoryApp, host: Model.MemoryApp?) -> some View {
        // A virtual machine is quit through the app that runs it, which shuts it down cleanly.
        let target = host ?? a
        let canQuit = target.sample.pid != getpid() && Safety.canKillManually(target.sample)
        let canForce = a.sample.pid != getpid() && a.sample.pid > 1 && (canQuit || Model.isVM(a.key))
        VStack(alignment: .trailing, spacing: 5) {
            if canQuit {
                pill("Quit", symbol: "xmark.circle.fill", fill: Theme.heat(100)) {
                    model.confirmAndPerform(.quit(pids: target.pids, name: target.name))
                }
                .tip("Ask \(target.name) to quit, so it can save first, and give its memory back")
            }
            if canForce {
                Button { model.confirmForceQuit(pids: a.pids, name: a.name, vm: Model.isVM(a.key)) } label: {
                    Label("Force Quit", systemImage: "bolt.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.heat(100))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Theme.heat(100), lineWidth: 1.2))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .tip("Stop all \(a.pids.count) of its processes at once, without saving")
            }
            if canQuit {
                ruleMenu(a, target: target)
            }
            if !canQuit, !canForce {
                Text("part of macOS").font(.caption).foregroundStyle(.secondary).fixedSize()
                    .tip("Not offered for quitting: the Mac depends on it")
            }
        }
    }

    private func ruleMenu(_ a: Model.MemoryApp, target: Model.MemoryApp) -> some View {
        let current = model.memoryRules.rules[target.key]
        return Menu {
            Section("Quit \(target.name) by itself when it holds over") {
                ForEach(MemoryRule.choices, id: \.self) { limit in
                    Button("\(limit >> 30) GB\(current?.limit == limit ? " (current)" : "")") { model.confirmMemoryRule(limit, for: a) }
                }
            }
            if current != nil {
                Button("No rule") { model.setMemoryRule(nil, for: a) }
            }
        } label: {
            Label(current == nil ? "Rule" : "Rule set", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Quit \(target.name) automatically when it holds too much memory while you are not using it")
    }

    private func pill(_ title: String, symbol: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(fill.gradient))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func age(_ start: Date) -> String { MemoryLargestAge.age(start) }

    /// Each app's memory about `seconds` ago, from the timeline's top apps.
    static func bytesAgo(_ points: [MemoryHistory.Point], seconds: TimeInterval) -> [String: UInt64] {
        let t = Int(Date().timeIntervalSince1970 - seconds)
        guard let p = points.last(where: { $0.t <= t }), t - p.t <= 600 else { return [:] }
        return Dictionary(p.apps.map { ($0.key, $0.bytes) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: Clean up

/// What can actually be done about memory from here, and what each one really frees.
private struct CleanUp: View {
    @ObservedObject var model: Model
    let memory: MemoryStatus

    var body: some View {
        let m = memory
        let up = MemoryStatus.uptime()
        Card(title: "Free up memory", symbol: "wand.and.stars", tint: Tab.memory.color) {
            if let top = model.memoryApps.max(by: { $0.outOfRAM < $1.outOfRAM }), top.outOfRAM >= 256 << 20 {
                let t = model.ruleTarget(top)
                let canQuit = t.sample.pid != getpid() && Safety.canKillManually(t.sample)
                action(symbol: "xmark.app.fill", title: "Quit \(t.name)",
                       text: "Frees about \(gb(model.ruleBytes(t))), including \(gb(top.outOfRAM)) compressed or in swap: the most of any app. Quitting apps is the only way to free swap while the Mac runs. The rest are under Memory by app.",
                       button: canQuit ? AnyView(button("Quit", symbol: "xmark.circle.fill", color: Theme.heat(100)) {
                           model.confirmAndPerform(.quit(pids: t.pids, name: t.name))
                       }) : nil)
            } else {
                action(symbol: "xmark.app.fill", title: "Quit what you are not using",
                       text: "The only thing that frees app memory and swap while the Mac runs. Use the Quit buttons under Memory by app, largest first.",
                       button: nil)
            }
            action(symbol: "doc.on.doc.fill", title: "Free cached files (purge)",
                   text: "Drops \(gb(m.cached)) of cached files from memory. Asks for your password. It does not empty swap (macOS has no command for that), and macOS refills the cache as you work, so it rarely makes the Mac faster.",
                   button: AnyView(button(model.purging ? "Purging…" : "Purge", symbol: "arrow.3.trianglepath", color: Color(hex: "#d97706")) { model.purgeCaches() }
                    .disabled(model.purging)))
            action(symbol: "restart.circle.fill", title: "Restart to clear swap",
                   text: "Swap only empties on a restart. \(up.map { "This Mac has been up \(Int($0 / 86_400)) days with \(gb(m.swapUsed)) in swap." } ?? "")",
                   button: AnyView(button("Restart…", symbol: "restart", color: Tab.processes.color) { model.askToRestart() }
                    .tip("Opens macOS's own Restart dialog: nothing restarts until you confirm")))
        }
    }

    private func action(symbol: String, title: String, text: String, button: AnyView?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolTile(symbol: symbol, color: Tab.memory.color, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let button { button }
        }
    }

    private func button(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(color.gradient))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
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

enum MemoryLargestAge {
    static func age(_ start: Date) -> String {
        let d = Date().timeIntervalSince(start)
        if d >= 86_400 { return "\(Int(d / 86_400))d \(Int(d.truncatingRemainder(dividingBy: 86_400) / 3600))h" }
        return Insights.duration(d)
    }
}
