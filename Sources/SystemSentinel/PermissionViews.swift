import AppKit
import SentinelCore
import SwiftUI
import UserNotifications

/// The permissions System Sentinel uses, asked for together on first launch so they do not
/// pop up one at a time later. Full Disk Access covers every folder prompt (Desktop,
/// Documents, Downloads, other apps' data), so it is the one that stops the prompts.
@MainActor
final class Permissions: ObservableObject {
    enum State: Equatable { case granted, denied, notAsked, unknown }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let why: String
        let symbol: String
        var state: State
    }

    @Published var items: [Item] = []
    @AppStorage("permissionsDismissed") var dismissed = false
    private var timer: Timer?

    /// Apps System Sentinel scripts: Finder empties the Trash, Terminal opens a sudo shell,
    /// Chrome lists tabs.
    static let automated: [(id: String, name: String, why: String)] = [
        ("com.apple.finder", "Finder", "Empty the Trash from the Storage tab."),
        ("com.apple.Terminal", "Terminal", "Open a Terminal with the sudo command for protected processes."),
        ("com.google.Chrome", "Google Chrome", "List Chrome's tabs by memory and close the ones you pick."),
    ]

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Not granted yet. Unknown (an app that is not running) does not nag.
    var missing: [Item] { items.filter { $0.state == .notAsked || $0.state == .denied } }

    func refresh() {
        var list: [Item] = [
            Item(id: "fda", title: "Full Disk Access",
                 why: "Measures the Trash, Mail, Messages and other apps' data, and stops macOS asking about Desktop, Documents and Downloads one folder at a time.",
                 symbol: "lock.open.fill", state: Self.hasFullDiskAccess() ? .granted : .notAsked),
        ]
        for a in Self.automated where a.id == "com.apple.finder" || NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.id) != nil {
            let s: State
            switch Self.automation(a.id, ask: false) {
            case noErr: s = .granted
            case OSStatus(errAEEventNotPermitted): s = .denied
            case OSStatus(errAEEventWouldRequireUserConsent): s = .notAsked
            default: s = .unknown // the app is not running, so macOS cannot say
            }
            list.append(Item(id: a.id, title: "Control \(a.name)", why: a.why, symbol: "applescript.fill", state: s))
        }
        let current = items.first { $0.id == "notifications" }?.state ?? .unknown
        list.insert(Item(id: "notifications", title: "Notifications", why: "Alarms, runaway processes, updates and the weekly report.",
                         symbol: "bell.badge.fill", state: current), at: 0)
        if list != items { items = list }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let style = settings.alertStyle
            Task { @MainActor in if self.alertStyle != style { self.alertStyle = style } }
            let s: State
            switch settings.authorizationStatus {
            case .authorized, .provisional: s = .granted
            case .denied: s = .denied
            case .notDetermined: s = .notAsked
            default: s = .unknown
            }
            Task { @MainActor in
                if let i = self.items.firstIndex(where: { $0.id == "notifications" }), self.items[i].state != s { self.items[i].state = s }
            }
        }
    }

    /// Asks for everything that can be asked for in place, then opens Full Disk Access.
    func requestAll() {
        // Once turned down, macOS never asks again: only System Settings can turn it back on.
        switch items.first(where: { $0.id == "notifications" })?.state {
        case .denied: Permissions.showNotificationSettings()
        case .granted: break
        default: askNotifications()
        }
        let ids = items.filter { $0.id.contains(".") && $0.state != .granted }.map(\.id)
        Task.detached {
            for id in ids { await Permissions.askAutomation(id) }
            await MainActor.run {
                self.refresh()
                if !Permissions.hasFullDiskAccess() { self.openFullDiskAccess() }
            }
        }
    }

    func request(_ item: Item) {
        switch item.id {
        case "fda": openFullDiskAccess()
        case "notifications":
            if item.state == .denied { Permissions.showNotificationSettings() } else { askNotifications() }
        default:
            if item.state == .denied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            } else {
                let id = item.id
                Task.detached {
                    await Permissions.askAutomation(id)
                    await MainActor.run { self.refresh() }
                }
            }
        }
    }

    func openFullDiskAccess() { Permissions.showFullDiskAccess() }

    /// How notifications appear: banners, alerts, or only in Notification Centre.
    @Published var alertStyle: UNAlertStyle?

    /// Focus settings, where an app can be let through Do Not Disturb and the rest.
    static func showFocusSettings() { showSettings("x-apple.systempreferences:com.apple.Focus-Settings.extension") }

    /// What the last Test said for each permission: passed, and what happened.
    @Published var tested: [String: (ok: Bool, text: String)] = [:]

    /// Uses the permission for real, harmlessly: a test notification, reading a folder only
    /// Full Disk Access opens, asking an app for its name.
    func test(_ item: Item) {
        switch item.id {
        case "notifications":
            let content = UNMutableNotificationContent()
            content.title = "System Sentinel test"
            content.body = "Notifications work. Alarms, runaway processes and updates arrive like this."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(Date().timeIntervalSince1970)", content: content, trigger: nil)) { error in
                Task { @MainActor in
                    self.tested[item.id] = error == nil ? (true, "Sent. If it went straight to Notification Centre without popping up, a Focus is on (the moon in the menu bar): let System Sentinel through it below.")
                                                        : (false, "Not sent: \(error!.localizedDescription)")
                }
            }
        case "fda":
            let ok = Permissions.hasFullDiskAccess()
            tested[item.id] = ok ? (true, "Read the Trash and Safari's folder: access works.")
                                 : (false, "Still blocked. Turn System Sentinel on in Full Disk Access, then quit and reopen it.")
        default:
            let id = item.id
            let name = Permissions.automated.first { $0.id == id }?.name ?? id
            Task.detached {
                let status = Permissions.automation(id, ask: false)
                let result: (Bool, String)
                switch status {
                case noErr: result = (true, "\(name) answered: control works.")
                case OSStatus(errAEEventNotPermitted): result = (false, "Refused. Turn it on in Privacy & Security, Automation.")
                case OSStatus(errAEEventWouldRequireUserConsent): result = (false, "Not asked yet: click Allow.")
                default: result = (false, "\(name) is not running, so macOS cannot say. Open it and test again.")
                }
                await MainActor.run { self.tested[id] = result }
            }
        }
    }

    /// Opens System Settings at the Full Disk Access list, in front. System Sentinel is already
    /// in that list (it looked for its access at launch), so turning on its switch is all it takes.
    static func showFullDiskAccess() {
        showSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    /// System Sentinel's own page in Notifications settings.
    static func showNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "consulting.cloudscale.systemsentinel"
        showSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    }

    /// Asks macOS; if it will not show its prompt (turned down before), opens the settings.
    func askNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in
                self.refresh()
                if !ok { Permissions.showNotificationSettings() }
            }
        }
    }

    static func showSettings(_ url: String) {
        NSWorkspace.shared.open(URL(string: url)!)
        // Opening a URL leaves System Settings behind this app's window; bring it forward.
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.activate()
            }
        }
    }

    /// macOS only asks about an app that is running, so it is opened hidden first if needed.
    nonisolated static func askAutomation(_ id: String) async {
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        _ = automation(id, ask: true)
    }

    /// Reading a folder only Full Disk Access opens, without triggering a prompt.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for p in ["Library/Safari", ".Trash", "Library/Mail"] {
            let url = home.appendingPathComponent(p)
            if FileManager.default.fileExists(atPath: url.path) {
                return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
            }
        }
        return false
    }

    /// Whether this app may send Apple Events to `bundleID`; with `ask`, macOS shows its prompt.
    nonisolated static func automation(_ bundleID: String, ask: Bool) -> OSStatus {
        var addr = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let made = bytes.withUnsafeBufferPointer { AECreateDesc(typeApplicationBundleID, $0.baseAddress, $0.count, &addr) }
        guard made == noErr else { return OSStatus(made) }
        defer { AEDisposeDesc(&addr) }
        return AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, ask)
    }
}

/// On every tab until everything is granted or the user says not now.
struct PermissionsBanner: View {
    @ObservedObject var permissions: Permissions
    private let tint = Color(hex: "#7c3aed")

    var body: some View {
        let missing = permissions.missing
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish setting up: \(missing.count) permission\(missing.count == 1 ? "" : "s") to go").font(.headline).foregroundStyle(.white)
                Text("Grant them once now so macOS does not interrupt you later: \(missing.map(\.title).joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.white.opacity(0.92)).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button { permissions.dismissed = true } label: {
                Text("Not now").font(.callout.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button { permissions.requestAll() } label: {
                Label("Grant all", systemImage: "hand.raised.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(tint)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint))
    }
}

/// Settings: each permission, whether it is granted, and a button to fix it.
struct PermissionsCard: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        Card(title: "Permissions", symbol: "checkmark.shield.fill", tint: Color(hex: "#7c3aed"),
             trailing: AnyView(Button("Check again") { permissions.refresh() }.buttonStyle(.link).font(.caption))) {
            ForEach(permissions.items) { p in
                HStack(spacing: 10) {
                    Image(systemName: p.state == .granted ? "checkmark.circle.fill" : (p.state == .denied ? "xmark.circle.fill" : "circle.dashed"))
                        .font(.title3).foregroundStyle(p.state == .granted ? Tab.battery.color : (p.state == .denied ? Theme.heat(100) : .secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(.callout.weight(.semibold))
                        Text(p.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if p.state != .granted {
                        Button(p.state == .denied || p.id == "fda" ? "Open settings" : "Allow") { permissions.request(p) }
                    }
                    Button("Test") { permissions.test(p) }
                        .help(p.id == "notifications" ? "Sends a test notification." : "Checks that the permission works now.")
                }
                if p.id == "notifications", p.state == .granted { NotificationStyleRow(permissions: permissions) }
                if let t = permissions.tested[p.id] {
                    Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(t.ok ? Tab.battery.color : Theme.heat(100))
                        .padding(.leading, 34).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Admin password prompts (purge memory, Low Power Mode, killing root processes) cannot be granted in advance: macOS asks each time, by design. Permissions stay granted across updates as long as the app is signed with the same certificate.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How notifications show up, and the two settings that stop them popping up: the alert
/// style and Focus (Do Not Disturb keeps them silent in Notification Centre).
private struct NotificationStyleRow: View {
    @ObservedObject var permissions: Permissions
    var body: some View {
        let style: String = switch permissions.alertStyle {
        case .alert: "Alerts (stay until dismissed)"
        case .banner: "Banners (pop up for a few seconds)"
        case .some(.none): "Off: only listed in Notification Centre"
        default: "checking…"
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Pops up as: \(style)").font(.caption).foregroundStyle(permissions.alertStyle == UNAlertStyle.none ? Theme.heat(100) : .secondary)
                Spacer()
                Button("Change") { Permissions.showNotificationSettings() }.buttonStyle(.link).font(.caption)
            }
            HStack(spacing: 6) {
                Text("A Focus such as Do Not Disturb holds them silently in Notification Centre unless System Sentinel is an allowed app.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Allow through Focus") { Permissions.showFocusSettings() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(.leading, 34)
    }
}

/// The banner, only while something is missing and it has not been put off.
struct PermissionsGate: View {
    @ObservedObject var permissions: Permissions
    var body: some View {
        if !permissions.dismissed, !permissions.missing.isEmpty { PermissionsBanner(permissions: permissions) }
    }
}
