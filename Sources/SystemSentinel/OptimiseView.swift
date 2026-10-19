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
    /// The built-in display's resolution now, and the one that draws exactly its pixels.
    @Published private(set) var mode: ModeSize?
    @Published private(set) var exactMode: ModeSize?
    /// The resolution before "Use exact pixels", for Undo.
    @Published private(set) var modeBefore: ModeSize? = TweakStore.loadModeBefore()

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
                self.readModes(native: shown.first { $0.builtIn }?.native)
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

    // MARK: Resolution of the built-in display

    nonisolated static var builtIn: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    nonisolated static func modes(_ d: CGDirectDisplayID) -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return ((CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []).filter { $0.isUsableForDesktopGUI() }
    }

    nonisolated static func size(_ m: CGDisplayMode) -> ModeSize { ModeSize(w: m.width, h: m.height, pixelW: m.pixelWidth, pixelH: m.pixelHeight) }

    private func readModes(native: (w: Int, h: Int)?) {
        guard let d = Self.builtIn, let cur = CGDisplayCopyDisplayMode(d) else { mode = nil; exactMode = nil; return }
        mode = Self.size(cur)
        let all = Self.modes(d).map(Self.size)
        let n = native ?? (cur.pixelWidth, cur.pixelHeight)
        exactMode = ModeSize.exact(in: all, native: n).map { all[$0] }
    }

    /// Switches the built-in display to the resolution that draws exactly its pixels.
    func useExactPixels() {
        guard let d = Self.builtIn, let cur = CGDisplayCopyDisplayMode(d), let want = exactMode,
              let target = Self.modes(d).first(where: { Self.size($0) == want }) else { return }
        let before = Self.size(cur)
        if setMode(d, target) {
            modeBefore = before
            UserDefaults.standard.set([before.w, before.h, before.pixelW, before.pixelH], forKey: "displayModeBefore")
            message["resolution"] = (true, "Now looks like \(want.w) × \(want.h). Undo puts back \(before.w) × \(before.h).")
        } else {
            message["resolution"] = (false, "macOS did not switch the resolution. Pick it in Display settings instead.")
        }
        refresh()
    }

    func restoreMode() {
        guard let d = Self.builtIn, let before = modeBefore,
              let target = Self.modes(d).first(where: { Self.size($0) == before }) else { return }
        if setMode(d, target) {
            modeBefore = nil
            UserDefaults.standard.removeObject(forKey: "displayModeBefore")
            message["resolution"] = (true, "Back to \(before.w) × \(before.h).")
        }
        refresh()
    }

    private func setMode(_ d: CGDirectDisplayID, _ m: CGDisplayMode) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, d, m, nil)
        let ok = CGCompleteDisplayConfiguration(config, .permanently) == .success
        if !ok { Diagnostics.report("optimise", "Could not switch the display to \(m.width) × \(m.height)") }
        return ok
    }

    nonisolated static func loadModeBefore() -> ModeSize? {
        guard let a = UserDefaults.standard.array(forKey: "displayModeBefore") as? [Int], a.count == 4 else { return nil }
        return ModeSize(w: a[0], h: a[1], pixelW: a[2], pixelH: a[3])
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
    @StateObject private var tips = TipCenter()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Card(title: "Draw less", symbol: "wand.and.stars", tint: optTint,
                     trailing: AnyView(HStack(spacing: 8) {
                         if store.working { ProgressView().controlSize(.small) }
                         Button("Undo all") { askUndo(Tweaks.windowServer.filter { store.canUndo($0) }, store) }
                             .tip("Put back every setting System Sentinel changed here, exactly as it was")
                             .disabled(!Tweaks.windowServer.contains { store.canUndo($0) })
                         Button("Optimise all") { askApply(Tweaks.windowServer.filter { !store.isOptimised($0) }, store) }.keyboardShortcut(.defaultAction)
                             .tip("Apply every setting below that is not on yet. Each can be undone")
                             .disabled(Tweaks.windowServer.allSatisfy { store.isOptimised($0) })
                     })) {
                    ForEach(Tweaks.windowServer) { t in TweakRow(tweak: t, store: store) }
                }
                ScreenDisplaysCard(store: store)
                WindowsCard(store: store)
                Card(title: "Menu bar icons hidden behind the notch", symbol: "menubar.rectangle", tint: optTint,
                     trailing: AnyView(Button("Fit more icons") { askApply(Tweaks.menuBar.filter { !store.isOptimised($0) }, store) }
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
        .tipsAndConfirmations(tips, surface: "optimise")
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

/// Asks before changing settings: which ones, when each takes effect, and that Undo exists.
@MainActor
private func askApply(_ list: [Tweak], _ store: TweakStore) {
    guard !list.isEmpty else { return }
    var points = list.map { "\($0.title): takes effect \($0.takes.text)." }
    let restarts = Set(list.map(\.takes)).compactMap { t -> String? in
        switch t { case .dock: "the Dock"; case .finder: "Finder"; case .windowManager: "the window manager"; default: nil }
    }
    if !restarts.isEmpty { points.append("\(restarts.joined(separator: " and ").capitalizingFirst) restart\(restarts.count == 1 ? "s" : "") for a second.") }
    Confirm.ask(list.count == 1 ? "\(list[0].title)?" : "Apply \(list.count) settings?", "These are ordinary macOS settings.",
                symbol: "wand.and.stars", tint: optTint, points: points,
                undo: "System Sentinel keeps what each was before: Undo puts back exactly that.",
                button: list.count == 1 ? "Apply" : "Apply \(list.count)", surface: "optimise") { store.apply(list) }
}

@MainActor
private func askUndo(_ list: [Tweak], _ store: TweakStore) {
    guard !list.isEmpty else { return }
    Confirm.ask(list.count == 1 ? "Undo \(list[0].title.lowercased())?" : "Undo \(list.count) settings?",
                "Each goes back to exactly what it was before System Sentinel changed it.",
                symbol: "arrow.uturn.backward.circle.fill", tint: optTint, points: list.map(\.title),
                button: "Undo", surface: "optimise") { store.undo(list) }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
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
                            .font(.caption).foregroundStyle(optTint).tip("How much it helps")
                    }
                    Text(tweak.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(on ? (store.canUndo(tweak) ? "On, set by System Sentinel" : "Already on") : "Off. Takes effect \(tweak.takes.text).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if store.canUndo(tweak) {
                    Button("Undo") { askUndo([tweak], store) }.tip("Put this setting back exactly as it was before")
                }
                if !on {
                    Button("Apply") { askApply([tweak], store) }.tip("Turn this on. Undo puts back what it was")
                }
                if let url = tweak.settingsURL {
                    Button { NSWorkspace.shared.open(URL(string: url)!) } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).tip("Open the same setting in System Settings")
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
                    if d.builtIn, let back = store.modeBefore, let now = store.mode, now != back {
                        HStack(alignment: .firstTextBaseline) {
                            Label("Draws exactly the panel's pixels (looks like \(now.w) × \(now.h)).", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(okColor)
                            Spacer()
                            Button(String("Undo: back to \(back.w) × \(back.h)")) {
                                Confirm.ask("Back to looks like \(back.w) × \(back.h)?", "Puts the built-in display back to the resolution it had before.",
                                            symbol: "arrow.uturn.backward.circle.fill", tint: optTint, button: "Switch back", surface: "optimise") { store.restoreMode() }
                            }
                        }
                    } else if let o = d.overdraw, o > 1.05, let n = d.native {
                        let lk = d.looksLike.map { "\($0.w) × \($0.h)" } ?? "this size"
                        Text(String(format: "Nothing is wrong: this is a scaled size (looks like %@), which on many MacBooks is Apple's Default. macOS draws it at %d × %d and shrinks that to the panel's %d × %d each frame, %.0f%% extra pixels.", lk, d.rendered.w, d.rendered.h, n.w, n.h, (o - 1) * 100))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if d.builtIn, let e = store.exactMode, let now = store.mode {
                            HStack(alignment: .firstTextBaseline) {
                                Text(String(format: "Optional: looks like %d × %d draws exactly the panel's pixels and is the sharpest, but everything is about %.0f%% larger. Only worth it if WindowServer stays high.", e.w, e.h, now.growth(to: e) * 100))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button(String("Use \(e.w) × \(e.h)")) {
                                    Confirm.ask("Switch to looks like \(e.w) × \(e.h)?", "The built-in display draws exactly its own pixels: the sharpest picture and the least work for WindowServer.",
                                                symbol: "display", tint: optTint,
                                                points: [String(format: "Everything on screen gets about %.0f%% larger, so less fits.", now.growth(to: e) * 100),
                                                         "The screen flickers once while it switches."],
                                                undo: "An Undo button appears here; Display settings can change it back too.",
                                                button: "Switch", surface: "optimise") { store.useExactPixels() }
                                }
                                .tip("Change the built-in display's resolution. Asks first")
                            }
                        }
                    } else if let hz = d.hz, hz > 60 {
                        Label(String(format: "%.0f Hz redraws more often than 60 Hz. Unless you need it for games or video, 60 Hz cuts the work.", hz),
                              systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Draws its own pixels, nothing to change.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(okColor)
                    }
                }
            }
            if let m = store.message["resolution"] {
                Label(m.text, systemImage: m.ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(m.ok ? okColor : Theme.heat(100))
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
                        Button("Hide") {
                            Confirm.ask("Hide \(w.app)?", "Its \(w.count) window\(w.count == 1 ? "" : "s") leave the screen, as ⌘H would. It keeps running.",
                                        symbol: "eye.slash.fill", tint: optTint, undo: "Click its icon in the Dock to show it again.",
                                        button: "Hide", surface: "optimise") {
                                app.hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.refresh() }
                            }
                        }
                        .tip("Hide this app's windows, as ⌘H would")
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }
}
