import AppKit
import SentinelCore
import SwiftUI

/// What a row's icon is: the real app icon where there is one, a tinted symbol otherwise.
enum ProcessIcon {
    case image(NSImage)
    case symbol(String, Color)
}

/// Resolves and caches an icon per executable path.
///
/// Order: the outermost .app bundle's icon (so a Chrome renderer shows Chrome); a known
/// command line tool mapped to its desktop app (the `claude` CLI shows Claude); a system
/// daemon gets a gear; anything else a terminal symbol. A path is resolved once.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: ProcessIcon] = [:]

    /// Command line tools and VMs that belong to a desktop app, by binary name.
    private let knownApps: [String: [String]] = [
        "claude": ["/Applications/Claude.app"],
        "claude-burst": ["/Applications/Claude.app"],
        "codex": ["/Applications/Codex.app", "/Applications/ChatGPT.app"],
        "com.apple.Virtualization.VirtualMachine": ["/Applications/Rancher Desktop.app", "/Applications/Docker.app", "/Applications/UTM.app"],
        "limactl": ["/Applications/Rancher Desktop.app"],
        "qemu-system-aarch64": ["/Applications/Rancher Desktop.app", "/Applications/UTM.app"],
        "com.docker.backend": ["/Applications/Docker.app"],
        "node": ["/Applications/Visual Studio Code.app"],
        "Python": ["/Applications/Python 3.13/IDLE.app"],
    ]

    private let symbolFor: [String: (String, Color)] = [
        "kernel_task": ("cpu.fill", .gray),
        "WindowServer": ("macwindow.on.rectangle", .blue),
        "mds": ("magnifyingglass", .indigo),
        "mds_stores": ("magnifyingglass", .indigo),
        "mdworker_shared": ("magnifyingglass", .indigo),
        "PerfPowerServices": ("bolt.fill", .yellow),
        "bash": ("terminal.fill", .green),
        "zsh": ("terminal.fill", .green),
        "sh": ("terminal.fill", .green),
        "python3": ("chevron.left.forwardslash.chevron.right", .yellow),
        "Python": ("chevron.left.forwardslash.chevron.right", .yellow),
        "swift-frontend": ("swift", .orange),
        "git": ("arrow.triangle.branch", .orange),
        "ssh": ("network", .teal),
        "docker-compose": ("shippingbox.fill", .blue),
        "screencapture": ("camera.viewfinder", .pink),
        "backupd": ("clock.arrow.circlepath", .green),
        "softwareupdated": ("arrow.down.circle.fill", .blue),
    ]

    func icon(for s: ProcessSample) -> ProcessIcon {
        if let hit = cache[s.path] { return hit }
        let resolved = resolve(s)
        cache[s.path] = resolved
        return resolved
    }

    private func resolve(_ s: ProcessSample) -> ProcessIcon {
        if let bundle = AppIdentity.bundlePath(of: s.path) {
            return .image(NSWorkspace.shared.icon(forFile: bundle))
        }
        if let candidates = knownApps[s.name],
           let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return .image(NSWorkspace.shared.icon(forFile: app))
        }
        if let (symbol, color) = symbolFor[s.name] { return .symbol(symbol, color) }
        if AppIdentity.isSystem(s.path) { return .symbol("gearshape.2.fill", .secondary) }
        return .symbol("terminal.fill", .mint)
    }
}

struct IconView: View {
    let icon: ProcessIcon
    var size: CGFloat = 26

    var body: some View {
        switch icon {
        case .image(let img):
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        case .symbol(let name, let color):
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.86, height: size * 0.86)
                .overlay(Image(systemName: name).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: color.opacity(0.35), radius: 1.5, y: 1)
                .frame(width: size, height: size)
        }
    }
}
