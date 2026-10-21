import AppKit
import SentinelCore
import SwiftUI
import UserNotifications

enum UpdateState: Equatable {
    case idle, checking, upToDate, installing
    case failed(String)
}

extension Model {
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func scheduleUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.autoUpdateCheck == true { self?.checkForUpdates(manual: false) }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.autoUpdateCheck == true { self?.checkForUpdates(manual: false) }
            }
        }
    }

    /// `manual` reports the outcome on screen, in the window named by `surface`; the automatic
    /// check stays quiet unless it finds one.
    func checkForUpdates(manual: Bool, surface: String = "main") {
        guard updateState != .checking, updateState != .installing else { return }
        updateState = .checking
        let mine = Model.appVersion
        Task.detached {
            let result = Updates.latest()
            let changes = Updates.changes(since: mine)
            await MainActor.run {
                self.changes = changes
                self.lastUpdateCheck = Date().timeIntervalSince1970
                switch result {
                case .success(let rel):
                    self.taskHealth.ran(.updateCheck)
                    if Updates.isNewer(rel.version, than: Model.appVersion) {
                        self.update = rel
                        self.updateState = .idle
                        self.announce(rel)
                    } else {
                        self.update = nil
                        self.updateState = .upToDate
                        if manual { self.showToast(Toast(ok: true, title: "System Sentinel is up to date", detail: "You have the latest version, v\(Model.appVersion).", surface: surface)) }
                    }
                case .failure(let e):
                    self.updateState = .failed(e.text)
                    Diagnostics.report("update", "Update check failed: \(e.text)")
                    if manual { self.showToast(Toast(ok: false, title: "Could not check for updates", detail: e.text, surface: surface)) }
                }
            }
        }
    }

    private func announce(_ rel: Updates.Release) {
        guard notifiedUpdate != rel.version else { return }
        notifiedUpdate = rel.version
        let content = UNMutableNotificationContent()
        content.title = "System Sentinel \(rel.version) is available"
        let new = Updates.highlights(rel.notes, max: 2)
        content.body = (new.isEmpty ? "" : new.joined(separator: " ") + " ") + "Click to install."
        content.categoryIdentifier = "info"
        content.threadIdentifier = "updates"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(rel.version)", content: content, trigger: nil))
    }

    /// Downloads the release, quits, and a small script swaps the new copy in and reopens it.
    /// Downloads the latest release and installs it even when it is this same version: a
    /// repair, and a way to try the installer.
    func reinstallLatest() {
        guard updateState != .checking, updateState != .installing else { return }
        updateState = .checking
        Task.detached {
            let result = Updates.latest()
            await MainActor.run {
                self.updateState = .idle
                switch result {
                case .success(let rel): self.installUpdate(rel)
                case .failure(let e):
                    self.updateState = .failed(e.text)
                    self.showToast(Toast(ok: false, title: "Could not reach GitHub", detail: e.text))
                }
            }
        }
    }

    func installUpdate(_ release: Updates.Release? = nil) {
        guard let rel = release ?? update, updateState != .installing else { return }
        let installed = Bundle.main.bundlePath
        guard installed.hasSuffix(".app") else {
            showToast(Toast(ok: false, title: "Not running from an app bundle", detail: "Download it from the release page instead."))
            return
        }
        updateState = .installing
        Task.detached {
            let result = Updates.download(rel)
            await MainActor.run {
                switch result {
                case .failure(let e):
                    self.updateState = .failed(e.text)
                    self.showToast(Toast(ok: false, title: "Update not installed", detail: e.text))
                case .success(let app):
                    if let why = Updates.verify(app, version: rel.version, bundleID: Bundle.main.bundleIdentifier ?? "") {
                        self.updateState = .failed(why)
                        self.showToast(Toast(ok: false, title: "Update not installed", detail: why + " Download it from the release page instead."))
                        return
                    }
                    // In the download's own private folder, not a fixed name in the temp folder.
                    let script = app.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("swap.sh")
                    let text = Updates.swapScript(pid: ProcessInfo.processInfo.processIdentifier, newApp: app.path, installedAt: installed)
                    do {
                        try text.write(to: script, atomically: true, encoding: .utf8)
                        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/bin/bash")
                        p.arguments = [script.path]
                        p.standardOutput = FileHandle.nullDevice
                        p.standardError = FileHandle.nullDevice
                        try p.run()
                    } catch {
                        self.updateState = .failed("Could not start the installer: \(error.localizedDescription)")
                        self.showToast(Toast(ok: false, title: "Update not installed", detail: "Could not start the installer: \(error.localizedDescription)"))
                        return
                    }
                    FileManager.default.createFile(atPath: Model.updateMarker.path, contents: Data(rel.version.utf8))
                    let note = UNMutableNotificationContent()
                    note.title = "System Sentinel"
                    note.subtitle = "Restarting to update"
                    note.body = "Installing v\(rel.version). Back in a few seconds."
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "restarting", content: note, trigger: nil))
                    // A moment for the notification to show; quitting saves the history (see saveOnQuit).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }

    var updateCheckedText: String {
        guard lastUpdateCheck > 0 else { return "Not checked yet" }
        let d = Date(timeIntervalSince1970: lastUpdateCheck)
        return "Last checked " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }
}

/// At the top of every tab while a newer version is out: hard to miss on purpose.
struct UpdateBanner: View {
    @ObservedObject var model: Model
    let rel: Updates.Release
    private let tint = Color(hex: "#2563eb")

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available: v\(rel.version)").font(.headline).foregroundStyle(.white)
                let new = Updates.highlights(rel.notes, max: 2)
                let count = model.changes.map { " \($0.ahead) change\($0.ahead == 1 ? "" : "s") since yours." } ?? ""
                Text((new.isEmpty ? "You have v\(Model.appVersion).\(count)" : "You have v\(Model.appVersion).\(count) New: " + new.joined(separator: " ")))
                    .font(.caption).foregroundStyle(.white.opacity(0.92)).lineLimit(2)
            }
            Spacer(minLength: 6)
            if let page = rel.page {
                Button { NSWorkspace.shared.open(page) } label: {
                    Text("Release notes").font(.callout.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                model.confirmInstallUpdate()
            } label: {
                Group {
                    if model.updateState == .installing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…") }
                    } else {
                        Label("Install and relaunch", systemImage: "arrow.down.to.line")
                    }
                }
                .font(.callout.weight(.semibold)).foregroundStyle(tint)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .disabled(model.updateState == .installing)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint))
    }
}

struct UpdatesCard: View {
    @ObservedObject var model: Model
    @Binding var auto: Bool

    var body: some View {
        Card(title: "Updates", symbol: "arrow.down.circle", tint: Color(hex: "#2563eb")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status).font(.callout.weight(.semibold)).foregroundStyle(statusColor)
                    Text("You have v\(Model.appVersion)  ·  \(model.updateCheckedText)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.update != nil {
                    Button("Install and relaunch") { model.confirmInstallUpdate() }
                        .tip("Download the new version, check it, install it and reopen. Asks first")
                        .buttonStyle(.borderedProminent).tint(Color(hex: "#16a34a"))
                        .disabled(model.updateState == .installing)
                }
                Button("Reinstall…") {
                    Confirm.ask("Reinstall System Sentinel?", "Downloads the latest release from GitHub and replaces this copy.",
                                symbol: "arrow.down.circle.fill", tint: Tab.settings.color,
                                points: ["Checks the download's signature before installing.", "Quits and reopens in a few seconds.",
                                         "Settings and history are kept."], button: "Reinstall") { model.reinstallLatest() }
                }
                .tip("Download and install the latest release again, even if you already have it")
                .buttonStyle(.bordered).tint(Tab.events.color)
                .disabled(model.updateState == .checking || model.updateState == .installing)
                Button {
                    model.checkForUpdates(manual: true)
                } label: {
                    if model.updateState == .checking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                    } else {
                        Label("Check for updates", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent).tint(Color(hex: "#2563eb"))
                .disabled(model.updateState == .checking || model.updateState == .installing)
            }
            ChangesList(changes: model.changes)
            if case .failed(let why) = model.updateState {
                Text(why).font(.caption).foregroundStyle(Theme.heat(100)).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Check automatically (at launch and every 6 hours) and notify me", isOn: $auto).toggleStyle(.switch)
            Text("Updates come from the GitHub releases. Install and relaunch downloads the new version, replaces this copy and reopens it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: String {
        if let u = model.update { return "Version \(u.version) is available" }
        switch model.updateState {
        case .checking: return "Checking…"
        case .installing: return "Installing…"
        case .failed: return "Could not check"
        case .upToDate: return "Up to date"
        case .idle: return model.lastUpdateCheck > 0 ? "Up to date" : "Not checked yet"
        }
    }

    private var statusColor: Color {
        if model.update != nil { return Color(hex: "#2563eb") }
        if case .failed = model.updateState { return Theme.heat(100) }
        return .primary
    }
}

/// "N changes on GitHub since your version", the newest few, and links to them and to the
/// latest files.
struct ChangesList: View {
    let changes: Updates.Changes?
    @State private var showAll = false
    private let tint = Color(hex: "#2563eb")

    var body: some View {
        if let c = changes {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(c.ahead == 0 ? "No changes on GitHub since v\(Model.appVersion)"
                                      : "\(c.ahead) change\(c.ahead == 1 ? "" : "s") on GitHub since v\(Model.appVersion), \(c.files) file\(c.files == 1 ? "" : "s")")
                        .font(.callout.weight(.semibold)).foregroundStyle(c.ahead == 0 ? Color.primary : tint)
                    Spacer()
                    if c.ahead > 0, let page = c.page { link("See the changes", "plus.forwardslash.minus", page) }
                    link("Latest files", "folder", Updates.latestFiles)
                    link("All releases", "shippingbox", Updates.releasesPage)
                }
                ForEach(showAll ? c.commits : Array(c.commits.prefix(5))) { m in
                    HStack(spacing: 8) {
                        Text(m.sha).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(m.title).font(.caption).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let d = m.date {
                            Text(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if c.commits.count > 5 {
                    Button(showAll ? "Show fewer" : "Show all \(c.commits.count)") { showAll.toggle() }.buttonStyle(.link).font(.caption)
                }
                if c.ahead > 0 {
                    Text("Changes reach you when they are released; ones newer than the latest release are not in Install or Reinstall yet.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.07)))
        } else {
            HStack(spacing: 8) {
                link("Latest files", "folder", Updates.latestFiles)
                link("All releases", "shippingbox", Updates.releasesPage)
            }
        }
    }

    private func link(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.13)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip(url.absoluteString)
    }
}
