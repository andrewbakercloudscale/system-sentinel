import AppKit
import SentinelCore
import SwiftUI

/// Every busy process, with its trend, its averages, and what can be done about it.
struct ProcessesView: View {
    @ObservedObject var model: Model
    @AppStorage("processSort") private var sortRaw = Sort.now.rawValue
    @State private var search = ""
    /// The list as it stood when Pause was pressed. Sampling, alerts and history carry on;
    /// only what this list shows holds still, so a row does not move away mid-read.
    @State private var frozen: (rows: [ProcessSample], at: Date)?
    /// Column widths, dragged in the header and kept. Process takes whatever is left.
    @AppStorage("colTrend") private var colTrend = 76.0
    @AppStorage("colNow") private var colNow = 62.0
    @AppStorage("colAvg") private var colAvg = 44.0
    @AppStorage("colMem") private var colMem = 54.0

    enum Sort: String, CaseIterable {
        case now = "Now", m15 = "15 min", h1 = "1 hour", h6 = "6 hours", memory = "Memory"

        /// The averaging window this sort ranks by, which the average column then shows.
        var window: TimeInterval? {
            switch self {
            case .m15: return 900
            case .h1: return 3600
            case .h6: return 6 * 3600
            default: return nil
            }
        }
    }

    var body: some View {
        let sort = Sort(rawValue: sortRaw) ?? .now
        // Ranked across every process, not just the 30 busiest right now: the heaviest over
        // 6 hours may be idle at this moment.
        let all = frozen?.rows ?? (model.top.isEmpty ? [] : model.sentinel.latest)
        let rows = Array(sorted(all.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }, by: sort).prefix(30))
        let window = sort.window ?? 900
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                .frame(width: 170)
                pauseButton
                Spacer()
                Text("Sort").font(.caption).foregroundStyle(.secondary)
                ChipPicker(options: Sort.allCases.map(\.rawValue), selection: $sortRaw, color: Tab.processes.color)
            }
            HStack(spacing: 8) {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
                ColumnHeader(title: "15 min trend", width: $colTrend, standard: 76, alignment: .center)
                ColumnHeader(title: "now", width: $colNow, standard: 62)
                ColumnHeader(title: window == 900 ? "15 min" : window == 3600 ? "1 hour" : "6 hours", width: $colAvg, standard: 44)
                ColumnHeader(title: "memory", width: $colMem, standard: 54)
                Text("").frame(width: ProcessColumns.actions)
            }
            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .tip("Drag a column's left edge to resize it; double-click the edge to reset")
            VStack(spacing: 2) {
                let cols = ProcessColumns(trend: colTrend, now: colNow, avg: colAvg, mem: colMem)
                ForEach(Array(rows.enumerated()), id: \.element.pid) { i, s in
                    ProcessRow(model: model, sample: s, zebra: i.isMultiple(of: 2), window: window, cols: cols)
                }
            }
            Text("100% is one full core; a busy process can use several. Averages count idle time, so they show what has been chewing the CPU, not how hot it runs when it does.")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pauseButton: some View {
        let on = frozen != nil
        return Button {
            frozen = on ? nil : (model.sentinel.latest, Date())
        } label: {
            Label(on ? "Paused \(frozen!.at.formatted(date: .omitted, time: .shortened))" : "Pause",
                  systemImage: on ? "play.fill" : "pause.fill")
                .font(.caption.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(on ? Tab.processes.color : Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip(on ? "Resume live updates" : "Hold the list still to read it. Sampling and alerts carry on.")
    }

    private func sorted(_ list: [ProcessSample], by sort: Sort) -> [ProcessSample] {
        switch sort {
        case .now: return list.sorted { $0.cpu > $1.cpu }
        case .m15: return list.map { ($0, model.average($0, 900)) }.sorted { $0.1 > $1.1 }.map(\.0)
        case .h1: return list.map { ($0, model.average($0, 3600)) }.sorted { $0.1 > $1.1 }.map(\.0)
        case .h6: return list.map { ($0, model.average($0, 6 * 3600)) }.sorted { $0.1 > $1.1 }.map(\.0)
        case .memory: return list.sorted { $0.rssKB > $1.rssKB }
        }
    }
}

/// Widths of the fixed columns, shared by the header and every row.
struct ProcessColumns: Equatable {
    var trend = 76.0, now = 62.0, avg = 44.0, mem = 54.0
    static let actions: CGFloat = 196
}

/// A column title with a handle on its left edge: drag to resize, double-click to reset.
private struct ColumnHeader: View {
    let title: String
    @Binding var width: Double
    let standard: Double
    var alignment: Alignment = .trailing
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        Text(title).lineLimit(1)
            .frame(width: width, alignment: alignment)
            .overlay(alignment: .leading) {
                Rectangle().fill(hover || start != nil ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.15))
                    .frame(width: 2, height: 12)
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
                    .offset(x: -6)
                    .onHover { h in
                        hover = h
                        if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            if start == nil { start = width }
                            // The column grows as its left edge moves left.
                            width = min(260, max(standard * 0.6, (start ?? width) - g.translation.width))
                        }
                        .onEnded { _ in start = nil })
                    .onTapGesture(count: 2) { width = standard }
            }
    }
}

/// A row of small tappable chips, the selected one filled.
struct ChipPicker: View {
    let options: [String]
    @Binding var selection: String
    var color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { selection = o } label: {
                    Text(o).font(.caption.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(on ? color : Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ProcessRow: View {
    @ObservedObject var model: Model
    let sample: ProcessSample
    let zebra: Bool
    /// The average column's window: 15 minutes, or what the list is sorted by.
    var window: TimeInterval = 900
    var cols = ProcessColumns()
    @State private var hover = false
    @State private var showInfo = false

    var body: some View {
        let s = sample
        let flagged = model.flagged.contains(s.pid)
        let avg15 = model.average(s, window)
        HStack(spacing: 8) {
            IconView(icon: IconCache.shared.icon(for: s), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(s.displayName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if flagged { Pill(text: "flagged", symbol: "exclamationmark.triangle.fill", color: Theme.heat(100)) }
                    if let hot = model.hotFor(s) { Pill(text: "hot \(hot)", symbol: "flame.fill", color: Theme.heat(50)) }
                    if s.isRoot { Pill(text: "root", color: Tab.settings.color) }
                    policyPill(model.policy(for: s))
                    if model.isSlowed(s) {
                        Pill(text: "background", symbol: "tortoise.fill", color: Tab.rules.color)
                            .tip("Running at background priority: efficiency cores, disk access last. The tortoise button puts it back.")
                    }
                    if model.restarted[s.path] == s.pid {
                        Pill(text: "restarted", symbol: "arrow.clockwise", color: Tab.rules.color)
                            .tip("Killed a moment ago and launched again under this new pid")
                    }
                }
                Text(subtitle(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Sparkline(values: model.sparkline(s), color: Theme.heat(max(s.cpu, avg15)))
                .frame(width: cols.trend, height: 22)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.pct(s.cpu)).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.heat(s.cpu))
                HeatBar(value: s.cpu).frame(width: max(20, cols.now - 10), height: 4)
            }
            .frame(width: cols.now, alignment: .trailing)
            Text(Fmt.pct(avg15)).font(.caption).monospacedDigit().foregroundStyle(Theme.heat(avg15)).frame(width: cols.avg, alignment: .trailing)
            Text(Fmt.memory(s.rssKB)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: cols.mem, alignment: .trailing)

            HStack(spacing: 4) {
                Button { showInfo.toggle() } label: {
                    Image(systemName: ProcessGuide.note(for: s.name) == nil ? "info.circle" : "questionmark.circle.fill")
                        .foregroundStyle(Tab.processes.color)
                }
                .buttonStyle(.plain)
                .tip("What is this?")
                .popover(isPresented: $showInfo, arrowEdge: .leading) { InfoPopover(model: model, sample: s) }
                Button { model.explain(s) } label: {
                    Image(systemName: "sparkles").foregroundStyle(Tab.trends.color)
                }
                .buttonStyle(.plain)
                .tip("Explain: ask ChatGPT why this is busy and how to bring it down")
                if model.canSlow(s) { SlowButton(model: model, sample: s) }
                if s.pid == getpid() {
                    Pill(text: "this app", color: Tab.overview.color).frame(width: 96, alignment: .trailing)
                } else if s.name == "WindowServer" {
                    OptimiseScreenButton(model: model)
                } else if Safety.canKillManually(s) {
                    KillButton(model: model, sample: s)
                } else {
                    SudoButton(model: model, sample: s)
                }
            }
            .frame(width: ProcessColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(flagged ? Theme.heat(100).opacity(0.10)
                      : hover ? Tab.processes.color.opacity(0.08)
                      : zebra ? Color.primary.opacity(0.025) : .clear)
        )
        .onHover { hover = $0 }
        .contextMenu { menu(s) }
    }

    private func subtitle(_ s: ProcessSample) -> String {
        var parts = ["pid \(s.pid)"]
        if let up = model.uptime(s) { parts.append(up) }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func policyPill(_ p: Policy) -> some View {
        switch p {
        case .alert: EmptyView()
        case .ignore, .ignoreDuring: Pill(text: p.label, symbol: "moon.fill", color: Tab.rules.color)
        default: Pill(text: p.label, symbol: p == .autoKill ? "bolt.fill" : "battery.50percent", color: Theme.heat(p == .autoKill ? 100 : 80))
        }
    }


    @ViewBuilder
    private func menu(_ s: ProcessSample) -> some View {
        Section("Rule") {
            Button("Alert me (default)") { model.setPolicy(.alert, for: s) }
            Button("Auto-kill") { model.confirmPolicy(.autoKill, for: s) }.disabled(!Safety.canAutoKill(s))
            Button("Auto-kill on battery") { model.confirmPolicy(.autoKillOnBattery, for: s) }.disabled(!Safety.canAutoKill(s))
            Button("Auto-kill when battery under 30%") { model.confirmPolicy(.autoKillBelow(percent: 30), for: s) }.disabled(!Safety.canAutoKill(s))
            Button("Ignore during work hours (9:00–17:00)") { model.setPolicy(.ignoreDuring(from: 9, to: 17), for: s) }
            Button("Ignore overnight (22:00–07:00)") { model.setPolicy(.ignoreDuring(from: 22, to: 7), for: s) }
            Button("Ignore for 1 hour") { model.setPolicy(.ignore(until: Date().addingTimeInterval(3600)), for: s) }
            Button("Always ignore") { model.setPolicy(.ignore(until: nil), for: s) }
        }
        Divider()
        if let app = NSRunningApplication(processIdentifier: s.pid), app.bundleURL != nil {
            Button("Bring to front") { app.activate() }
            Button("Quit gracefully") { model.confirmQuitGracefully(app, name: s.displayName) }
        }
        Button("Reveal in Finder") {
            let url = URL(fileURLWithPath: AppIdentity.bundlePath(of: s.path) ?? s.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .disabled(!s.path.hasPrefix("/"))
        Button("Copy pid") { copy("\(s.pid)") }
        Button("Force kill (kill -9)…") { ForceKillButton.confirm(model, s) }
            .disabled(s.pid <= 1 || s.pid == getpid())
        Button("Copy sudo kill command") { copy(Killer.sudoCommand(for: s)) }
        Button("Open Activity Monitor") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.lastAction = "Copied: \(text)"
    }
}

/// What the process is, where it lives, and its averages.
private struct InfoPopover: View {
    @ObservedObject var model: Model
    let sample: ProcessSample

    var body: some View {
        let s = sample
        let note = ProcessGuide.note(for: s.name)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconView(icon: IconCache.shared.icon(for: s), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.displayName).font(.headline)
                    Text(note?.headline ?? Model.appName(Model.appKey(s.path))).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let note {
                Text(note.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                verdict(note.verdict)
            }
            HStack(spacing: 8) {
                stat("now", s.cpu)
                stat("1 min", model.average(s, 60))
                stat("15 min", model.average(s, 900))
                stat("1 hour", model.average(s, 3600))
                stat("6 hours", model.average(s, 6 * 3600))
            }
            Sparkline(values: model.sparkline(s, minutes: 60, buckets: 60), color: Theme.heat(s.cpu)).frame(height: 40)
            Text("Last hour").font(.caption2).foregroundStyle(.secondary)
            ExplainButton { model.explain(s) }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text(s.path).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("pid \(s.pid)  ·  uid \(s.uid)  ·  \(Fmt.memory(s.rssKB))\(model.started(s).map { "  ·  " + $0 } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func stat(_ label: String, _ v: Double) -> some View {
        VStack(spacing: 1) {
            Text(Fmt.pct(v)).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.heat(v))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.heat(v).opacity(0.1)))
    }

    @ViewBuilder
    private func verdict(_ v: ProcessGuide.Verdict) -> some View {
        switch v {
        case .wait: Pill(text: "Normal: it settles on its own", symbol: "hourglass", color: Theme.heat(0))
        case .safe: Pill(text: "Safe to stop: it comes back when needed", symbol: "checkmark.circle.fill", color: Color(light: "#2563eb", dark: "#60a5fa"))
        case .avoid: Pill(text: "Do not kill: macOS depends on it", symbol: "hand.raised.fill", color: Theme.heat(100))
        case .yours: Pill(text: "Something you started: your call", symbol: "person.fill", color: Tab.trends.color)
        }
    }
}

/// A filled line of recent CPU, scaled to its own peak (min 10% so idle stays flat).
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let top = max(values.max() ?? 0, 10)
            let step = values.count > 1 ? g.size.width / CGFloat(values.count - 1) : 0
            let pts = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: g.size.height - CGFloat(v / top) * (g.size.height - 2) - 1)
            }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: g.size.height))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// A short bar filled to `value`% of 100 (capped), in its heat colour.
struct HeatBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Theme.heat(value)).frame(width: max(3, g.size.width * min(value, 100) / 100))
            }
        }
    }
}

/// Red for a normal kill, orange for a root kill (asks for the password).
struct KillButton: View {
    @ObservedObject var model: Model
    let sample: ProcessSample
    private var isRoot: Bool { sample.isRoot }
    private var busy: Bool { model.killing.contains(sample.pid) }

    /// Off where the row already has a Force kill of its own.
    var withForce = true

    var body: some View {
        HStack(spacing: 5) {
            if withForce, !busy {
                Button { ForceKillButton.confirm(model, sample) } label: {
                    Image(systemName: "bolt.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(Color(hex: "#dc2626"))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Capsule().strokeBorder(Color(hex: "#dc2626"), lineWidth: 1.2))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .tip("Force kill (kill -9): stops it at once, with no chance to save. Asks first.")
            }
            kill
        }
    }

    private var kill: some View {
        Button { model.confirmKill(sample) } label: {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Killing…")
                } else {
                    Label("Kill", systemImage: isRoot ? "lock.fill" : "xmark.octagon.fill")
                }
            }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(LinearGradient(
                    colors: isRoot ? [Color(hex: "#f97316"), Color(hex: "#ea580c")] : [Color(hex: "#ef4444"), Color(hex: "#dc2626")],
                    startPoint: .top, endPoint: .bottom)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.75 : 1)
        .fixedSize()
        .tip(isRoot ? "Runs as root: asks for your password" : "Stop politely, force after 5 s")
    }
}

/// Lower priority, now or always for this name, and back again.
struct SlowButton: View {
    @ObservedObject var model: Model
    let sample: ProcessSample

    var body: some View {
        let on = model.isSlowed(sample)
        let ruled = model.slowRules.contains(sample.name)
        Menu {
            if on {
                Button("Back to normal priority") { model.confirmRestore(sample) }
            } else {
                Button("Lower priority now") { model.confirmSlowDown(sample, always: false) }
                Button("Always lower \(sample.name)") { model.confirmSlowDown(sample, always: true) }
            }
            if on, !ruled { Button("Always lower \(sample.name)") { model.confirmSlowDown(sample, always: true) } }
            if let note = BackgroundCandidates.note(sample.name) {
                Divider()
                Text(note)
            }
        } label: {
            Image(systemName: on ? "tortoise.fill" : "tortoise")
                .foregroundStyle(on ? Tab.rules.color : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip(on ? "At background priority\(ruled ? ", always" : ""). Click to put it back." :
                   "Optimise: lower its priority so it runs on the efficiency cores and your apps stay quick. Undo any time.")
    }
}

/// WindowServer cannot be killed without logging out; it can be given less to draw.
struct OptimiseScreenButton: View {
    @ObservedObject var model: Model
    var body: some View {
        Button { OptimiseWindow.show(model) } label: {
            Label("Optimise", systemImage: "wand.and.stars")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(Tab.processes.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .frame(width: 96, alignment: .trailing)
        .tip("Settings that make WindowServer draw less, each with an undo")
    }
}

/// A protected process: a red-outlined sudo button that says what killing it will do,
/// then offers a Terminal sudo shell, the admin password prompt, or the command to copy.
struct SudoButton: View {
    @ObservedObject var model: Model
    let sample: ProcessSample

    var body: some View {
        Button(action: confirm) {
            HStack(spacing: 4) {
                if model.killing.contains(sample.pid) {
                    ProgressView().controlSize(.mini)
                    Text("Killing…")
                } else {
                    Label("sudo kill", systemImage: "terminal.fill")
                }
            }
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(hex: "#dc2626"))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color(hex: "#dc2626").opacity(0.08)))
                .overlay(Capsule().stroke(Color(hex: "#dc2626"), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: 96, alignment: .trailing)
        .tip("Protected macOS process: kill it as admin")
    }

    private func confirm() { model.confirmSudoKill(sample) }

    static func consequence(of name: String) -> String {
        switch name {
        case "WindowServer": return "WindowServer draws the whole screen. Killing it logs you out immediately and every unsaved document is lost."
        case "loginwindow": return "Killing loginwindow logs you out immediately."
        case "kernel_task": return "kernel_task is the kernel. It cannot be killed; high CPU here is macOS throttling for heat."
        case "Finder", "Dock", "SystemUIServer": return "\(name) restarts by itself within seconds. Usually harmless."
        case "coreaudiod": return "Sound stops briefly while coreaudiod restarts."
        default: return "\(name) is a core macOS process. launchd normally restarts it, but the Mac may misbehave until it does."
        }
    }
}

/// Opens ChatGPT with a prompt about the process, prefilled with this Mac's details.
struct ExplainButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Explain and how to fix it", systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.heroGradient))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .tip("Opens ChatGPT with a prompt describing this process and your Mac")
    }
}

/// SIGKILL, for a process that ignored the polite kill. Always confirms first: the process
/// cannot save or clean up, and for a core macOS process the warning says what will break.
struct ForceKillButton: View {
    @ObservedObject var model: Model
    let sample: ProcessSample

    var body: some View {
        let busy = model.killing.contains(sample.pid)
        Button { Self.confirm(model, sample) } label: {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Killing…")
                } else {
                    Label("Force kill", systemImage: "bolt.fill")
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(LinearGradient(colors: [Color(hex: "#b91c1c"), Color(hex: "#7f1d1d")],
                                                      startPoint: .top, endPoint: .bottom)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy || sample.pid <= 1 || sample.pid == getpid())
        .frame(width: 104, alignment: .trailing)
        .tip("kill -9: stops it at once, with no chance to save")
    }

    static func confirm(_ model: Model, _ s: ProcessSample) { model.confirmForceKill(s) }
}
