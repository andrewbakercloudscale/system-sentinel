import AppKit
import CoreGraphics
import SentinelCore
import SwiftUI

/// Applies and undoes the `Tweaks`, remembering what each setting was before.
@MainActor
final class TweakStore: ObservableObject {
    static let shared = TweakStore()

    /// What each setting is now; nil when not set (macOS's default applies).
    @Published private(set) var current: [String: Tweak.Value?] = [:]
    @Published private(set) var backup = TweakBackup()
    @Published private(set) var message: [String: (ok: Bool, text: String)] = [:]
    @Published private(set) var displays: [DisplayPixels] = []
    @Published private(set) var windows: [(app: String, count: Int)] = []
    @Published private(set) var working = false

    nonisolated static var backupURL: URL { NetworkStore.supportDir.appendingPathComponent("tweaks-backup.json") }

    init() {
        if let d = try? Data(contentsOf: Self.backupURL), let b = try? JSONDecoder().decode(TweakBackup.self, from: d) { backup = b }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            var now: [String: Tweak.Value?] = [:]
            for t in Tweaks.all { now[t.id] = .some(Self.read(t)) }
            let shown = DisplayPixels.parse(Data(sh("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], timeout: 15).utf8))
            let wins = Self.windowsOnScreen()
            await MainActor.run {
                self.current = now
                self.displays = shown
                self.windows = wins
            }
        }
    }

    func value(_ t: Tweak) -> Tweak.Value? { current[t.id] ?? nil }
    func isOptimised(_ t: Tweak) -> Bool { t.isOptimised(value(t)) }
    func canUndo(_ t: Tweak) -> Bool { backup.has(t.id) }

    // MARK: Apply and undo

    func apply(_ list: [Tweak]) {
        let todo = list.filter { !isOptimised($0) }
        guard !todo.isEmpty, !working else { return }
        working = true
        Task.detached(priority: .userInitiated) {
            var results: [String: (Bool, String)] = [:]
            var saved: [(String, Tweak.Value?)] = []
            for t in todo {
                let was = Self.read(t)
                _ = sh("/usr/bin/defaults", t.hostArgs + ["write", t.domain, t.key] + t.better.args, timeout: 5)
                let now = Self.read(t)
                if t.isOptimised(now) {
                    saved.append((t.id, was))
                    results[t.id] = (true, "Done. Shows \(t.takes.text).")
                } else {
                    results[t.id] = (false, "macOS did not accept the change" + (t.settingsURL == nil ? "." : ": switch it in System Settings instead."))
                    Diagnostics.report("optimise", "Could not set \(t.domain) \(t.key)")
                }
            }
            Self.restart(for: todo.filter { results[$0.id]?.0 == true })
            await MainActor.run {
                for (id, was) in saved { self.backup.save(id, was: was, at: Date()) }
                for (id, r) in results { self.message[id] = r }
                self.saveBackup()
                self.working = false
                self.refresh()
            }
        }
    }

    func undo(_ list: [Tweak]) {
        let todo = list.filter { backup.has($0.id) }
        guard !todo.isEmpty, !working else { return }
        working = true
        let plans = todo.map { ($0, TweakUndo.plan(backup.original($0.id) ?? nil)) }
        Task.detached(priority: .userInitiated) {
            var done: [String] = []
            for (t, plan) in plans {
                switch plan {
                case .write(let v): _ = sh("/usr/bin/defaults", t.hostArgs + ["write", t.domain, t.key] + v.args, timeout: 5)
                case .delete: _ = sh("/usr/bin/defaults", t.hostArgs + ["delete", t.domain, t.key], timeout: 5)
                }
                done.append(t.id)
            }
            Self.restart(for: todo)
            await MainActor.run {
                for id in done {
                    self.backup.forget(id)
                    if let t = Tweaks.named(id) { self.message[id] = (true, "Put back as it was. Shows \(t.takes.text).") }
                }
                self.saveBackup()
                self.working = false
                self.refresh()
            }
        }
    }

    private func saveBackup() {
        if let d = try? JSONEncoder().encode(backup) { Diagnostics.write(d, to: Self.backupURL, what: "the optimise undo list") }
    }

    nonisolated static func read(_ t: Tweak) -> Tweak.Value? {
        Tweak.Value.parse(sh("/usr/bin/defaults", t.hostArgs + ["read", t.domain, t.key], timeout: 5), like: t.better)
    }

    /// Restarts what has to restart for the changes to show. Each comes straight back.
    nonisolated static func restart(for list: [Tweak]) {
        let takes = Set(list.map(\.takes))
        if takes.contains(.dock) { _ = sh("/usr/bin/killall", ["Dock"], timeout: 5) }
        if takes.contains(.finder) { _ = sh("/usr/bin/killall", ["Finder"], timeout: 5) }
        if takes.contains(.windowManager) { _ = sh("/usr/bin/killall", ["WindowManager"], timeout: 5) }
    }

    /// Ordinary windows on screen, by app: each is drawn into the picture WindowServer composites.
    nonisolated static func windowsOnScreen() -> [(app: String, count: Int)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var count: [String: Int] = [:]
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let owner = w[kCGWindowOwnerName as String] as? String { count[owner, default: 0] += 1 }
        }
        return count.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }
}

/// The optimiser in its own window: settings that make WindowServer draw less, each with an
/// undo, plus what else on this Mac adds to its work.
@MainActor
enum OptimiseWindow {
    private static var window: NSWindow?

    static func show(_ model: Model) {
        TweakStore.shared.refresh()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OptimiseView(model: model, store: .shared)))
            w.title = "Optimise the screen"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 760))
            w.setFrameAutosaveName("OptimiseWindow")
            if !w.setFrameUsingName("OptimiseWindow") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private let optTint = Tab.processes.color
private let okColor = Tab.battery.color
private let amber = Color(hex: "#d97706")

struct OptimiseView: View {
    @ObservedObject var model: Model
    @ObservedObject var store: TweakStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Card(title: "Draw less", symbol: "wand.and.stars", tint: optTint,
                     trailing: AnyView(HStack(spacing: 8) {
                         if store.working { ProgressView().controlSize(.small) }
                         Button("Undo all") { store.undo(Tweaks.windowServer) }
                             .disabled(!Tweaks.windowServer.contains { store.canUndo($0) })
                         Button("Optimise all") { store.apply(Tweaks.windowServer) }.keyboardShortcut(.defaultAction)
                             .disabled(Tweaks.windowServer.allSatisfy { store.isOptimised($0) })
                     })) {
                    ForEach(Tweaks.windowServer) { t in TweakRow(tweak: t, store: store) }
                }
                ScreenDisplaysCard(store: store)
                WindowsCard(store: store)
                Card(title: "Menu bar icons hidden behind the notch", symbol: "menubar.rectangle", tint: optTint,
                     trailing: AnyView(Button("Fit more icons") { store.apply(Tweaks.menuBar) }
                        .disabled(Tweaks.menuBar.allSatisfy { store.isOptimised($0) }))) {
                    ForEach(Tweaks.menuBar) { t in TweakRow(tweak: t, store: store) }
                }
                Text("Each change is a macOS setting; System Sentinel keeps what it was before, so Undo puts back exactly that. Nothing here is permanent or risky. The Dock, Finder or window manager restart for a second where a change needs it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        let ws = model.sentinel.latest.first { $0.name == "WindowServer" }
        let avg = ws.map { model.average($0, 900) }
        return HStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 30)).foregroundStyle(optTint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Make WindowServer lighter").font(.title3.weight(.semibold))
                Text("WindowServer draws every window, the menu bar and the Dock into the picture on your screens. Its work grows with pixels, transparency, animation and open windows.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let ws {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.pct(ws.cpu)).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(Theme.heat(ws.cpu))
                    Text("now · \(Fmt.pct(avg ?? 0)) over 15 min").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TweakRow: View {
    let tweak: Tweak
    @ObservedObject var store: TweakStore

    var body: some View {
        let on = store.isOptimised(tweak)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? okColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tweak.title).font(.callout.weight(.semibold))
                        Text(String(repeating: "●", count: tweak.impact) + String(repeating: "○", count: 3 - tweak.impact))
                            .font(.caption).foregroundStyle(optTint).help("How much it helps")
                    }
                    Text(tweak.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(on ? (store.canUndo(tweak) ? "On, set by System Sentinel" : "Already on") : "Off. Takes effect \(tweak.takes.text).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if store.canUndo(tweak) {
                    Button("Undo") { store.undo([tweak]) }
                }
                if !on {
                    Button("Apply") { store.apply([tweak]) }
                }
                if let url = tweak.settingsURL {
                    Button { NSWorkspace.shared.open(URL(string: url)!) } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Open the same setting in System Settings")
                }
            }
            if let m = store.message[tweak.id] {
                Label(m.text, systemImage: m.ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(m.ok ? okColor : Theme.heat(100)).padding(.leading, 26)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ScreenDisplaysCard: View {
    @ObservedObject var store: TweakStore
    var body: some View {
        Card(title: "Displays", symbol: "display.2", tint: optTint,
             trailing: AnyView(Button("Display settings") { NSWorkspace.shared.open(URL(string: FixAction.Settings.displays.url)!) })) {
            if store.displays.isEmpty { Text("Reading displays…").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(store.displays.enumerated()), id: \.offset) { _, d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(d.name).font(.callout.weight(.semibold))
                        if d.builtIn { Text("built in").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("draws \(d.rendered.w) × \(d.rendered.h)" + (d.hz.map { String(format: " at %.0f Hz", $0) } ?? ""))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let o = d.overdraw, o > 1.05, let n = d.native {
                        Label(String(format: "Scaled: draws %.0f%% more pixels than the panel's %d × %d, then shrinks each frame. The Default resolution in Display settings draws exactly the panel's pixels.", (o - 1) * 100, n.w, n.h),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(amber).fixedSize(horizontal: false, vertical: true)
                    } else if let hz = d.hz, hz > 60 {
                        Label(String(format: "%.0f Hz redraws more often than 60 Hz. Unless you need it for games or video, 60 Hz cuts the work.", hz),
                              systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Draws its own pixels, nothing to change.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(okColor)
                    }
                }
            }
        }
    }
}

private struct WindowsCard: View {
    @ObservedObject var store: TweakStore
    var body: some View {
        let total = store.windows.reduce(0) { $0 + $1.count }
        Card(title: "Windows on screen: \(total)", symbol: "macwindow.on.rectangle", tint: optTint) {
            Text("Each visible window is part of every frame. Minimised and hidden windows cost nothing; closing ones you are not using, or hiding an app (⌘H), lightens the load. Video and animation in any of them cost the most.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(store.windows.prefix(8), id: \.app) { w in
                HStack {
                    Text(w.app).font(.callout)
                    Spacer()
                    Text("\(w.count)").font(.callout.monospacedDigit().weight(.semibold))
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == w.app }), app.activationPolicy == .regular {
                        Button("Hide") { app.hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.refresh() } }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }
}
