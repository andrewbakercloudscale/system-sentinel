import AppKit
import Charts
import SentinelCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Fix-it buttons

/// The one-click fixes under an insight. Red for ones that change something.
struct FixButtons: View {
    @ObservedObject var model: Model
    /// Watched too, so storage fixes show Clearing… while they run.
    @ObservedObject private var storage: StorageStore
    let fixes: [FixAction]

    init(model: Model, fixes: [FixAction]) {
        self.model = model
        self.storage = model.storage
        self.fixes = fixes
    }

    /// The storage job a fix starts, while it is running.
    private func busy(_ f: FixAction) -> Bool {
        switch f {
        case .emptyTrash: return storage.working.contains("trash")
        case .cleanPlaces(let keys): return keys.contains { storage.working.contains($0) }
        case .trashFound(let kind, _), .archiveFound(let kind, _): return storage.working.contains("insight-\(kind.rawValue)")
        default: return false
        }
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(fixes) { f in
                if busy(f) {
                    BusyButton(title: f == .emptyTrash ? "Emptying…" : "Clearing…")
                } else {
                Button { model.confirmAndPerform(f) } label: {
                    Label(f.title, systemImage: f.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(f.acts ? .white : Tab.processes.color)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(f.acts ? AnyShapeStyle(Theme.heat(100).gradient) : AnyShapeStyle(Tab.processes.color.opacity(0.12))))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .tip(help(f))
                }
                if case .quit(let pids, let name) = f {
                    Button { forceQuit(pids, name) } label: {
                        Label("Force Quit", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.heat(100))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().strokeBorder(Theme.heat(100), lineWidth: 1.2))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .tip("Stop \(name) at once, without saving. Asks first.")
                }
            }
        }
    }

    /// Force Quit for a quit fix. Quitting a VM's app by force would leave the VM running,
    /// so its virtual machine goes too.
    private func forceQuit(_ pids: [Int32], _ name: String) {
        var all = pids
        if model.vmHost()?.name == name {
            all += model.memoryApps.filter { Model.isVM($0.key) }.flatMap(\.pids)
        }
        let bytes = model.memoryApps.filter { !Set($0.pids).isDisjoint(with: all) }.reduce(UInt64(0)) { $0 + $1.bytes }
        model.confirmForceQuit(pids: all, name: name, vm: all.count > pids.count)
    }

    private func help(_ f: FixAction) -> String {
        switch f {
        case .quit(_, let name): return "Quit \(name) the normal way, so it can save. A minute later you see what it changed."
        case .kill(let pids, _): return "Stop \(pids.count == 1 ? "this process" : "these \(pids.count) processes")."
        case .lowPowerMode: return "Turns Low Power Mode on now. macOS asks for your password."
        case .openSettings(let s): return "Opens System Settings at \(s.title)."
        case .reveal: return "Shows the file in Finder."
        case .emptyTrash: return "Deletes everything in the Trash for good. Asks first."
        case .cleanPlaces: return "Deletes caches that are rebuilt when needed. Asks first."
        case .trashFound: return "Moves them to the Trash, where you can still put them back. Asks first."
        case .archiveFound: return "Moves them to a folder you pick, such as an external drive."
        case .review: return "Shows the list below, to pick item by item."
        case .openApp(_, let name): return "Opens \(name)."
        case .openURL: return "Opens it in the browser."
        case .leaveHotspot: return "Turns Wi-Fi off and on, so the Mac rejoins its usual network instead of the phone."
        case .optimiseScreen: return "Shows the settings that make WindowServer work less, to apply one by one or all at once. Each can be undone."
        case .goTo(let tab, _, _): return "Opens the \(tab) tab."
        case .copy(let text, _): return "Copies \(text) to paste into Terminal. It asks for your admin password."
        }
    }
}

// MARK: Memory

struct MemoryCard: View {
    @ObservedObject var model: Model

    var body: some View {
        if let m = model.memory {
            let color: Color = m.pressure == .normal ? Tab.battery.color : m.pressure == .warning ? Color(hex: "#d97706") : Theme.heat(100)
            Card(title: "Memory", symbol: "memorychip.fill", tint: Tab.processes.color,
                 trailing: AnyView(Pill(text: m.pressure.label, symbol: m.pressure == .normal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", color: color))) {
                HStack(spacing: 8) {
                    StatTile(symbol: "memorychip", color: color, value: ReportDocument.bytes(m.used), label: "used of \(ReportDocument.bytes(m.total))")
                    StatTile(symbol: "arrow.down.right.and.arrow.up.left", color: Tab.processes.color, value: ReportDocument.bytes(m.compressed), label: "compressed")
                    StatTile(symbol: "externaldrive.fill", color: m.swapUsed > 1 << 30 ? Color(hex: "#d97706") : .secondary,
                             value: ReportDocument.bytes(m.swapUsed), label: "swap on disk")
                }
                ShareBar(share: Double(m.used) / Double(max(m.total, 1)), color: color)
                Text(explain(m)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func explain(_ m: MemoryStatus) -> String {
        switch m.pressure {
        case .normal: return "Pressure is what matters, not how full memory looks: macOS keeps memory busy on purpose. Normal means apps get what they ask for."
        case .warning: return "macOS is compressing memory and moving some to disk (swap). Things slow down. The Memory insight names the apps holding the most."
        case .critical: return "The Mac is short of memory and swapping heavily. Quit apps you are not using, starting with the largest."
        }
    }
}

// MARK: Graphics

/// The graphics chip: how busy, the last hour, and which apps are drawing with it.
struct GraphicsCard: View {
    @ObservedObject var model: Model
    static let color = Color(hex: "#0891b2")

    var body: some View {
        if let g = model.gpuStatus {
            let busyColor = g.busy >= 80 ? Theme.heat(100) : g.busy >= 50 ? Color(hex: "#d97706") : Self.color
            Card(title: "Graphics (GPU)", symbol: "square.stack.3d.up.fill", tint: Self.color,
                 trailing: g.name.map { n in AnyView(Pill(text: n + (g.cores.map { ", \($0) cores" } ?? ""), color: .secondary)) }) {
                HStack(spacing: 8) {
                    StatTile(symbol: "gauge.with.dots.needle.67percent", color: busyColor, value: "\(Int(g.busy))%", label: "busy now")
                    StatTile(symbol: "clock.fill", color: Self.color,
                             value: model.gpuAverage(3600).map { "\(Int($0.rounded()))%" } ?? "–",
                             label: model.gpuHistory.count < 12 ? "average so far" : "average, last hour")
                    StatTile(symbol: "memorychip", color: Tab.processes.color,
                             value: g.memoryInUse.map { ReportDocument.bytes($0) } ?? "–", label: "graphics memory")
                    if let w = model.partWatts?.gpu {
                        StatTile(symbol: "bolt.fill", color: Tab.battery.color, value: String(format: "%.1f W", w), label: "power now")
                            .tip(powerTip(w))
                    }
                }
                if model.gpuHistory.count > 1 {
                    Chart(model.gpuHistory, id: \.at) { p in
                        AreaMark(x: .value("Time", p.at), y: .value("Busy", p.busy))
                            .foregroundStyle(Self.color.opacity(0.25).gradient)
                        LineMark(x: .value("Time", p.at), y: .value("Busy", p.busy))
                            .foregroundStyle(Self.color).lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in
                        AxisGridLine()
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.caption2) }
                    } }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute(), centered: false).font(.caption2)
                    } }
                    .frame(height: 70)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("USING IT NOW").sectionLabel()
                    if model.gpuApps.isEmpty {
                        Text("Nothing is drawing much right now.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.gpuApps) { a in
                        HStack(spacing: 8) {
                            IconView(icon: IconCache.shared.icon(for: a.sample), size: 18)
                            Text(a.name).font(.callout).lineLimit(1).truncationMode(.middle).frame(width: 190, alignment: .leading)
                            ShareBar(share: a.cpu / 100, color: Self.color).frame(height: 6)
                            Text(String(format: a.cpu >= 10 ? "%.0f%%" : "%.1f%%", a.cpu)).font(.callout.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(Self.color).frame(width: 46, alignment: .trailing)
                        }
                        .tip("\(a.name) used the graphics chip \(String(format: "%.1f", a.cpu))% of the last few seconds")
                    }
                }
                Text(caption(g)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                savings
            }
        }
    }

    /// What it costs in power, and how much of the Mac's draw that is.
    private func powerTip(_ w: Double) -> String {
        var t = String(format: "The graphics chip is drawing %.1f W", w)
        if let avg = model.gpuWattsAverage(3600) { t += String(format: ", %.1f W on average over the last hour", avg) }
        if let all = model.battery?.watts, all > 0.5 { t += String(format: ". That is %.0f%% of the Mac's %.1f W.", min(100, w / all * 100), all) }
        return t
    }

    private var savings: some View {
        let list = model.gpuSavings()
        return VStack(alignment: .leading, spacing: 6) {
            Text("SAVE POWER").sectionLabel()
            if list.isEmpty {
                Text("Nothing to do: nothing has kept the graphics chip busy over the last 5 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(list, id: \.title) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title).font(.callout.weight(.semibold))
                    Text(s.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !s.fixes.isEmpty { FixButtons(model: model, fixes: s.fixes) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Self.color.opacity(0.07)))
            }
        }
    }

    private func caption(_ g: GPUReader.Status) -> String {
        if g.busy >= 80 { return "The graphics chip is nearly flat out. Games, video export, 3D and AI models do this; if nothing like that is running, the app at the top of the list is the cause." }
        return "The graphics chip draws the screen, plays and exports video, and runs games and AI models. Its memory is part of the Mac's memory, not separate. The window server (WindowServer) is macOS drawing the screen itself."
    }
}

// MARK: Sleep

struct SleepCard: View {
    let report: SleepReport?

    var body: some View {
        Card(title: "Sleep, last 24 hours", symbol: "moon.stars.fill", tint: Color(hex: "#6366f1")) {
            if let r = report, r.sleeps > 0 {
                HStack(spacing: 8) {
                    StatTile(symbol: "bed.double.fill", color: Color(hex: "#6366f1"), value: Model.duration(r.asleep), label: "asleep, \(r.sleeps) \(r.sleeps == 1 ? "time" : "times")")
                    StatTile(symbol: "eye.slash.fill", color: r.darkWakes >= 40 ? Color(hex: "#d97706") : Tab.processes.color,
                             value: "\(r.darkWakes)", label: "dark wakes")
                    StatTile(symbol: "battery.25percent", color: (r.lossPerHour ?? 0) >= 1.5 ? Theme.heat(90) : Tab.battery.color,
                             value: r.lossPerHour.map { String(format: "%.1f%%/h", $0) } ?? (r.chargeLost > 0 ? "\(r.chargeLost)%" : "–"),
                             label: "charge lost asleep")
                }
                if !r.wakeCauses.isEmpty {
                    let top = r.wakeCauses.prefix(5)
                    let most = Double(top.first?.count ?? 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WOKEN BY").sectionLabel()
                        ForEach(Array(top), id: \.cause) { c in
                            HStack(spacing: 8) {
                                Text(c.cause.prefix(1).uppercased() + c.cause.dropFirst()).font(.caption).frame(width: 150, alignment: .leading)
                                ShareBar(share: Double(c.count) / most, color: Color(hex: "#6366f1"))
                                Text("\(c.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                }
                Text("Dark wakes are the Mac waking with the screen off to sync, check mail or run maintenance. A sleeping MacBook should lose about 1% an hour or less.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(report == nil ? "Reading the power log…" : "The Mac has not slept in the last 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Graphics and displays

enum Displays {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    /// The built-in screen's brightness, from the private DisplayServices framework (no
    /// public API exists on Apple silicon). nil when it is unavailable.
    private static let getBrightness: GetBrightness? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let f = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(f, to: GetBrightness.self)
    }()

    @MainActor
    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let mode = CGDisplayCopyDisplayMode(id)
            var level: Float = 0
            let brightness: Double? = builtIn && getBrightness?(id, &level) == 0 ? Double(level) : nil
            return DisplayInfo(name: s.localizedName, builtIn: builtIn, width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0,
                               refresh: Int((mode?.refreshRate ?? 0).rounded()), brightness: brightness)
        }
    }
}

struct DisplaysCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let displays = Displays.current()
        let tips = DisplayAdvice.tips(displays, gpu: model.gpu, onBattery: model.battery?.onBattery ?? false)
        Card(title: "Graphics and displays", symbol: "display", tint: Color(hex: "#0891b2")) {
            HStack(spacing: 8) {
                StatTile(symbol: "cpu.fill", color: (model.gpu ?? 0) >= 50 ? Color(hex: "#d97706") : Color(hex: "#0891b2"),
                         value: model.gpu.map { "\(Int($0))%" } ?? "–", label: "graphics busy")
                StatTile(symbol: "sun.max.fill", color: Color(hex: "#ca8a04"),
                         value: displays.first(where: \.builtIn)?.brightness.map { "\(Int($0 * 100))%" } ?? "–", label: "screen brightness")
                StatTile(symbol: "display.2", color: Tab.processes.color, value: "\(displays.count)", label: displays.count == 1 ? "display" : "displays")
            }
            ForEach(displays, id: \.name) { d in
                HStack(spacing: 8) {
                    Image(systemName: d.builtIn ? "laptopcomputer" : "display").foregroundStyle(Color(hex: "#0891b2")).frame(width: 20)
                    Text(d.name).font(.caption.weight(.medium))
                    Spacer()
                    Text("\(d.width) × \(d.height)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if d.refresh > 0 { Pill(text: "\(d.refresh) Hz", color: d.refresh > 60 && !d.builtIn ? Color(hex: "#d97706") : .secondary) }
                }
            }
            ForEach(tips, id: \.self) { t in
                Label(t, systemImage: "lightbulb.fill").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if tips.isEmpty {
                Text("Nothing to change: brightness, displays and graphics load are all modest.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Network and disk

struct NetworkDiskCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let rows = Array(model.io.prefix(8))
        Card(title: "Network and disk", symbol: "arrow.up.arrow.down.circle.fill", tint: Color(hex: "#0d9488")) {
            if rows.isEmpty {
                Text("Measuring (every 30 seconds)…").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    Text("DOWN").frame(width: 78, alignment: .trailing)
                    Text("UP").frame(width: 78, alignment: .trailing)
                    Text("DISK").frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            ForEach(rows) { r in
                let sample = r.pids.first.flatMap(model.sample(pid:))
                HStack(spacing: 10) {
                    IconView(icon: IconCache.shared.icon(for: sample ?? ProcessSample(pid: 0, uid: 501, cpu: 0, path: r.key)), size: 20)
                    Text(r.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(IORow.netRate(r.netIn)).frame(width: 78, alignment: .trailing)
                    Text(IORow.netRate(r.netOut)).frame(width: 78, alignment: .trailing)
                    Text(IORow.rate(r.disk)).frame(width: 70, alignment: .trailing)
                        .foregroundStyle(r.disk >= 20_000_000 ? Color(hex: "#d97706") : .primary)
                }
                .font(.caption.monospacedDigit())
            }
            Text("Radios and disks cost power too: a big upload or a sync that never stops shows here even when CPU is low. Disk for processes run by the system is not visible to apps.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Health over time

struct HealthTrendCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let entries = model.healthLog.entries
        let now = Date()
        let habits = ChargeHabits.from(model.powerHistory.since(now.addingTimeInterval(-7 * 86_400)))
        Card(title: "Battery wear and charging", symbol: "chart.line.downtrend.xyaxis", tint: Color(hex: "#e11d48")) {
            if entries.count >= 2 {
                Chart {
                    ForEach(entries, id: \.day) { e in
                        LineMark(x: .value("Day", Date(timeIntervalSince1970: Double(e.day))), y: .value("Health", e.health))
                            .foregroundStyle(Color(hex: "#e11d48")).interpolationMethod(.monotone)
                    }
                    RuleMark(y: .value("Replace", 80)).foregroundStyle(Theme.heat(100).opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartYScale(domain: max(0, (entries.map(\.health).min() ?? 80) - 5)...100)
                .frame(height: 90)
            } else {
                Text("Wear is logged once a day; the chart appears from the second day.").font(.caption).foregroundStyle(.secondary)
            }
            if let p = HealthLog.projection(entries) {
                Label("At the current rate it reaches 80% around \(p.formatted(.dateTime.month(.wide).year())).", systemImage: "calendar")
                    .font(.caption)
            } else if !entries.isEmpty {
                Text("A projection needs two weeks of readings.").font(.caption2).foregroundStyle(.secondary)
            }
            if let c = HealthLog.cyclesPerWeek(entries, at: now) {
                Label(String(format: "%.1f charge cycles a week.", c), systemImage: "arrow.triangle.2.circlepath").font(.caption)
            }
            if habits.pluggedMinutes + habits.batteryMinutes >= 60 {
                let total = Double(habits.pluggedMinutes + habits.batteryMinutes)
                HStack(spacing: 8) {
                    StatTile(symbol: "powerplug.fill", color: Tab.processes.color, value: "\(Int(Double(habits.pluggedMinutes) / total * 100))%", label: "time on the charger")
                    StatTile(symbol: "battery.100percent.bolt", color: habits.sitsAtFull ? Color(hex: "#d97706") : Tab.battery.color,
                             value: "\(Int(habits.fullShare * 100))%", label: "of that at 100%")
                    StatTile(symbol: "battery.50percent", color: Tab.battery.color, value: Model.duration(Double(habits.batteryMinutes) * 60), label: "on battery, 7 days")
                }
                Text(habits.sitsAtFull
                     ? "Sitting at 100% on the charger wears the battery fastest. A charge limit of 80% (System Settings > Battery > Charging) or Optimised Battery Charging avoids it."
                     : "Charging looks healthy: the battery is not left full on the charger for long.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Chrome tabs

/// Chrome does not say which tab a process serves, so this lists the open tabs, likely
/// energy users first, with Show and Close for each.
struct ChromeTabsButton: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Label("Tabs", systemImage: "square.on.square").font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .tip("List Chrome's tabs, likely energy users first")
        .popover(isPresented: $shown, arrowEdge: .trailing) { ChromeTabsList() }
    }
}

private struct ChromeTabsList: View {
    @State private var tabs: [ChromeTab] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chrome tabs, likely energy users first").font(.headline)
            Text("Chrome keeps which tab uses what to itself (Window > Task Manager shows it). Video, calls and live apps are the usual cost.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.heat(100)) }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tabs) { t in
                        let w = TabWeight.of(url: t.url)
                        HStack(spacing: 8) {
                            Circle().fill(w.score == 3 ? Theme.heat(100) : w.score == 2 ? Color(hex: "#d97706") : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text([t.host, w.reason].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Button("Show") { _ = ChromeTabs.show(t) }.buttonStyle(.borderless).font(.caption)
                                .tip("Bring this tab to the front in Chrome")
                            Button("Close") {
                                Confirm.ask("Close this Chrome tab?", t.title, symbol: "xmark.square.fill", tint: Theme.heat(100),
                                            points: ["Anything typed into a form on it and not sent is lost."],
                                            undo: "⇧⌘T in Chrome reopens it.", button: "Close tab", destructive: true) {
                                    if case .success = ChromeTabs.close(t) { tabs.removeAll { $0.id == t.id } }
                                }
                            }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(Theme.heat(100))
                            .tip("Close this tab. Asks first")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 320)
            Button("Open Chrome's Task Manager") { _ = ChromeTabs.openTaskManager() }.font(.caption)
                .tip("Chrome's own list of what each tab and extension uses")
        }
        .padding(12)
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private func load() {
        switch ChromeTabs.list() {
        case .success(let all):
            tabs = all.sorted { TabWeight.of(url: $0.url).score > TabWeight.of(url: $1.url).score }
        case .failure(let e):
            error = e.text.isEmpty ? "Could not read Chrome's tabs." : e.text
        }
    }
}

// MARK: Before and after

struct ImpactsCard: View {
    let impacts: [Impact]

    var body: some View {
        Card(title: "What stopping things changed", symbol: "arrow.left.arrow.right", tint: Tab.battery.color) {
            ForEach(Array(impacts.prefix(6).enumerated()), id: \.offset) { _, i in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: i.helped ? "checkmark.circle.fill" : "minus.circle.fill")
                        .foregroundStyle(i.helped ? Tab.battery.color : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.name).font(.callout.weight(.medium))
                        Text(i.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(i.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Measured a minute after each quit or kill, against the minute before.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: Export

struct ExportCard: View {
    @ObservedObject var model: Model

    var body: some View {
        Card(title: "Share a report", symbol: "square.and.arrow.up", tint: Tab.events.color) {
            HStack(spacing: 8) {
                Button { save(pdf: false) } label: { Label("Markdown…", systemImage: "doc.text") }
                    .tip("Save the report as a Markdown text file. You pick where")
                Button { save(pdf: true) } label: { Label("PDF…", systemImage: "doc.richtext") }
                    .tip("Save the report as a PDF. You pick where")
                Spacer()
                ExportMenu(model: model, color: Tab.events.color)
            }
            Text("The week, today, battery, sleep and memory in one page: for your records, IT support, or a repair shop. Export saves the readings themselves as CSV or JSON, for a spreadsheet or a script.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(pdf: Bool) {
        let doc = model.reportDocument()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "System Sentinel report \(Date().formatted(.iso8601.year().month().day())).\(pdf ? "pdf" : "md")"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if pdf {
                try ReportPDF.write(doc, to: url)
            } else {
                try doc.markdown.write(to: url, atomically: true, encoding: .utf8)
            }
            model.showToast(Model.Toast(ok: true, title: "Report saved", detail: url.lastPathComponent))
        } catch {
            model.showToast(Model.Toast(ok: false, title: "Could not save the report", detail: error.localizedDescription))
        }
    }
}

enum ReportPDF {
    struct ExportError: LocalizedError { var errorDescription: String? { "The PDF could not be drawn." } }

    @MainActor
    static func write(_ doc: ReportDocument, to url: URL) throws {
        let renderer = ImageRenderer(content: ReportPage(doc: doc).environment(\.colorScheme, .light))
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = true
        }
        if !ok { throw ExportError() }
    }
}

/// The printable page: A4 width, black on white.
struct ReportPage: View {
    let doc: ReportDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title).font(.system(size: 22, weight: .bold))
                Text(doc.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(doc.sections, id: \.heading) { s in
                VStack(alignment: .leading, spacing: 5) {
                    Text(s.heading).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: "#dc2626"))
                    ForEach(s.lines, id: \.self) { l in
                        Text(l).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .foregroundStyle(.black)
        .padding(40)
        .frame(width: 595, alignment: .leading)
        .background(Color.white)
    }
}

// MARK: Settings

/// The menu bar, alert and sleep settings; edits go to the Settings tab's draft.
struct MenuBarSettingsCard: View {
    @ObservedObject var model: Model
    @Binding var draft: SettingsDraft

    private var heatHelp: String {
        var s = "Also alerts at once when macOS reports the Mac is hot (it then slows the chip). The alert names the likely culprit, with Kill and Ignore buttons. At most one every 30 minutes."
        if let w = model.battery?.watts { s += String(format: " Right now: %.1f W.", w) }
        s += " A MacBook idles at about 3 to 8 W with the screen on; 20 to 30 W is heavy work; over 40 W is flat out."
        return s
    }

    var body: some View {
        Card(title: "Menu bar", symbol: "menubar.rectangle", tint: Tab.overview.color) {
            Picker("Beside the icon", selection: $draft.menuBarShows) {
                Text("Nothing").tag("none")
                Text("CPU load").tag("load")
                Text("Power draw").tag("watts")
                Text("Battery").tag("battery")
            }
            .pickerStyle(.segmented)
            Text("CPU load is the share of the whole Mac. Power draw is in watts. Battery shows the charge, and the time left when unplugged.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Card(title: "Heat and power alerts", symbol: "thermometer.sun.fill", tint: Theme.heat(90)) {
            Toggle("Pop up an alert when the Mac runs hot or draws a lot of power", isOn: $draft.alertHeat).toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Power draw over")
                    Spacer()
                    Text("\(Int(draft.heatWatts)) W").monospacedDigit().fontWeight(.semibold)
                }
                Slider(value: $draft.heatWatts, in: 10...60, step: 5)
                Stepper("For at least \(Int(draft.heatMinutes)) \(draft.heatMinutes == 1 ? "minute" : "minutes")", value: $draft.heatMinutes, in: 1...30)
            }
            .disabled(!draft.alertHeat)
            Text(heatHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Card(title: "Sleep blockers", symbol: "moon.zzz.fill", tint: Color(hex: "#6366f1")) {
            Toggle("Notify when something keeps the Mac awake too long", isOn: $draft.alertBlockers).toggleStyle(.switch)
            Stepper("After \(Int(draft.blockerHours)) \(draft.blockerHours == 1 ? "hour" : "hours")", value: $draft.blockerHours, in: 1...24)
                .disabled(!draft.alertBlockers)
            Text("Once per hold: a forgotten caffeinate, a stuck download, a video call left open.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
