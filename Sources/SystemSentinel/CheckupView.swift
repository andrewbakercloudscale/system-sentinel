import SentinelCore
import SwiftUI

/// Checkup: what is wrong (found on its own, or picked from a list of symptoms), then security
/// posture, network doctor, leftovers and crashes, backups, each with a fix,
/// and a toolbox of the everyday restarts.
struct CheckupView: View {
    @ObservedObject var model: Model
    @ObservedObject var store: CheckupStore
    @State private var open: Set<String> = []
    /// Snapshots show one symptom open, so the screenshot shows what a panel looks like.
    @State private var symptom: Symptom? = Model.snapshotDir == nil ? nil : .slow

    var body: some View {
        VStack(spacing: 10) {
            hero
            SymptomsCard(model: model, store: store, open: $symptom) { AnyView(row($0)) }
            ForEach(Check.Area.allCases, id: \.self) { area in
                let list = store.checks.filter { $0.area == area }
                if !list.isEmpty {
                    Card(title: area.rawValue, symbol: area.symbol, tint: Tab.checkup.color,
                         trailing: AnyView(summary(list))) {
                        ForEach(list) { c in row(c) }
                    }
                }
            }
            toolbox
        }
    }

    private var hero: some View {
        let a = model.attention()
        let problems = a.problems
        let warnings = a.count - a.problems
        let ok = store.checks.filter { $0.status == .ok }.count
        let colors: [Color] = problems > 0 ? [Color(hex: "#b91c1c"), Color(hex: "#9f1239")]
            : warnings > 0 ? [Color(hex: "#b45309"), Color(hex: "#c2410c")] : [Color(hex: "#047857"), Color(hex: "#0f766e")]
        return HStack(spacing: 16) {
            Image(systemName: problems + warnings == 0 ? "checkmark.seal.fill" : "stethoscope")
                .font(.system(size: 40, weight: .semibold)).foregroundStyle(.white).frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.checks.isEmpty ? "Running the checkup…" : problems + warnings == 0 ? "All \(ok) checks passed" : "\(problems + warnings) thing\(problems + warnings == 1 ? "" : "s") to look at")
                    .font(.title3.weight(.bold)).foregroundStyle(.white)
                Text("Performance, startup items, crashes, network, backups and security. \(store.ranAt.map { "Checked \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())); again every 6 hours." } ?? "")")
                    .font(.callout).foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            Button { store.run() } label: {
                Group {
                    if store.running { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") } }
                    else { Label("Check again", systemImage: "arrow.clockwise") }
                }
                .font(.callout.weight(.semibold)).foregroundStyle(colors[0])
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .tip("Run every check again now")
            .disabled(store.running)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func summary(_ list: [Check]) -> some View {
        let bad = list.filter { $0.status >= .warning }.count
        return Text(bad == 0 ? "all good" : "\(bad) to look at").font(.caption.weight(.semibold))
            .foregroundStyle(bad == 0 ? Tab.battery.color : Color(hex: "#d97706"))
    }

    private func color(_ s: Check.Status) -> Color {
        switch s {
        case .ok: return Tab.battery.color
        case .info: return Tab.processes.color
        case .warning: return Color(hex: "#d97706")
        case .problem: return Theme.heat(100)
        }
    }

    private func symbol(_ s: Check.Status) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    private func row(_ c: Check) -> some View {
        let expandable = c.why != nil || !c.steps.isEmpty || !c.items.isEmpty
        let isOpen = open.contains(c.id) || (Model.snapshotDir != nil && c.status >= .warning)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(c.status)).font(.title3).foregroundStyle(color(c.status)).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.callout.weight(.semibold))
                    Text(c.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if expandable {
                    Button { if open.contains(c.id) { open.remove(c.id) } else { open.insert(c.id) } } label: {
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tip(isOpen ? "Hide the details" : "Show the details")
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    if let why = c.why { Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(Array(c.steps.enumerated()), id: \.offset) { i, s in
                        Text("\(i + 1). \(s)").font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(c.items.prefix(12), id: \.self) { i in
                        Text("• " + i).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    if c.items.count > 12 { Text("and \(c.items.count - 12) more").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.leading, 32)
            }
            if !c.fixes.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(c.fixes.enumerated()), id: \.offset) { _, f in fixButton(f, c) }
                }
                .padding(.leading, 32)
            }
            if !c.actions.isEmpty {
                FixButtons(model: model, fixes: c.actions).padding(.leading, 32)
            }
        }
        .padding(.vertical, 2)
    }

    private func fixButton(_ f: Check.Fix, _ c: Check) -> some View {
        let busy = store.working.contains(c.id + f.label)
        let acts: Bool = { switch f { case .admin, .run, .removeAgent: return true; default: return false } }()
        return Button {
            if acts {
                Confirm.ask("\(f.label)?", c.title, symbol: "wrench.and.screwdriver.fill", tint: Tab.checkup.color,
                            points: [help(f)], undo: undoText(f), button: f.label) { store.perform(f, in: c) }
            } else {
                store.perform(f, in: c)
            }
        } label: {
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.mini) }
                if case .admin = f, !busy { Image(systemName: "lock.fill") }
                Text(busy ? "Working…" : f.label)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(acts ? .white : Tab.checkup.color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(acts ? AnyShapeStyle(Tab.checkup.color.gradient) : AnyShapeStyle(Tab.checkup.color.opacity(0.13))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .tip(help(f))
    }

    private func undoText(_ f: Check.Fix) -> String? {
        switch f {
        case .removeAgent: return "It goes to the Trash: put it back from there to undo."
        case .admin, .run: return "Most of these restart something that comes straight back by itself."
        default: return nil
        }
    }

    private func help(_ f: Check.Fix) -> String {
        switch f {
        case .admin(_, let cmd): return "Asks for your admin password, then runs: \(cmd.rawValue)"
        case .run(_, let path, let args): return "Runs: \(([path] + args).joined(separator: " "))"
        case .settings: return "Opens System Settings at the right place."
        case .reveal(_, let p): return "Shows \(p) in Finder."
        case .web(_, let u): return "Opens \(u)"
        case .removeAgent(_, let plist, _): return "Stops it and moves \(plist) to the Trash. Put it back from the Trash to undo."
        }
    }

    private var toolbox: some View {
        Card(title: "Quick fixes", symbol: "wrench.and.screwdriver.fill", tint: Tab.checkup.color) {
            let pseudo = Check(id: "toolbox", area: .system, title: "", status: .info, detail: "")
            ForEach(CheckupStore.toolbox, id: \.title) { t in
                HStack(spacing: 10) {
                    SymbolTile(symbol: t.symbol, color: Tab.checkup.color, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.callout.weight(.semibold))
                        Text(t.about).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    fixButton(t.fix, pseudo)
                }
            }
            Text("Buttons with a lock ask for your admin password and show the exact command when you hover. Nothing here turns a security setting off.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
