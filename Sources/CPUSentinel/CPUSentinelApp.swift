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
            if fullLength {
                page
            } else {
                ScrollView(.vertical) { page.padding(.trailing, 2) }
                    .frame(height: Self.contentHeight)
            }
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
                Text("\(Int(model.cores)) cores  ·  sampled every 5 s").font(.caption2).foregroundStyle(.secondary)
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
        let autoKill = rules.filter { if case .autoKill = $0.value { return true }; return false }.count
        let ignored = rules.filter { if case .ignore = $0.value { return true }; return false }.count
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
                            Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
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
        }
    }

    @ViewBuilder
    private func rulePill(_ p: Policy) -> some View {
        switch p {
        case .alert: Pill(text: "alert", symbol: "bell.fill", color: Tab.events.color)
        case .autoKill: Pill(text: "auto-kill", symbol: "bolt.fill", color: Theme.heat(100))
        case .ignore(let until?): Pill(text: "ignored until \(Fmt.time(until))", symbol: "moon.fill", color: Tab.rules.color)
        case .ignore(nil): Pill(text: "always ignored", symbol: "moon.fill", color: Tab.rules.color)
        }
    }
}

/// Edits are a draft until Save, so dragging a slider past the value you wanted does not
/// change detection halfway through.
struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var threshold: Double?
    @State private var window: Double?
    @State private var login: Bool?

    private var t: Double { threshold ?? model.threshold }
    private var w: Double { window ?? model.windowSeconds }
    private var l: Bool { login ?? model.launchAtLogin }
    private var dirty: Bool { t != model.threshold || w != model.windowSeconds || l != model.launchAtLogin }

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
                    Slider(value: Binding(get: { t }, set: { threshold = $0 }), in: 30...400, step: 10).tint(Theme.heat(t))
                    Text("100% is one full core; a process can use several.").font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("for")
                        Text(Model.duration(w)).font(.body.weight(.bold)).foregroundStyle(Tab.events.color)
                        Text("without a break")
                    }
                    Slider(value: Binding(get: { w }, set: { window = $0 }), in: 30...900, step: 30).tint(Tab.events.color)
                    Text("Short bursts never count; only a process that stays over the line the whole time.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Card(title: "Startup", symbol: "power", tint: Tab.processes.color) {
                Toggle("Launch CPU Sentinel at login", isOn: Binding(get: { l }, set: { login = $0 }))
                    .toggleStyle(.switch)
                Text("Trends and insights only cover the time CPU Sentinel is running.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if dirty {
                    Label("Unsaved changes", systemImage: "pencil.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Tab.events.color)
                }
                Spacer()
                Button("Revert") { threshold = nil; window = nil; login = nil }
                    .disabled(!dirty)
                Button {
                    model.threshold = t
                    model.windowSeconds = w
                    if l != model.launchAtLogin { model.launchAtLogin = l }
                    threshold = nil; window = nil; login = nil
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
        exit(0)
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
