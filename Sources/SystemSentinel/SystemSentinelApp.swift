import AppKit
import ApplicationServices
import SentinelCore
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct SystemSentinelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()
    @ObservedObject private var bar = MenuBarState.shared

    init() {
        SelfGuard.start()
        MenuBarState.placeRight()
        // Before Model reads any settings.
        Migration.fromCPUSentinel()
    }

    var body: some Scene {
        // Set only on a real change: SwiftUI writes the binding back on every update, and a
        // @Published that fires on each write keeps the scene updating forever.
        MenuBarExtra(isInserted: Binding(get: { bar.inserted }, set: { if bar.inserted != $0 { bar.inserted = $0 } })) {
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
        let h = model.health
        // The glyph names the worst risk: chip, memory, disk, heat or battery.
        return Self.menuIcon(alert: alert, rag: h.rag, update: model.update != nil, symbol: h.reasons.first?.symbol)
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
    static func menuIcon(alert: Bool, rag: LoadRAG? = nil, update: Bool = false, symbol: String? = nil) -> NSImage {
        // A blue dot on the top right corner while an update is waiting.
        let size = NSSize(width: update ? 28 : 24, height: 18)
        let fill = color(rag ?? (alert ? .red : .green))
        let glyph = NSImage(systemSymbolName: alert ? "exclamationmark.triangle.fill" : (symbol ?? "cpu"), accessibilityDescription: "System Sentinel")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        let img = NSImage(size: size, flipped: false) { rect in
            let badge = NSRect(x: 0, y: 0, width: 24, height: 18)
            fill.setFill()
            NSBezierPath(roundedRect: badge.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
            if let g = glyph {
                let r = NSRect(x: (badge.width - g.size.width) / 2, y: (badge.height - g.size.height) / 2,
                               width: g.size.width, height: g.size.height)
                g.draw(in: r)
            }
            if update {
                let dot = NSBezierPath(ovalIn: NSRect(x: rect.width - 10, y: rect.height - 10, width: 9, height: 9))
                NSColor.white.setFill(); dot.fill()
                NSColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - 9, y: rect.height - 9, width: 7, height: 7)).fill()
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "System Sentinel"
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
            TabBar(selection: $tab, badges: [.events: model.flagged.count, .checkup: model.checkup.problems.count])
            Group {
                if fullLength {
                    banners
                    page
                } else {
                    // Banners scroll with the page: a window that changes height while open
                    // can make AppKit abort mid-layout.
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) { VStack(spacing: 10) { banners; page }.padding(.trailing, 2) }
                            .frame(height: Self.contentHeight)
                            .onChange(of: model.focus) { _, card in
                                guard let card else { return }
                                let id = String(card.split(separator: ":").first ?? "")
                                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
                                // Cleared after the card has picked its view, so the same button works again.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.focus = nil }
                            }
                    }
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
                Text("System Sentinel").font(.headline)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")  ·  \(Int(model.cores)) cores  ·  sampled every 5 s").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            HealthChip(health: model.health)
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
    private var banners: some View {
        CrashBanner(model: model)
        if let rel = model.update { UpdateBanner(model: model, rel: rel) }
        if Model.snapshotDir == nil { PermissionsGate(permissions: model.permissions) }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .overview: OverviewView(model: model)
        case .processes: ProcessesView(model: model)
        case .trends: TrendsView(model: model)
        case .memory: MemoryView(model: model)
        case .storage: StorageView(model: model, store: model.storage)
        case .network: NetworkView(model: model, store: model.network)
        case .checkup: CheckupView(model: model, store: model.checkup)
        case .battery: BatteryView(model: model)
        case .events: EventsView(model: model)
        case .rules: RulesView(model: model)
        case .settings: SettingsView(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = model.lastError {
                Label(err, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Theme.heat(100)).lineLimit(1)
            } else if let msg = model.lastAction {
                Label(msg, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
    var autoUpdateCheck: Bool
    var alarmCPU: Bool, alarmCPUPercent: Double, alarmCPUMinutes: Double
    var alarmSwap: Bool, alarmSwapGB: Double
    var alarmPressure: Bool, alarmPressureMinutes: Double
    var alarmDisk: Bool, alarmDiskGB: Double
    var dnsWorkHost: String, hotspotAlerts: Bool

    @MainActor init(_ m: Model) {
        threshold = m.threshold; window = m.windowSeconds; login = m.launchAtLogin
        menuBarShows = m.menuBarShows; alertHeat = m.alertHeat; heatWatts = m.heatWatts; heatMinutes = m.heatMinutes
        alertBlockers = m.alertBlockers; blockerHours = m.blockerHours; weeklyReport = m.weeklyReport
        autoUpdateCheck = m.autoUpdateCheck
        alarmCPU = m.alarmCPU; alarmCPUPercent = m.alarmCPUPercent; alarmCPUMinutes = m.alarmCPUMinutes
        alarmSwap = m.alarmSwap; alarmSwapGB = m.alarmSwapGB
        alarmPressure = m.alarmPressure; alarmPressureMinutes = m.alarmPressureMinutes
        alarmDisk = m.alarmDisk; alarmDiskGB = m.alarmDiskGB
        dnsWorkHost = m.dnsWorkHost; hotspotAlerts = m.hotspotAlerts
    }

    @MainActor func apply(to m: Model) {
        m.threshold = threshold; m.windowSeconds = window
        if login != m.launchAtLogin { m.launchAtLogin = login }
        m.menuBarShows = menuBarShows; m.alertHeat = alertHeat; m.heatWatts = heatWatts; m.heatMinutes = heatMinutes
        m.alertBlockers = alertBlockers; m.blockerHours = blockerHours; m.weeklyReport = weeklyReport
        m.autoUpdateCheck = autoUpdateCheck
        m.alarmCPU = alarmCPU; m.alarmCPUPercent = alarmCPUPercent; m.alarmCPUMinutes = alarmCPUMinutes
        m.alarmSwap = alarmSwap; m.alarmSwapGB = alarmSwapGB
        m.alarmPressure = alarmPressure; m.alarmPressureMinutes = alarmPressureMinutes
        m.alarmDisk = alarmDisk; m.alarmDiskGB = alarmDiskGB
        let hostChanged = m.dnsWorkHost != dnsWorkHost
        m.dnsWorkHost = dnsWorkHost.trimmingCharacters(in: .whitespaces); m.hotspotAlerts = hotspotAlerts
        if hostChanged { m.network.runDNSDoctor() }
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
                Toggle("Launch System Sentinel at login", isOn: draft.login)
                    .toggleStyle(.switch)
                Text("Trends and insights only cover the time System Sentinel is running.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            MenuBarSettingsCard(model: model, draft: draft)
            AlarmsSettingsCard(model: model, draft: draft)
            Card(title: "Network", symbol: "network", tint: Tab.network.color) {
                HStack {
                    Text("Work name to check")
                    TextField("e.g. jira.corp.example.com", text: draft.dnsWorkHost).textFieldStyle(.roundedBorder)
                }
                Text("An internal name that only resolves on the office network or VPN. The DNS doctor checks it every 10 minutes and says when it stops resolving.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Notify when the Mac joins a phone's hotspot, and as mobile data adds up", isOn: draft.hotspotAlerts).toggleStyle(.switch)
            }
            Card(title: "Reports", symbol: "calendar.badge.clock", tint: Tab.events.color) {
                Toggle("Weekly report notification, Monday morning", isOn: draft.weeklyReport).toggleStyle(.switch)
                Text("Top apps, CPU hours, time on battery and average power draw for the last 7 days. The same report is always on the Events tab.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            UpdatesCard(model: model, auto: draft.autoUpdateCheck)
            PermissionsCard(permissions: model.permissions)
            DiagnosticsCard(model: model)
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
            let icon = SystemSentinelApp.menuIcon(alert: alert)
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
                ("optimise", AnyView(OptimiseView(model: model, store: .shared)), NSSize(width: 720, height: 1500)),
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
        // The DNS map window, when `--dnsmap <name>` started one.
        if let r = DNSMapStore.shared.result {
            try? DNSMap.report(r).write(to: URL(fileURLWithPath: dir).appendingPathComponent("dnsmap.txt"), atomically: true, encoding: .utf8)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: DNSMapView(store: .shared, fullLength: true).frame(width: 920))
                host.appearance = NSAppearance(named: appearance)
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: appearance)
                win.contentView = host
                let size = host.fittingSize
                win.setContentSize(size)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("dnsmap-\(appearance == .aqua ? "light" : "dark").png"))
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
        if Model.snapshotDir == nil { IconWatch.start() }
        guard !atLogin, Model.snapshotDir == nil else { return }
        // The model is created with the menu bar scene; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let m = Model.current { PopOut.show(m) } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let m = Model.current { PopOut.show(m) }
        return true
    }
}

/// Whether the icon is in the menu bar, and where it goes.
@MainActor
final class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    /// Snapshot runs put no icon in the menu bar: a second one there pushes the real one
    /// behind the notch while it runs.
    @Published var inserted = Model.snapshotDir == nil

    /// AppKit's own key for where a status item sits: points from the right edge of the screen.
    /// New items go to the far left, next to the notch, and that is the end macOS hides first
    /// when the bar is full. Near the right, by Control Centre, it is the last to go.
    static let positionKey = "NSStatusItem Preferred Position Item-0"
    static let rightSide: Double = 150

    /// Before the icon is created: on the right unless it has been placed already (a ⌘-drag
    /// sets this too, and is kept).
    static func placeRight(force: Bool = false) {
        guard force || UserDefaults.standard.object(forKey: positionKey) == nil else { return }
        UserDefaults.standard.set(rightSide, forKey: positionKey)
    }

    /// Takes the icon out and puts it back on the right, where macOS hides icons last.
    func moveRight() {
        Self.placeRight(force: true)
        inserted = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.inserted = true }
    }
}

/// On a MacBook with a notch, menu bar icons that do not fit are hidden without a word,
/// newest first, and an app that has just started is the newest. Checks now and then
/// whether the icon is on screen; if it has been hidden for a while, says so once a day
/// and how to bring it back.
@MainActor
enum IconWatch {
    private static var hiddenSince: Date?
    private static var timer: Timer?
    private static var moved: Date?
    private static var closingPanel = false

    /// The icon's button, inside the status item's window.
    static var statusButton: NSButton? {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return iconWindow?.contentView.flatMap(find)
    }

    static func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in check() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { check() }
        // Clicking the icon while the window is open brings the window to the front instead
        // of opening a second copy under the icon.
        // The panel under the icon does not become key while the window is, so this watches
        // for it appearing at all.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                MainActor.assumeIsolated {
                    guard let w = n.object as? NSWindow, w.isVisible, String(describing: type(of: w)).contains("MenuBarExtra"),
                          PopOut.isOpen, !closingPanel else { return }
                    // SwiftUI keeps its own open flag for the panel; hiding the window behind its
                    // back would spend the next click closing it. Clicking the icon's button again
                    // closes it the way SwiftUI expects.
                    closingPanel = true
                    w.alphaValue = 0
                    DispatchQueue.main.async {
                        statusButton?.performClick(nil)
                        w.alphaValue = 1
                        if w.isVisible { w.orderOut(nil) }
                        closingPanel = false
                    }
                    if let m = Model.current { PopOut.show(m) }
                }
            }
        }
    }

    /// The status item's window: AppKit's own class, the only way to it from MenuBarExtra.
    static var iconWindow: NSWindow? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("NSStatusBarWindow") }
    }

    /// Where the icon really is, from the accessibility tree of this app's own menu bar item.
    /// The status window's frame cannot be trusted: since macOS 26 Control Centre lays the icons
    /// out, and the frame AppKit reports can be far from where it is drawn.
    static func iconX() -> (minX: CGFloat, width: CGFloat)? {
        let app = AXUIElementCreateApplication(getpid())
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let item = (kids as? [AXUIElement])?.first else { return nil }
        var pos: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size)
        var p = CGPoint.zero, sz = CGSize.zero
        guard let pos, let size, AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &sz) else { return nil }
        return (p.x, sz.width)
    }

    static func isHidden() -> Bool {
        guard iconWindow != nil else { return true }
        guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main else { return false }
        guard let x = iconX() else { return false } // cannot tell: say nothing rather than cry wolf
        // Behind the notch: the icon's middle falls in the gap between the two usable top areas.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let mid = x.minX + x.width / 2 - screen.frame.minX
            if mid > left.maxX && mid < right.minX { return true }
        }
        return x.minX + x.width <= screen.frame.minX || x.minX >= screen.frame.maxX
    }

    static func check() {
        guard isHidden() else { hiddenSince = nil; return }
        let now = Date()
        // First, move it to the right end, which macOS hides last. At most every 10 minutes,
        // so a bar that is simply too full does not make it jump about.
        if moved.map({ now.timeIntervalSince($0) > 600 }) ?? true {
            moved = now
            Diagnostics.report("menu bar", "Icon was hidden behind the notch; moved it to the right end")
            MenuBarState.shared.moveRight()
            return
        }
        guard let since = hiddenSince else { hiddenSince = now; return }
        let last = UserDefaults.standard.double(forKey: "iconHiddenNotified")
        guard now.timeIntervalSince(since) >= 120, now.timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "iconHiddenNotified")
        let content = UNMutableNotificationContent()
        content.title = "System Sentinel's menu bar icon is hidden"
        content.body = "The menu bar is full, so macOS hid it behind the notch. Hide menu bar icons you do not need (System Settings, Menu Bar), or show the icon without the number (System Sentinel Settings). Open System Sentinel from Spotlight meanwhile."
        content.categoryIdentifier = "info"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "icon-hidden", content: content, trigger: nil))
    }
}

/// The same screens in an ordinary window, which can be dragged anywhere and stays open;
/// a menu bar panel is pinned under its icon and closes when you click away.
@MainActor
enum PopOut {
    private static var window: NSWindow?

    static var isOpen: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }

    static func show(_ model: Model) {
        if window == nil {
            let host = NSHostingController(rootView: MenuView(model: model, inWindow: true))
            let w = NSWindow(contentViewController: host)
            w.title = "System Sentinel"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("SystemSentinelWindow")
            if !w.setFrameUsingName("SystemSentinelWindow") { w.center() }
            window = w
        }
        NSApp.activate()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
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

/// The app was CPU Sentinel until 0.7.0. Brings its settings, history and login item across
/// once, so the rename loses nothing.
enum Migration {
    static let oldDomain = "consulting.cloudscale.cpusentinel"
    static let flag = "migratedFromCPUSentinel"

    static func fromCPUSentinel() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        let d = UserDefaults.standard
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)
        let old = UserDefaults.standard.persistentDomain(forName: oldDomain) ?? [:]
        for (k, v) in old where d.object(forKey: k) == nil && !k.hasPrefix("NS") && !k.hasPrefix("Apple") {
            d.set(v, forKey: k)
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = base.appendingPathComponent("CPUSentinel", isDirectory: true)
        let newDir = base.appendingPathComponent("SystemSentinel", isDirectory: true)
        if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        }
        // macOS ties the login item to the app, so the old one cannot carry over: re-add it
        // for anyone who used CPU Sentinel. Settings turns it off.
        if !old.isEmpty, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}
