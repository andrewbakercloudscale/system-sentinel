import AppKit
import SentinelCore
import SwiftUI

@main
struct CPUSentinelApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // The menu bar draws SwiftUI images as monochrome templates, so the colour has to
            // be baked into a non-template NSImage.
            Image(nsImage: menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// Always red, so it stands out in the menu bar; the glyph carries the state.
    private let color = NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)

    private var glyphName: String {
        model.level == .alert ? "exclamationmark.triangle.fill" : "cpu"
    }

    /// A solid coloured badge with a white chip glyph: readable on light and dark menu bars,
    /// which a thin coloured outline symbol was not.
    private var menuIcon: NSImage {
        let size = NSSize(width: 24, height: 18)
        let fill = color
        let glyph = NSImage(systemSymbolName: glyphName, accessibilityDescription: "CPU Sentinel")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        let img = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
            if let g = glyph {
                let r = NSRect(x: (rect.width - g.size.width) / 2, y: (rect.height - g.size.height) / 2,
                               width: g.size.width, height: g.size.height)
                g.draw(in: r)
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "CPU Sentinel"
        return img
    }
}

struct MenuView: View {
    @ObservedObject var model: Model
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CPU Sentinel").font(.headline)
                Spacer()
                Text("\(Int(model.machineLoad))% of \(Int(model.cores)) cores")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $tab) {
                Text("Processes").tag(0)
                Text("24 h").tag(4)
                Text("Rules").tag(1)
                Text("History").tag(2)
                Text("Settings").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case 0: ProcessList(model: model)
            case 1: RulesView(model: model)
            case 2: HistoryView(model: model)
            case 4: DailyView(model: model)
            default: SettingsView(model: model)
            }

            if let msg = model.lastAction {
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    model.sentinel.dailyUsage.save()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding(12)
        .frame(width: 580)
    }
}

struct ProcessList: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 4) {
            ForEach(model.top, id: \.pid) { s in
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.flagged.contains(s.pid) ? .red : (s.cpu >= model.threshold ? .orange : .clear))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.displayName).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text("pid \(s.pid)")
                            if let started = model.started(s) { Text(started) }
                            if s.isRoot { Text("root") }
                            if let hot = model.hotFor(s) { Text("hot \(hot)") }
                            policyBadge(model.policy(for: s))
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.0f%%", s.cpu))
                        .monospacedDigit()
                        .foregroundStyle(s.cpu >= model.threshold ? .red : .primary)
                    Menu {
                        policyButtons(for: s)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .menuStyle(.borderlessButton)
                    .tint(.blue)
                    .foregroundStyle(.blue)
                    .frame(width: 22)
                    .help("Rule for this process")
                    if Safety.canKillManually(s) {
                        KillButton(isRoot: s.isRoot) { model.kill(s) }
                    } else {
                        SudoButton(model: model, sample: s)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func policyButtons(for s: ProcessSample) -> some View {
        Button("Alert me (default)") { model.setPolicy(.alert, for: s) }
        Button("Auto-kill") { model.setPolicy(.autoKill, for: s) }
            .disabled(!Safety.canAutoKill(s))
        Button("Ignore for 1 hour") { model.setPolicy(.ignore(until: Date().addingTimeInterval(3600)), for: s) }
        Button("Always ignore") { model.setPolicy(.ignore(until: nil), for: s) }
        if !Safety.canAutoKill(s) {
            Text(s.isRoot ? "Auto-kill is off for root processes" : "Auto-kill is off for protected processes")
        }
    }
}

@ViewBuilder
func policyBadge(_ p: Policy) -> some View {
    switch p {
    case .alert: EmptyView()
    case .autoKill: Text("auto-kill").foregroundStyle(.red)
    case .ignore(let until?): Text("ignored until \(until.formatted(date: .omitted, time: .shortened))")
    case .ignore(nil): Text("ignored")
    }
}

struct RulesView: View {
    @ObservedObject var model: Model

    var body: some View {
        let rules = model.sentinel.policies.policies.sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 6) {
            if rules.isEmpty {
                Text("No rules yet. Every process alerts by default; set a rule from the Processes tab or a notification.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rules, id: \.key) { path, policy in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text((path as NSString).lastPathComponent).lineLimit(1)
                        policyBadge(policy).font(.caption2)
                    }
                    Spacer()
                    Button("Remove") {
                        model.sentinel.policies.set(.alert, for: path)
                        model.objectWillChange.send()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: Model

    var body: some View {
        let entries = model.sentinel.history.entries.suffix(15).reversed()
        VStack(alignment: .leading, spacing: 4) {
            if entries.isEmpty {
                Text("Nothing flagged or killed yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .top) {
                    Text(e.date.formatted(date: .omitted, time: .shortened)).monospacedDigit().frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(e.kind.rawValue): \(e.name) (\(Int(e.cpu))%)").lineLimit(1)
                        if !e.detail.isEmpty { Text(e.detail).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .font(.caption)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading) {
                Text("Bad actor: over \(Int(model.threshold))% CPU")
                Slider(value: $model.threshold, in: 30...400, step: 10)
                Text("100% is one full core; a process can use several.").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("for \(Model.duration(model.windowSeconds)) without a break")
                Slider(value: $model.windowSeconds, in: 30...900, step: 30)
            }
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            Text("Protected and never killable: WindowServer, kernel_task, launchd, loginwindow, Finder, Dock and other core macOS processes. Root processes can be killed by hand (asks for your password), never automatically. Auto-kill stops after 3 kills of the same app in an hour.")
                .font(.caption2).foregroundStyle(.secondary)
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
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(isRoot ? .orange : .red)
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
            Label("sudo", systemImage: "terminal.fill").font(.callout.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red, lineWidth: 1))
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

/// Heat colour for a CPU percentage: green, yellow, orange, red.
func heat(_ cpu: Double) -> Color {
    cpu < 10 ? .green : cpu < 40 ? .yellow : cpu < 80 ? .orange : .red
}

/// The heaviest CPU users over the last 24 hours, from `DailyUsage`.
struct DailyView: View {
    @ObservedObject var model: Model
    @AppStorage("dailyByApp") private var byApp = true

    var body: some View {
        let now = Date()
        let usage = model.sentinel.dailyUsage
        let rows = Array(usage.summaries(
            at: now,
            group: byApp ? { AppIdentity.groupKey(of: $0) } : nil,
            name: byApp ? { key in
                AppIdentity.bundlePath(of: key) != nil ? AppIdentity.appName(of: key) : (key as NSString).lastPathComponent
            } : nil).prefix(12))
        let maxSeconds = rows.first?.coreSeconds ?? 1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top CPU, last 24 hours").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("By app", isOn: $byApp).toggleStyle(.switch).controlSize(.mini)
            }
            HourBars(values: usage.totalHourly(at: now), height: 28)
            Text("\(Model.duration(usage.sampled(at: now))) recorded. Average is over the time CPU Sentinel was running.")
                .font(.caption2).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("Nothing recorded yet. Usage builds up while CPU Sentinel runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("by hour").frame(width: 96)
                Text("avg").frame(width: 44, alignment: .trailing)
                Text("peak").frame(width: 44, alignment: .trailing)
                Text("CPU time").frame(width: 64, alignment: .trailing)
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.element.key) { i, r in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
                    IconView(icon: IconCache.shared.icon(for: ProcessSample(pid: 0, uid: 501, cpu: 0, path: r.key)), size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).lineLimit(1).truncationMode(.middle)
                        GeometryReader { g in
                            Capsule().fill(heat(r.average).gradient)
                                .frame(width: max(3, g.size.width * r.coreSeconds / maxSeconds))
                        }
                        .frame(height: 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HourBars(values: r.hourly, height: 18).frame(width: 96)
                    Text(String(format: "%.1f%%", r.average)).foregroundStyle(heat(r.average)).frame(width: 44, alignment: .trailing)
                    Text(String(format: "%.0f%%", r.peak)).foregroundStyle(heat(r.peak)).frame(width: 44, alignment: .trailing)
                    Text(Model.duration(r.coreSeconds)).frame(width: 64, alignment: .trailing)
                        .help("Core time: 100% for one minute is 1m")
                }
                .font(.callout.monospacedDigit())
            }
        }
    }
}

/// 24 hourly bars, oldest on the left, each coloured by its heat.
struct HourBars: View {
    let values: [Double]
    let height: CGFloat

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(v > 0 ? heat(v) : Color.gray.opacity(0.2))
                    .frame(height: max(1, height * v / top))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}
