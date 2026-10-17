import AppKit
import SentinelCore
import SwiftUI

@main
struct CPUSentinelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // The menu bar draws SwiftUI images as monochrome templates, so the colour has to
            // be baked into a non-template NSImage.
            Image(nsImage: menuIcon)
            if let t = model.menuBarText { Text(t).monospacedDigit() }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: NSImage {
        let alert = model.level == .alert
        return Self.menuIcon(alert: alert, rag: LoadRAG.of(load: model.machineAverage(60), flagged: alert))
    }

    /// Green under 40% of the Mac over the last minute, amber to 70%, red above or when
    /// something is flagged.
    static func color(_ rag: LoadRAG) -> NSColor {
        switch rag {
        case .green: NSColor(srgbRed: 0.13, green: 0.63, blue: 0.33, alpha: 1)
        case .amber: NSColor(srgbRed: 0.93, green: 0.58, blue: 0.05, alpha: 1)
        case .red: NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)
        }
    }

    /// A solid coloured badge with a white chip glyph (a warning triangle when something is
    /// flagged): readable on light and dark menu bars, which a thin coloured outline symbol was not.
    static func menuIcon(alert: Bool, rag: LoadRAG? = nil) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let fill = color(rag ?? (alert ? .red : .green))
        let glyph = NSImage(systemSymbolName: alert ? "exclamationmark.triangle.fill" : "cpu", accessibilityDescription: "CPU Sentinel")?
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
    @State var tab: Tab = .overview
    /// Snapshots render the whole page instead of a scrolling window.
    var fullLength = false
    /// Shown in the movable window rather than under the menu bar icon.
    var inWindow = false

    static let width: CGFloat = 660
    /// Fixed, so switching tabs never resizes the window (a resize made the menu jump).
    static let contentHeight: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TabBar(selection: $tab, badges: [.events: model.flagged.count])
            Group {
                if fullLength {
                    page
                } else {
                    ScrollView(.vertical) { page.padding(.trailing, 2) }
                        .frame(height: Self.contentHeight)
                }
            }
            .overlay(alignment: .top) {
                if let t = model.toast { ToastView(toast: t) { model.toast = nil }.padding(.top, 6) }
            }
            .animation(.spring(duration: 0.3), value: model.toast)
            footer
        }
        .padding(14)
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: "cpu", color: Color(hex: "#dc2626"), size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("CPU Sentinel").font(.headline)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")  ·  \(Int(model.cores)) cores  ·  sampled every 5 s").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            let load = model.machineLoad
            HStack(spacing: 6) {
                Circle().fill(Theme.machineHeat(load)).frame(width: 8, height: 8)
                Text("\(Int(load))% of Mac").font(.callout.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.machineHeat(load).opacity(0.13)))
            .help("Share of all \(Int(model.cores)) cores in use right now")
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .overview: OverviewView(model: model)
        case .processes: ProcessesView(model: model)
        case .trends: TrendsView(model: model)
        case .memory: MemoryView(model: model)
        case .battery: BatteryView(model: model)
        case .events: EventsView(model: model)
        case .rules: RulesView(model: model)
        case .settings: SettingsView(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = model.lastError {
                Label(err, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Theme.heat(100)).lineLimit(2)
            } else if let msg = model.lastAction {
                Label(msg, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if !inWindow {
                FooterButton(title: "Pop out", symbol: "macwindow.on.rectangle", color: Tab.trends.color) {
                    PopOut.show(model)
                }
                .help("Open in a window you can move around and keep open")
            }
            FooterButton(title: "Activity Monitor", symbol: "waveform.path.ecg", color: Tab.processes.color) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            FooterButton(title: "Quit", symbol: "power", color: Tab.settings.color) {
                model.sentinel.dailyUsage.save()
                model.sentinel.recentUsage.save()
                model.powerHistory.save()
                model.memoryHistory.save()
                model.energyUsage.save()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

struct FooterButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(color.opacity(hover ? 0.2 : 0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RulesView: View {
    @ObservedObject var model: Model

    var body: some View {
        let rules = model.sentinel.policies.policies.sorted { $0.key < $1.key }
        let autoKill = rules.filter { $0.value.killsSometimes }.count
        let ignored = rules.filter { if case .ignore = $0.value { return true }; if case .ignoreDuring = $0.value { return true }; return false }.count
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                StatTile(symbol: "bolt.fill", color: Theme.heat(100), value: "\(autoKill)", label: "auto-kill")
                StatTile(symbol: "moon.fill", color: Tab.rules.color, value: "\(ignored)", label: "ignored")
                StatTile(symbol: "bell.fill", color: Tab.events.color, value: "Alert", label: "everything else")
            }
            Card(title: "Rules", symbol: "slider.horizontal.3", tint: Tab.rules.color) {
                if rules.isEmpty {
                    Text("No rules yet. Every process alerts by default. Right-click a process on the Processes tab, or use a notification's buttons, to set one.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rules, id: \.key) { path, policy in
                    HStack(spacing: 10) {
                        IconView(icon: IconCache.shared.icon(for: ProcessSample(pid: 0, uid: 501, cpu: 0, path: path)), size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((path as NSString).lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        rulePill(policy)
                        FooterButton(title: "Remove", symbol: "trash", color: Theme.heat(100)) {
                            model.sentinel.policies.set(.alert, for: path)
                            model.objectWillChange.send()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            BackgroundItemsCard(model: model)
        }
    }

    @ViewBuilder
    private func rulePill(_ p: Policy) -> some View {
        switch p {
        case .alert: Pill(text: "alert", symbol: "bell.fill", color: Tab.events.color)
        case .ignore, .ignoreDuring: Pill(text: p.label, symbol: "moon.fill", color: Tab.rules.color)
        default: Pill(text: p.label, symbol: p == .autoKill ? "bolt.fill" : "battery.50percent", color: Theme.heat(p == .autoKill ? 100 : 80))
        }
    }

}

/// Every setting on this tab is a draft until Save, so dragging a slider past the value you
/// wanted does not change detection halfway through, and nothing here applies on its own.
struct SettingsDraft: Equatable {
    var threshold: Double
    var window: Double
    var login: Bool
    var menuBarShows: String
    var alertHeat: Bool
    var heatWatts: Double
    var heatMinutes: Double
    var alertBlockers: Bool
    var blockerHours: Double
    var weeklyReport: Bool

    @MainActor init(_ m: Model) {
        threshold = m.threshold; window = m.windowSeconds; login = m.launchAtLogin
        menuBarShows = m.menuBarShows; alertHeat = m.alertHeat; heatWatts = m.heatWatts; heatMinutes = m.heatMinutes
        alertBlockers = m.alertBlockers; blockerHours = m.blockerHours; weeklyReport = m.weeklyReport
    }

    @MainActor func apply(to m: Model) {
        m.threshold = threshold; m.windowSeconds = window
        if login != m.launchAtLogin { m.launchAtLogin = login }
        m.menuBarShows = menuBarShows; m.alertHeat = alertHeat; m.heatWatts = heatWatts; m.heatMinutes = heatMinutes
        m.alertBlockers = alertBlockers; m.blockerHours = blockerHours; m.weeklyReport = weeklyReport
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var edits: SettingsDraft?

    private var draft: Binding<SettingsDraft> {
        Binding(get: { edits ?? SettingsDraft(model) }, set: { edits = $0 })
    }
    private var t: Double { draft.wrappedValue.threshold }
    private var w: Double { draft.wrappedValue.window }
    private var dirty: Bool { edits.map { $0 != SettingsDraft(model) } ?? false }

    var body: some View {
        VStack(spacing: 10) {
            Card(title: "When is a process a bad actor?", symbol: "flame.fill", tint: Theme.heat(100)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Over")
                        Text("\(Int(t))% CPU").font(.body.weight(.bold)).foregroundStyle(Theme.heat(t))
                        Spacer()
                        Text(Insights.fmtCores(t)).font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: draft.threshold, in: 30...400, step: 10).tint(Theme.heat(t))
                    Text("100% is one full core; a process can use several.").font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("for")
                        Text(Model.duration(w)).font(.body.weight(.bold)).foregroundStyle(Tab.events.color)
                        Text("without a break")
                    }
                    Slider(value: draft.window, in: 30...900, step: 30).tint(Tab.events.color)
                    Text("Short bursts never count; only a process that stays over the line the whole time.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Card(title: "Startup", symbol: "power", tint: Tab.processes.color) {
                Toggle("Launch CPU Sentinel at login", isOn: draft.login)
                    .toggleStyle(.switch)
                Text("Trends and insights only cover the time CPU Sentinel is running.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            MenuBarSettingsCard(model: model, draft: draft)
            Card(title: "Reports", symbol: "calendar.badge.clock", tint: Tab.events.color) {
                Toggle("Weekly report notification, Monday morning", isOn: draft.weeklyReport).toggleStyle(.switch)
                Text("Top apps, CPU hours, time on battery and average power draw for the last 7 days. The same report is always on the Events tab.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if dirty {
                    Label("Unsaved changes", systemImage: "pencil.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Tab.events.color)
                }
                Spacer()
                Button("Revert") { edits = nil }
                    .disabled(!dirty)
                Button {
                    edits?.apply(to: model)
                    edits = nil
                    model.lastAction = "Settings saved"
                } label: {
                    Label("Save", systemImage: "checkmark").frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tab.rules.color)
                .keyboardShortcut(.defaultAction)
                .disabled(!dirty)
            }
            Card(title: "Safety", symbol: "shield.lefthalf.filled", tint: Tab.settings.color) {
                Text("Protected and never killed automatically: WindowServer, kernel_task, launchd, loginwindow, Finder, Dock and other core macOS processes; these get a sudo button instead. Root processes can be killed by hand (asks for your password), never automatically. Auto-kill stops after 3 kills of the same app in an hour.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// `--snapshot <dir>`: renders every tab, light and dark, to PNG files and quits. Used to
/// check the design without clicking through the menu.
@MainActor
enum Snapshot {
    static func run(_ model: Model, into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The exported report, both formats, through the same code as the Export buttons.
        let doc = model.reportDocument()
        try? doc.markdown.write(to: URL(fileURLWithPath: dir).appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        try? ReportPDF.write(doc, to: URL(fileURLWithPath: dir).appendingPathComponent("report.pdf"))
        for alert in [false, true] {
            let icon = CPUSentinelApp.menuIcon(alert: alert)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 72, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: 96, height: 72))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("menubar-\(alert ? "alert" : "normal").png"))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for tab in Tab.allCases {
                let view = MenuView(model: model, tab: tab, fullLength: true)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuView.width, height: 400),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: appearance)
                win.contentView = host
                let size = host.fittingSize
                win.setContentSize(size)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "\(tab.rawValue)-\(tab.title.lowercased())-\(appearance == .aqua ? "light" : "dark").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        // The zoomed chart windows too.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let zooms: [(String, AnyView, NSSize)] = [
                ("zoom-now", AnyView(NowDonut(model: model, zoomed: true)), NSSize(width: 760, height: 440)),
                ("zoom-lasthour", AnyView(LastHourChart(model: model, zoomed: true)), NSSize(width: 960, height: 600)),
            ]
            for (name, view, size) in zooms {
                let host = NSHostingView(rootView: view.padding(14).frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: appearance)
                let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: appearance)
                win.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        exit(0)
    }
}

/// Opening the app from Finder, Launchpad or Spotlight shows its window: at once when it
/// was not running, and brought to the front when it was. A launch at login stays in the
/// menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var atLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == kAEOpenApplication,
           e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            atLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !atLogin, Model.snapshotDir == nil else { return }
        // The model is created with the menu bar scene; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let m = Model.current { PopOut.show(m) } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let m = Model.current { PopOut.show(m) }
        return true
    }
}

/// The same screens in an ordinary window, which can be dragged anywhere and stays open;
/// a menu bar panel is pinned under its icon and closes when you click away.
@MainActor
enum PopOut {
    private static var window: NSWindow?

    static func show(_ model: Model) {
        if window == nil {
            let host = NSHostingController(rootView: MenuView(model: model, inWindow: true))
            let w = NSWindow(contentViewController: host)
            w.title = "CPU Sentinel"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("CPUSentinelWindow")
            if !w.setFrameUsingName("CPUSentinelWindow") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The result of a kill, over the top of the page where it cannot be missed: green when the
/// process stopped, red when it did not, with what to do when it was relaunched at once.
struct ToastView: View {
    let toast: Model.Toast
    let close: () -> Void

    var body: some View {
        let color = toast.ok ? Theme.heat(0) : Theme.heat(100)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title).font(.callout.weight(.semibold))
                if let d = toast.detail {
                    Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
