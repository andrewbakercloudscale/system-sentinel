import AppKit
import SentinelCore
import SwiftUI

/// Who made it, where it comes from, which version this is and whether there is a newer one.
struct AboutView: View {
    @ObservedObject var model: Model
    @State private var copied = false
    @StateObject private var tips = TipCenter()
    private let tint = Color(hex: "#2563eb")

    static let linkedIn = URL(string: "https://www.linkedin.com/in/andrew-baker-ninja/")!
    static let blog = URL(string: "https://andrewbaker.ninja/")!
    static let cloudScale = URL(string: "https://cloudscale.consulting/")!
    static let gitHubProfile = URL(string: "https://github.com/andrewbakercloudscale")!
    static let repoPage = URL(string: "https://github.com/\(Updates.repo)")!
    static let issues = URL(string: "https://github.com/\(Updates.repo)/issues")!
    static let guide = URL(string: "https://github.com/\(Updates.repo)/blob/main/docs/guide.md")!
    static let licence = URL(string: "https://github.com/\(Updates.repo)/blob/main/LICENSE")!
    static let post = URL(string: "https://andrewbaker.ninja/2026/10/19/system-sentinel-a-menu-bar-doctor-for-your-mac/")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                updates
                author
                project
                details
                Text("Copyright © 2026 Andrew Baker. Free and open source under the MIT licence: use it, change it and share it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(width: 560)
        .frame(minHeight: 520, idealHeight: 760)
        .tipsAndConfirmations(tips, surface: "about")
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text("System Sentinel").font(.largeTitle.weight(.bold))
                Text("Version \(Model.appVersion) (build \(Self.build))").font(.title3.weight(.medium)).monospacedDigit()
                Text("A menu bar doctor for your Mac: why it is slow, hot, full or flat, in plain English, with a fix a click away.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var updates: some View {
        Card(title: "Updates", symbol: "arrow.down.circle", tint: tint) {
            HStack(spacing: 10) {
                Image(systemName: statusSymbol).font(.title2).foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status).font(.callout.weight(.semibold)).foregroundStyle(statusColor)
                    Text("You have v\(Model.appVersion)  ·  \(model.updateCheckedText)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.update != nil {
                    Button("Install and relaunch") { model.confirmInstallUpdate() }
                        .buttonStyle(.borderedProminent).tint(Color(hex: "#16a34a"))
                        .disabled(model.updateState == .installing)
                        .tip("Download the new version, check it, install it and reopen. Asks first")
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
                .tip("Ask GitHub whether a newer release is out")
            }
            if case .failed(let why) = model.updateState {
                Text(why).font(.callout).foregroundStyle(Theme.heat(100)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let page = model.update?.page { pill("What's new", "sparkles", page) }
                pill("All releases", "shippingbox", Updates.releasesPage)
                Spacer()
            }
            Text("Automatic checks and Reinstall are in Settings, under Updates.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var author: some View {
        Card(title: "Made by", symbol: "person.crop.circle", tint: Tab.trends.color) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Andrew Baker").font(.title3.weight(.semibold))
                Text("Group Chief Information Officer at Capitec Bank, and the person behind CloudScale Consulting. He writes about technology, leadership and the tools he builds at andrewbaker.ninja.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("System Sentinel started when a macOS energy logger quietly used one and a half cores for 37 hours and nothing said so.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                linkRow("LinkedIn", "linkedin.com/in/andrew-baker-ninja", "person.2.fill", Color(hex: "#0a66c2"), Self.linkedIn)
                linkRow("Blog", "andrewbaker.ninja", "text.book.closed.fill", Tab.battery.color, Self.blog)
                linkRow("CloudScale Consulting", "cloudscale.consulting", "cloud.fill", Tab.network.color, Self.cloudScale)
                linkRow("GitHub", "github.com/andrewbakercloudscale", "chevron.left.forwardslash.chevron.right", Color.primary, Self.gitHubProfile)
            }
        }
    }

    private var project: some View {
        Card(title: "The project", symbol: "shippingbox", tint: Tab.storage.color) {
            VStack(spacing: 6) {
                linkRow("Source code", "github.com/\(Updates.repo)", "curlybraces", Tab.storage.color, Self.repoPage)
                linkRow("User guide", "Every screen and setting explained", "book.fill", Tab.storage.color, Self.guide)
                linkRow("Report a problem or ask for a feature", "GitHub issues", "exclamationmark.bubble.fill", Tab.storage.color, Self.issues)
                linkRow("The story behind it", "andrewbaker.ninja blog post", "newspaper.fill", Tab.storage.color, Self.post)
                linkRow("Licence", "MIT", "checkmark.seal.fill", Tab.storage.color, Self.licence)
            }
            Text("Monitoring runs on this Mac and nothing is uploaded. The app is not notarised by Apple; the source is public so anyone can check what it does.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var details: some View {
        Card(title: "Details", symbol: "info.circle", tint: Tab.settings.color,
             trailing: AnyView(Button {
                 NSPasteboard.general.clearContents()
                 NSPasteboard.general.setString(detailText, forType: .string)
                 copied = true
                 DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
             } label: {
                 Label(copied ? "Copied" : "Copy details", systemImage: copied ? "checkmark" : "doc.on.doc")
             }
             .tip("Copy these details, for a bug report or a support ticket"))) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.callout).foregroundStyle(.secondary)
                        Text(row.1).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Bundle.main.bundlePath)]) } label: {
                    Label("Show the app in Finder", systemImage: "folder")
                }
                Button { NSWorkspace.shared.open(Model.supportDir) } label: {
                    Label("Open the data folder", systemImage: "externaldrive")
                }
                .tip("History and settings live here: " + Model.supportDir.path)
            }
        }
    }

    // MARK: Pieces

    private func linkRow(_ title: String, _ detail: String, _ symbol: String, _ color: Color, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(color).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(url.absoluteString)
    }

    private func pill(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold)).foregroundStyle(tint)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.13)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip(url.absoluteString)
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

    private var statusSymbol: String {
        if model.update != nil { return "arrow.down.circle.fill" }
        if case .failed = model.updateState { return "exclamationmark.triangle.fill" }
        return model.lastUpdateCheck > 0 ? "checkmark.circle.fill" : "questionmark.circle"
    }

    private var statusColor: Color {
        if model.update != nil { return tint }
        if case .failed = model.updateState { return Theme.heat(100) }
        return model.lastUpdateCheck > 0 ? Theme.heat(0) : .secondary
    }

    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    private var rows: [(String, String)] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let since = model.taskHealth.started
        return [
            ("Version", "\(Model.appVersion) (build \(Self.build))"),
            ("Installed at", Bundle.main.bundlePath),
            ("App ID", Bundle.main.bundleIdentifier ?? "?"),
            ("Running since", since.formatted(date: .abbreviated, time: .shortened)
                + " (" + RelativeDateTimeFormatter().localizedString(for: since, relativeTo: Date()) + ")"),
            ("Its own CPU", SelfGuard.usage.map { String(format: "%.1f%% of one core over the last minute", $0) } ?? "Measuring"),
            ("Mac", [Self.sysctl("hw.model"), Self.sysctl("machdep.cpu.brand_string")].compactMap { $0 }.joined(separator: ", ")),
            ("Cores and memory", "\(Int(model.cores)) cores, \(ReportDocument.bytes(ProcessInfo.processInfo.physicalMemory)) memory"),
            ("macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"),
            ("Mac up for", Self.duration(ProcessInfo.processInfo.systemUptime)),
        ]
    }

    private var detailText: String {
        (["System Sentinel"] + rows.map { "\($0.0): \($0.1)" } + ["Source: \(Self.repoPage.absoluteString)"]).joined(separator: "\n")
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d) day\(d == 1 ? "" : "s"), \(h % 24) hour\(h % 24 == 1 ? "" : "s")" }
        if h > 0 { return "\(h) hour\(h == 1 ? "" : "s"), \(m % 60) min" }
        return "\(m) min"
    }
}

/// About in its own window, like a normal Mac app's About box.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show(_ model: Model) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView(model: model)))
            w.title = "About System Sentinel"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 760))
            w.setFrameAutosaveName("AboutWindow")
            if !w.setFrameUsingName("AboutWindow") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
