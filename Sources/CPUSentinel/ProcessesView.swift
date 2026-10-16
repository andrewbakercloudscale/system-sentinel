import AppKit
import SentinelCore
import SwiftUI

/// Every busy process, with its trend, its averages, and what can be done about it.
struct ProcessesView: View {
    @ObservedObject var model: Model
    @AppStorage("processSort") private var sortRaw = Sort.now.rawValue
    @State private var search = ""

    enum Sort: String, CaseIterable {
        case now = "Now", m15 = "15 min", h1 = "1 hour", memory = "Memory"
    }

    var body: some View {
        let sort = Sort(rawValue: sortRaw) ?? .now
        let rows = sorted(model.top.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }, by: sort)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                .frame(width: 170)
                Spacer()
                Text("Sort").font(.caption).foregroundStyle(.secondary)
                ChipPicker(options: Sort.allCases.map(\.rawValue), selection: $sortRaw, color: Tab.processes.color)
            }
            HStack(spacing: 8) {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
                Text("15 min trend").frame(width: 76)
                Text("now").frame(width: 62, alignment: .trailing)
                Text("15 min").frame(width: 44, alignment: .trailing)
                Text("memory").frame(width: 54, alignment: .trailing)
                Text("").frame(width: 128)
            }
            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.pid) { i, s in
                    ProcessRow(model: model, sample: s, zebra: i.isMultiple(of: 2))
                }
            }
            Text("100% is one full core; a busy process can use several. Averages count idle time, so they show what has been chewing the CPU, not how hot it runs when it does.")
                .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sorted(_ list: [ProcessSample], by sort: Sort) -> [ProcessSample] {
        switch sort {
        case .now: return list.sorted { $0.cpu > $1.cpu }
        case .m15: return list.map { ($0, model.average($0, 900)) }.sorted { $0.1 > $1.1 }.map(\.0)
        case .h1: return list.map { ($0, model.average($0, 3600)) }.sorted { $0.1 > $1.1 }.map(\.0)
        case .memory: return list.sorted { $0.rssKB > $1.rssKB }
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
    @State private var hover = false
    @State private var showInfo = false

    var body: some View {
        let s = sample
        let flagged = model.flagged.contains(s.pid)
        let avg15 = model.average(s, 900)
        HStack(spacing: 8) {
            IconView(icon: IconCache.shared.icon(for: s), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(s.displayName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if flagged { Pill(text: "flagged", symbol: "exclamationmark.triangle.fill", color: Theme.heat(100)) }
                    if let hot = model.hotFor(s) { Pill(text: "hot \(hot)", symbol: "flame.fill", color: Theme.heat(50)) }
                    if s.isRoot { Pill(text: "root", color: Tab.settings.color) }
                    policyPill(model.policy(for: s))
                }
                Text(subtitle(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Sparkline(values: model.sparkline(s), color: Theme.heat(max(s.cpu, avg15)))
                .frame(width: 76, height: 22)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.pct(s.cpu)).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.heat(s.cpu))
                HeatBar(value: s.cpu).frame(width: 52, height: 4)
            }
            .frame(width: 62, alignment: .trailing)
            Text(Fmt.pct(avg15)).font(.caption).monospacedDigit().foregroundStyle(Theme.heat(avg15)).frame(width: 44, alignment: .trailing)
            Text(Fmt.memory(s.rssKB)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)

            HStack(spacing: 4) {
                Button { showInfo.toggle() } label: {
                    Image(systemName: ProcessGuide.note(for: s.name) == nil ? "info.circle" : "questionmark.circle.fill")
                        .foregroundStyle(Tab.processes.color)
                }
                .buttonStyle(.plain)
                .help("What is this?")
                .popover(isPresented: $showInfo, arrowEdge: .leading) { InfoPopover(model: model, sample: s) }
                Button { model.explain(s) } label: {
                    Image(systemName: "sparkles").foregroundStyle(Tab.trends.color)
                }
                .buttonStyle(.plain)
                .help("Explain: ask ChatGPT why this is busy and how to bring it down")
                if s.pid == getpid() {
                    Pill(text: "this app", color: Tab.overview.color).frame(width: 72, alignment: .trailing)
                } else if Safety.canKillManually(s) {
                    KillButton(isRoot: s.isRoot) { model.kill(s) }
                } else {
                    SudoButton(model: model, sample: s)
                }
            }
            .frame(width: 128, alignment: .trailing)
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
        case .autoKill: Pill(text: "auto-kill", symbol: "bolt.fill", color: Theme.heat(100))
        case .ignore(let until?): Pill(text: "ignored until \(Fmt.time(until))", symbol: "moon.fill", color: Tab.rules.color)
        case .ignore(nil): Pill(text: "ignored", symbol: "moon.fill", color: Tab.rules.color)
        }
    }

    @ViewBuilder
    private func menu(_ s: ProcessSample) -> some View {
        Section("Rule") {
            Button("Alert me (default)") { model.setPolicy(.alert, for: s) }
            Button("Auto-kill") { model.setPolicy(.autoKill, for: s) }.disabled(!Safety.canAutoKill(s))
            Button("Ignore for 1 hour") { model.setPolicy(.ignore(until: Date().addingTimeInterval(3600)), for: s) }
            Button("Always ignore") { model.setPolicy(.ignore(until: nil), for: s) }
        }
        Divider()
        if let app = NSRunningApplication(processIdentifier: s.pid), app.bundleURL != nil {
            Button("Bring to front") { app.activate() }
            Button("Quit gracefully") { app.terminate() }
        }
        Button("Reveal in Finder") {
            let url = URL(fileURLWithPath: AppIdentity.bundlePath(of: s.path) ?? s.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .disabled(!s.path.hasPrefix("/"))
        Button("Copy pid") { copy("\(s.pid)") }
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
    let isRoot: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Kill", systemImage: isRoot ? "lock.fill" : "xmark.octagon.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(LinearGradient(
                    colors: isRoot ? [Color(hex: "#f97316"), Color(hex: "#ea580c")] : [Color(hex: "#ef4444"), Color(hex: "#dc2626")],
                    startPoint: .top, endPoint: .bottom)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: 72, alignment: .trailing)
        .help(isRoot ? "Runs as root: asks for your password" : "Stop politely, force after 5 s")
    }
}

/// A protected process: a red-outlined sudo button that says what killing it will do,
/// then offers a Terminal sudo shell, the admin password prompt, or the command to copy.
struct SudoButton: View {
    @ObservedObject var model: Model
    let sample: ProcessSample

    var body: some View {
        Button(action: confirm) {
            Label("sudo", systemImage: "terminal.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(hex: "#dc2626"))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color(hex: "#dc2626").opacity(0.08)))
                .overlay(Capsule().stroke(Color(hex: "#dc2626"), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: 72, alignment: .trailing)
        .help("Protected macOS process: kill it as admin")
    }

    private func confirm() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Kill \(sample.name) (pid \(sample.pid)) as admin?"
        alert.informativeText = Self.consequence(of: sample.name)
            + "\n\nCommand:\n\(Killer.sudoCommand(for: sample))"
        alert.addButton(withTitle: "Open sudo shell")
        alert.addButton(withTitle: "Kill with password")
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.openSudoShell(sample)
        case .alertSecondButtonReturn: model.killProtected(sample)
        case .alertThirdButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Killer.sudoCommand(for: sample), forType: .string)
            model.lastAction = "Copied: \(Killer.sudoCommand(for: sample))"
        default: break
        }
    }

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
        .help("Opens ChatGPT with a prompt describing this process and your Mac")
    }
}
