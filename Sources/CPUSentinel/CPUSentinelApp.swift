import SentinelCore
import SwiftUI

@main
struct CPUSentinelApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: icon)
                .symbolRenderingMode(.palette)
                .foregroundStyle(color)
        }
        .menuBarExtraStyle(.window)
    }

    private var icon: String {
        switch model.level {
        case .normal: return "gauge.with.dots.needle.33percent"
        case .busy: return "gauge.with.dots.needle.67percent"
        case .alert: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch model.level {
        case .normal: return .primary
        case .busy: return .orange
        case .alert: return .red
        }
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 440)
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
                    .frame(width: 22)
                    .help("Rule for this process")
                    if Safety.canKillManually(s) {
                        Button("Kill") { model.kill(s) }
                            .help(s.isRoot ? "Runs as root: asks for your password" : "Stop politely, force after 5 s")
                    } else {
                        Text("protected").font(.caption2).foregroundStyle(.secondary).frame(width: 52)
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
