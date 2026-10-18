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

    /// `manual` reports the outcome on screen; the automatic check stays quiet unless it finds one.
    func checkForUpdates(manual: Bool) {
        guard updateState != .checking, updateState != .installing else { return }
        updateState = .checking
        Task.detached {
            let result = Updates.latest()
            await MainActor.run {
                self.lastUpdateCheck = Date().timeIntervalSince1970
                switch result {
                case .success(let rel):
                    if Updates.isNewer(rel.version, than: Model.appVersion) {
                        self.update = rel
                        self.updateState = .idle
                        self.announce(rel)
                    } else {
                        self.update = nil
                        self.updateState = .upToDate
                        if manual { self.showToast(Toast(ok: true, title: "System Sentinel is up to date", detail: nil)) }
                    }
                case .failure(let e):
                    self.updateState = .failed(e.text)
                    if manual { self.showToast(Toast(ok: false, title: "Could not check for updates", detail: e.text)) }
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
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(rel.version)", content: content, trigger: nil))
    }

    /// Downloads the release, quits, and a small script swaps the new copy in and reopens it.
    func installUpdate() {
        guard let rel = update, updateState != .installing else { return }
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
                        return
                    }
                    self.sentinel.dailyUsage.save()
                    self.sentinel.recentUsage.save()
                    self.powerHistory.save()
                    self.memoryHistory.save()
                    self.energyUsage.save()
                    NSApplication.shared.terminate(nil)
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
                Text(new.isEmpty ? "You have v\(Model.appVersion)." : "You have v\(Model.appVersion). New: " + new.joined(separator: " "))
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
                model.installUpdate()
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
                    Button("Install and relaunch") { model.installUpdate() }
                        .buttonStyle(.borderedProminent).tint(Color(hex: "#16a34a"))
                        .disabled(model.updateState == .installing)
                }
                Button {
                    model.checkForUpdates(manual: true)
                } label: {
                    if model.updateState == .checking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                    } else {
                        Label("Check for updates", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.updateState == .checking || model.updateState == .installing)
            }
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
