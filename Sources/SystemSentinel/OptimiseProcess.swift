import AppKit
import SentinelCore
import SwiftUI

/// The wand on each process row: what can be done about this one, short of killing it.
struct OptimiseButton: View {
    @ObservedObject var model: Model
    let sample: ProcessSample
    @State private var open = false

    var body: some View {
        let lowered = model.isSlowed(sample)
        let specific = ProcessFixes.hasSpecific(sample.name)
        Button { open.toggle() } label: {
            Image(systemName: lowered ? "tortoise.fill" : "wand.and.stars")
                .font(.callout.weight(.semibold))
                .foregroundStyle(specific ? Color.white : lowered ? Tab.rules.color : Tab.processes.color)
                .frame(width: 26, height: 22)
                .background(Capsule().fill(specific ? Tab.processes.color : Tab.processes.color.opacity(0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip(specific ? "Optimise: there is a fix for this one" : lowered ? "At background priority. Optimise to change it." : "Optimise: lower its priority or restart it")
        .popover(isPresented: $open, arrowEdge: .leading) {
            OptimisePopover(model: model, sample: sample) { open = false }
        }
    }

    /// Shown only where there is something to offer. Cheap, since every row asks every
    /// sample; the popover works out the full list when opened.
    static func available(_ model: Model, _ s: ProcessSample) -> Bool {
        s.pid != getpid() && s.name != "WindowServer" && (model.canSlow(s) || ProcessFixes.hasSpecific(s.name) || AppIdentity.bundlePath(of: s.path) != nil)
    }
}

private struct OptimisePopover: View {
    @ObservedObject var model: Model
    let sample: ProcessSample
    let close: () -> Void

    var body: some View {
        let s = sample
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconView(icon: IconCache.shared.icon(for: s), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Optimise \(s.displayName)").font(.headline)
                    Text("\(Fmt.pct(s.cpu)) now  ·  \(Fmt.pct(model.average(s, 900))) over 15 min")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ForEach(model.fixes(for: s)) { fix in
                VStack(alignment: .leading, spacing: 5) {
                    Text(fix.title).font(.callout.weight(.semibold))
                    Text(fix.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let label = fix.button {
                        Button {
                            close()
                            model.perform(fix, on: s)
                        } label: {
                            Text(label).font(.callout.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Capsule().fill(Tab.processes.color))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045)))
            }
            if model.isSlowed(s) {
                Button {
                    close()
                    model.confirmRestore(s)
                } label: {
                    Label("Back to normal priority", systemImage: "hare.fill").font(.callout.weight(.medium))
                }
                .buttonStyle(.link)
            }
            ExplainButton { close(); model.explain(s) }
        }
        .padding(14)
        .frame(width: 360)
    }
}

extension Model {
    func fixes(for s: ProcessSample) -> [ProcessFix] {
        ProcessFixes.fixes(for: s.name, app: reopenable(s).map { $0.localizedName ?? Model.appName(Model.appKey(s.path)) },
                           canLower: canSlow(s), lowered: isSlowed(s), always: slowRules.contains(s.name))
            .filter { fix in
                // A button to open an app that is not on this Mac would do nothing.
                if case .openApp(let name) = fix.action { return Self.appURL(name) != nil }
                return true
            }
    }

    /// The ordinary app a process belongs to (a helper's app too), if it can be quit and reopened.
    func reopenable(_ s: ProcessSample) -> NSRunningApplication? {
        guard s.pid != getpid(), let bundle = AppIdentity.bundlePath(of: s.path) else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleURL?.path == bundle && $0.processIdentifier != getpid()
        }
    }

    static func appURL(_ name: String) -> URL? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let url = running.bundleURL {
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", "\(home)/Applications"].map { URL(fileURLWithPath: "\($0)/\(name).app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func perform(_ fix: ProcessFix, on s: ProcessSample) {
        switch fix.action {
        case .settings(let url):
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            lastAction = "Opened \(fix.button ?? "settings")"
        case .openApp(let name):
            if let url = Self.appURL(name) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .screen:
            OptimiseWindow.show(self)
        case .lowerPriority(let always):
            confirmSlowDown(s, always: always)
        case .quitAndReopen:
            if let app = reopenable(s) { confirmQuitAndReopen(app) }
        case .none:
            break
        }
    }

    func confirmQuitAndReopen(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "the app"
        Confirm.ask("Quit and reopen \(name)?", "Quits it the normal way, as ⌘Q would, then opens it again.",
                    symbol: "arrow.clockwise.circle.fill", tint: Tab.processes.color,
                    points: ["It can save first, and may ask you about unsaved work.",
                             "Windows and tabs come back only if \(name) restores them on launch."],
                    button: "Quit and reopen") { self.quitAndReopen(app) }
    }

    private func quitAndReopen(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
        app.terminate()
        lastAction = "Quitting \(name)…"
        // Wait for it to go (it may be asking about unsaved work), then open it again.
        Task { @MainActor in
            for _ in 0..<120 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(500)) }
            guard app.isTerminated else {
                lastAction = "\(name) did not quit; nothing reopened"
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            lastAction = "Reopened \(name)"
        }
    }
}
