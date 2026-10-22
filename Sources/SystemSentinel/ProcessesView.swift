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
    @AppStorage("colGPU") private var colGPU = 46.0
    /// Bumped when the standard widths change, so saved ones start again once.
    @AppStorage("colLayout") private var colLayout = 0

    enum Sort: String, CaseIterable {
        case now = "Now", m15 = "15 min", h1 = "1 hour", h6 = "6 hours", memory = "Memory", gpu = "GPU", name = "Name"

        var label: String {
            switch self {
            case .now: return "CPU now"
            case .m15, .h1, .h6: return "CPU, \(rawValue) average"
            default: return rawValue
            }
        }

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
        // A Section so the menu's scroll view can pin this bar: Filter, Pause, Sort and the
        // column headers stay in view however far the list is scrolled.
        Section {
            VStack(spacing: 2) {
                let cols = ProcessColumns(trend: colTrend, now: colNow, avg: colAvg, mem: colMem, gpu: colGPU)
                ForEach(Array(rows.enumerated()), id: \.element.pid) { i, s in
                    ProcessRow(model: model, sample: s, zebra: i.isMultiple(of: 2), window: window, cols: cols)
                }
            }
            Text("100% is one full core; a busy process can use several. Averages count idle time, so they show what has been chewing the CPU, not how hot it runs when it does. GPU is each process's share of the graphics chip over the last 5 seconds, where 100% is all of it. Click a column title to sort by it.")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            toolbar(sort: sort, window: window)
        }
    }

    private func toolbar(sort: Sort, window: TimeInterval) -> some View {
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
                sortMenu(sort)
            }
            HStack(spacing: 8) {
                Button { sortRaw = Sort.name.rawValue } label: { sortTitle("Process", on: sort == .name) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
                    .tip("Sort by name")
                // A column grows into the Process column, never past it: an overfull row made the
                // whole list fight over its width, which is what flickered.
                let room = ProcessColumns.room
                let used = colTrend + colNow + colAvg + colMem + colGPU
                ColumnHeader(title: "15 min trend", width: $colTrend, standard: 84, minWidth: 50, maxWidth: room - used + colTrend, alignment: .center)
                ColumnHeader(title: "CPU", width: $colNow, standard: 64, minWidth: 54, maxWidth: room - used + colNow,
                             sorted: sort == .now, onSort: { sortRaw = Sort.now.rawValue })
                ColumnHeader(title: window == 900 ? "15 min" : window == 3600 ? "1 hour" : "6 hours", width: $colAvg, standard: 60, minWidth: 44, maxWidth: room - used + colAvg,
                             sorted: sort.window != nil, onSort: { sortRaw = (sort.window == nil ? Sort.m15 : sort == .m15 ? .h1 : sort == .h1 ? .h6 : .m15).rawValue })
                ColumnHeader(title: "memory", width: $colMem, standard: 66, minWidth: 54, maxWidth: room - used + colMem,
                             sorted: sort == .memory, onSort: { sortRaw = Sort.memory.rawValue })
                ColumnHeader(title: "GPU", width: $colGPU, standard: 52, minWidth: 42, maxWidth: room - used + colGPU,
                             sorted: sort == .gpu, onSort: { sortRaw = Sort.gpu.rawValue })
                Text("").frame(width: ProcessColumns.actions)
            }
            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .tip("Click a title to sort by it. Drag a column's left edge to resize it; double-click the edge to reset.")
        }
        .padding(.vertical, 6)
        .onAppear {
            // Widths saved before the columns had limits, or before the GPU column, can
            // overfill the row or wrap a value onto two lines; start again.
            // Widths from before the actions moved into one menu are too narrow; start again too.
            if colLayout < 2 || colTrend + colNow + colAvg + colMem + colGPU > ProcessColumns.room
                || colTrend < 50 || colNow < 54 || colAvg < 44 || colMem < 54 || colGPU < 42 {
                (colTrend, colNow, colAvg, colMem, colGPU) = (84, 64, 60, 66, 52)
                colLayout = 2
            }
        }
        // Opaque, so rows scrolling underneath the pinned bar do not show through it.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sortMenu(_ sort: Sort) -> some View {
        Menu {
            ForEach(Sort.allCases, id: \.self) { s in
                Button { sortRaw = s.rawValue } label: {
                    if s == sort { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                }
            }
        } label: {
            Label("Sort: \(sort.label)", systemImage: "arrow.up.arrow.down").font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .tip("Sort by CPU, memory, GPU or name. Clicking a column title does the same.")
    }

    private func sortTitle(_ title: String, on: Bool) -> some View {
        HStack(spacing: 2) {
            Text(title)
            if on { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .foregroundStyle(on ? Tab.processes.color : .secondary)
        .contentShape(Rectangle())
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
        case .gpu: return list.sorted { (model.gpuShares[$0.pid] ?? 0, $0.cpu) > (model.gpuShares[$1.pid] ?? 0, $1.cpu) }
        case .name: return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }
}

/// Widths of the fixed columns, shared by the header and every row.
struct ProcessColumns: Equatable {
    var trend = 84.0, now = 64.0, avg = 60.0, mem = 66.0, gpu = 52.0
    /// The one Actions menu at the end of each row.
    static let actions: CGFloat = 40
    /// What the five resizable columns may share: the row, less its padding, spacing, the
    /// actions and the narrowest the Process column can usefully be.
    static let room = Double(MenuView.width) - 28 - 2 - 12 - Double(actions) - 6 * 8 - 100
}

/// A column title with a handle on its left edge: drag to resize, double-click to reset.
private struct ColumnHeader: View {
    let title: String
    @Binding var width: Double
    let standard: Double
    /// Narrow enough to give room away, wide enough that the value still fits on one line.
    let minWidth: Double
    let maxWidth: Double
    var alignment: Alignment = .trailing
    /// Columns that sort: the title is clickable and marked while it is the sort.
    var sorted = false
    var onSort: (() -> Void)?
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 2) {
            Text(title).lineLimit(1)
            if sorted { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
            .foregroundStyle(sorted ? Tab.processes.color : .secondary)
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
            .onTapGesture { onSort?() }
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
                    // Global coordinates: the handle moves as the column grows, so measuring the
                    // drag in its own space fed the movement back into itself.
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            if start == nil { start = width }
                            // The column grows as its left edge moves left.
                            width = min(max(minWidth, maxWidth), max(minWidth, ((start ?? width) - g.translation.width).rounded()))
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
    @State private var optimise = false

    var body: some View {
        let s = sample
        let flagged = model.flagged.contains(s.pid)
        let hot = model.hotFor(s)
        let onFire = flagged || hot != nil
        let avg15 = model.average(s, window)
        HStack(spacing: 8) {
            IconView(icon: IconCache.shared.icon(for: s), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(s.displayName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    if flagged { Pill(text: "Flagged: using too much CPU", symbol: "exclamationmark.triangle.fill", color: Theme.heat(100), compact: true) }
                    if let hot { Pill(text: "Hot for \(hot)", symbol: "flame.fill", color: Theme.heat(50), compact: true) }
                    if s.isRoot { Pill(text: "Runs as root", symbol: "lock.fill", color: Color(hex: "#b45309"), compact: true) }
                    policyPill(model.policy(for: s))
                    if model.isSlowed(s) {
                        Pill(text: "background", symbol: "tortoise.fill", color: Theme.rules, compact: true)
                            .tip("Running at background priority: efficiency cores, disk access last. The tortoise button puts it back.")
                    }
                    if model.restarted[s.path] == s.pid {
                        Pill(text: "restarted", symbol: "arrow.clockwise", color: Theme.rules, compact: true)
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
            let gpu = model.gpuShares[s.pid] ?? 0
            Text(gpu >= 0.05 ? Fmt.pct(gpu) : "–").font(.caption.weight(gpu >= 5 ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(gpu >= 0.05 ? GraphicsCard.color : .secondary).frame(width: cols.gpu, alignment: .trailing)

            actions(s)
            .frame(width: ProcessColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(onFire ? Theme.heat(100).opacity(hover ? 0.20 : 0.14)
                      : hover ? Tab.processes.color.opacity(0.08)
                      : zebra ? Color.primary.opacity(0.025) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.heat(100).opacity(onFire ? 0.45 : 0), lineWidth: 1)
        )
        .onHover { hover = $0 }
        .contextMenu { menu(s) }
    }

    /// Everything that can be done to the process, in one menu, so the rows stay calm.
    @ViewBuilder
    private func actions(_ s: ProcessSample) -> some View {
        if model.killing.contains(s.pid) {
            ProgressView().controlSize(.small).tip("Killing…")
        } else {
            let fix = ProcessFixes.hasSpecific(s.name)
            Menu {
                Button { InfoPanel.toggle(model: model, sample: s) } label: { Label("What is this?", systemImage: "info.circle") }
                Button { model.explain(s) } label: { Label("Explain with ChatGPT", systemImage: "sparkles") }
                if s.name == "WindowServer" {
                    Button { OptimiseWindow.show(model) } label: { Label("Optimise the screen…", systemImage: "wand.and.stars") }
                } else if OptimiseButton.available(model, s) {
                    Button { optimise = true } label: {
                        Label(fix ? "Optimise (there is a fix)…" : "Optimise…", systemImage: model.isSlowed(s) ? "tortoise.fill" : "wand.and.stars")
                    }
                }
                Divider()
                if s.pid == getpid() {
                    Text("This app")
                } else if s.name == "WindowServer" || !Safety.canKillManually(s) {
                    Button { model.confirmSudoKill(s) } label: { Label("sudo kill…", systemImage: "terminal.fill") }
                } else {
                    Button { model.confirmKill(s) } label: { Label(s.isRoot ? "Kill (asks for your password)" : "Kill", systemImage: "xmark.octagon.fill") }
                    Button { ForceKillButton.confirm(model, s) } label: { Label("Force kill (kill -9)…", systemImage: "bolt.fill") }
                }
                Divider()
                Menu("More") { menu(s) }
            } label: {
                Image(systemName: fix ? "wand.and.stars" : "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Tab.processes.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip(fix ? "Actions: there is a fix for this one" : "Actions: explain, optimise, kill")
            .popover(isPresented: $optimise, arrowEdge: .leading) {
                OptimisePopover(model: model, sample: s) { optimise = false }
            }
        }
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
        case .ignore, .ignoreDuring: Pill(text: p.label, symbol: "moon.fill", color: Theme.rules, compact: true)
        default: Pill(text: p.label, symbol: p == .autoKill ? "bolt.fill" : "battery.50percent", color: Theme.heat(p == .autoKill ? 100 : 80), compact: true)
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
/// "What is this?" in a small floating window of its own, so it stays put while the list
/// re-sorts underneath it. One at a time: another row's button swaps it, the same one closes it.
@MainActor
enum InfoPanel {
    private static var panel: NSPanel?
    private static var pid: Int32?

    static func toggle(model: Model, sample: ProcessSample) {
        if let p = panel, p.isVisible, pid == sample.pid { p.orderOut(nil); return }
        let host = NSHostingController(rootView: InfoPopover(model: model, sample: sample).tipsAndConfirmations(TipCenter(), surface: "info"))
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        let wasOpen = p.isVisible
        p.contentViewController = host
        p.title = sample.displayName
        let size = host.view.fittingSize
        p.setContentSize(size)
        if !wasOpen {
            // Level with the pointer, just outside the window it was opened from (left, or
            // right when there is no room), so it covers none of the list.
            let mouse = NSEvent.mouseLocation
            let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
            let frame = p.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            let from = NSApp.windows.first { $0 !== p && $0.isVisible && $0.frame.contains(mouse) }?.frame
                ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
            var x = from.minX - frame.width - 8
            if x < screen.minX + 8 { x = min(from.maxX + 8, screen.maxX - frame.width - 8) }
            let y = min(max(mouse.y - frame.height / 2, screen.minY + 8), screen.maxY - frame.height - 8)
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        pid = sample.pid
        p.orderFrontRegardless()
    }
}

private struct InfoPopover: View {
    @ObservedObject var model: Model
    let sample: ProcessSample

    var body: some View {
        // The latest reading while it is still running, so "now" stays current in the window.
        let s = model.sample(pid: sample.pid) ?? sample
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
        case .yours: Pill(text: "Something you started: your call", symbol: "person.fill", color: Theme.trends)
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
