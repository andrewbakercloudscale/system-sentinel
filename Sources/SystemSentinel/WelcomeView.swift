import AppKit
import SwiftUI

/// The first-run welcome: what the app does, the two permissions worth granting, and how to
/// open it. Shown once in its own window; About and the Help button's menu open it again.
struct WelcomeView: View {
    @ObservedObject var model: Model
    @ObservedObject var permissions: Permissions
    @State var step = 0
    var close: () -> Void = {}

    static let steps = 3
    private let tint = Tab.overview.color
    /// Full Disk Access has no callback; look again every 2 seconds while this step is open.
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.bold))
                    Text("Step \(step + 1) of \(Self.steps)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Group {
                switch step {
                case 0: what
                case 1: grants
                default: open
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            buttons
        }
        .padding(24)
        .frame(width: 560)
        .onReceive(poll) { _ in if step == 1 { permissions.refresh() } }
    }

    private var title: String {
        switch step {
        case 0: "Welcome to System Sentinel"
        case 1: "Two permissions worth granting"
        default: "Opening it"
        }
    }

    // MARK: Steps

    private var what: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("It sits in the menu bar and watches your Mac, so you know why it is slow, hot or running out of battery.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            point("cpu", Tab.processes.color, "CPU and processes", "Spots apps stuck at full speed and offers to quit them, with a warning first for anything macOS or your IT team needs.")
            point("memorychip", Tab.memory.color, "Memory and storage", "Shows what is using memory and what is filling the disk, and how to free it.")
            point("network", Tab.network.color, "Network", "Checks the connection every few minutes and says plainly what is wrong.")
            point("bolt.fill", Tab.battery.color, "Energy", "Which apps drain the battery, and how long it will last.")
            point("lock.shield.fill", Tab.settings.color, "Private", "Nothing about you, your files or your apps leaves the Mac. About lists the few checks that reach the internet.")
        }
    }

    private var grants: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Sentinel works without them, but does less. You can change either later in Settings, Permissions.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            ForEach(permissions.items.filter { $0.id == "fda" || $0.id == "notifications" }) { p in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: p.state == .granted ? "checkmark.circle.fill" : p.symbol)
                        .font(.title2).foregroundStyle(p.state == .granted ? Tab.battery.color : tint).frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).font(.headline)
                        Text(p.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if p.state == .granted {
                        Text("Granted").font(.callout.weight(.semibold)).foregroundStyle(Tab.battery.color)
                    } else {
                        Button(p.id == "fda" || p.state == .denied ? "Open settings" : "Allow") { permissions.request(p) }
                            .buttonStyle(.borderedProminent).tint(tint)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.07)))
            }
            Text("For Full Disk Access, turn on System Sentinel in the list that opens. This page sees the change within a few seconds.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 12) {
            point("menubar.rectangle", tint, "From the menu bar", "Click the chip icon at the top right of the screen. It turns red when something needs you.")
            point("keyboard", Tab.processes.color, "From any app: ⌃⌥⌘S", "Control Option Command S opens it in a window you can move and keep open.")
            point("questionmark.circle", Tab.memory.color, "Help", "The Help button at the bottom (Cmd ?) opens the user guide, with every screen explained. Right-click it to see this tour again.")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login").font(.headline)
                    Text("So it is watching from the moment the Mac starts. Change it later in Settings.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    .labelsHidden().toggleStyle(.switch).tint(tint)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.07)))
        }
    }

    private func point(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            if step < Self.steps - 1 {
                Button("Skip") { close() }.buttonStyle(.link).font(.callout)
                    .tip("Close the tour. About opens it again")
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.steps, id: \.self) { i in
                    Circle().fill(i == step ? tint : Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                }
            }
            .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(Self.steps)")
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }.controlSize(.large)
            }
            if step < Self.steps - 1 {
                Button("Next") { step += 1 }.buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { close() }.buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The welcome in its own window, once on first launch and whenever asked for again.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    static let seenKey = "onboarded.v1"

    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    static func showOnce(_ model: Model) {
        guard !seen else { return }
        show(model)
    }

    static func show(_ model: Model) {
        seen = true
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView(model: model, permissions: model.permissions) { window?.close() })
            // Fixed size, as with PopOut: content changing height must not resize the window mid-layout.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.setContentSize(host.view.fittingSize)
            w.title = "Welcome"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            w.dropContentOnClose { window = nil }
            window = w
        }
        NSApp.activate()
        if let w = window { keepOnScreen(w) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
