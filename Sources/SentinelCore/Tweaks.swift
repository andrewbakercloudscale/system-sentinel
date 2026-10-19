import Foundation

// MARK: Click to optimise: settings that make WindowServer draw less, each with an undo

/// One macOS setting, stored with `defaults`, that lightens the screen work. What it was before
/// is saved when it is applied, so Undo puts back exactly that, including "never set".
public struct Tweak: Identifiable, Equatable, Sendable {
    public enum Value: Equatable, Sendable, Codable {
        case bool(Bool), int(Int), double(Double), string(String)

        /// The `defaults write` type flag and value.
        public var args: [String] {
            switch self {
            case .bool(let b): ["-bool", b ? "true" : "false"]
            case .int(let i): ["-int", String(i)]
            case .double(let d): ["-float", String(d)]
            case .string(let s): ["-string", s]
            }
        }

        /// From `defaults read` output, for the type this tweak uses.
        public static func parse(_ s: String, like: Value) -> Value? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.contains("does not exist") else { return nil }
            switch like {
            case .bool: return t == "1" || t.lowercased() == "true" ? .bool(true) : (t == "0" || t.lowercased() == "false" ? .bool(false) : nil)
            case .int: return Int(t).map(Value.int)
            case .double: return Double(t).map(Value.double)
            case .string: return .string(t)
            }
        }
    }

    /// What has to restart for the change to show.
    public enum Takes: String, Sendable {
        case now, dock, finder, windowManager, newApps, logout
        public var text: String {
            switch self {
            case .now: "at once"
            case .dock: "when the Dock restarts (a second, done for you)"
            case .finder: "when Finder restarts (done for you)"
            case .windowManager: "when macOS's window manager restarts (a second, done for you)"
            case .newApps: "in apps opened from now on"
            case .logout: "after you log out and back in"
            }
        }
    }

    public let id: String
    public let title: String
    public let why: String
    public let domain: String
    public let key: String
    public let currentHost: Bool
    public let better: Value
    /// macOS's own default when the key is not set.
    public let standard: Value
    public let takes: Takes
    /// How much it helps WindowServer: 3 big, 1 small.
    public let impact: Int

    /// The System Settings page where the same switch lives, for doing it by hand.
    public var settingsURL: String? {
        switch domain {
        case "com.apple.universalaccess": "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display"
        case "com.apple.WindowManager": "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        case "com.apple.dock": "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        default: nil
        }
    }

    public init(id: String, title: String, why: String, domain: String, key: String, currentHost: Bool = false,
                better: Value, standard: Value, takes: Takes, impact: Int) {
        self.id = id; self.title = title; self.why = why; self.domain = domain; self.key = key
        self.currentHost = currentHost; self.better = better; self.standard = standard; self.takes = takes; self.impact = impact
    }

    /// Arguments for `defaults` before the verb's own: `-currentHost` where the setting lives
    /// per machine.
    public var hostArgs: [String] { currentHost ? ["-currentHost"] : [] }

    /// Already as good as it gets, given what `defaults read` returned (nil when not set).
    public func isOptimised(_ current: Value?) -> Bool { (current ?? standard) == better }
}

public enum Tweaks {
    /// The settings that cut WindowServer's work, biggest first.
    public static let windowServer: [Tweak] = [
        Tweak(id: "transparency", title: "Reduce transparency",
              why: "The menu bar, Dock, sidebars and Control Centre stop blurring what is behind them. Every blur is redrawn whenever anything underneath moves; this is the biggest single saving.",
              domain: "com.apple.universalaccess", key: "reduceTransparency", better: .bool(true), standard: .bool(false), takes: .logout, impact: 3),
        Tweak(id: "motion", title: "Reduce motion",
              why: "Switching Spaces, Mission Control and full screen fade instead of sliding and zooming, which redraws the whole screen for every frame.",
              domain: "com.apple.universalaccess", key: "reduceMotion", better: .bool(true), standard: .bool(false), takes: .logout, impact: 2),
        Tweak(id: "stage", title: "Turn off Stage Manager",
              why: "Stage Manager keeps live thumbnails of the other windows at the side of the screen, redrawn as they change.",
              domain: "com.apple.WindowManager", key: "GloballyEnabled", better: .bool(false), standard: .bool(false), takes: .windowManager, impact: 2),
        Tweak(id: "widgets", title: "Hide desktop widgets",
              why: "Widgets on the desktop are live views that update on their own and are composited under every window.",
              domain: "com.apple.WindowManager", key: "StandardHideWidgets", better: .bool(true), standard: .bool(false), takes: .windowManager, impact: 1),
        Tweak(id: "windowAnimations", title: "No window open and close animations",
              why: "New windows appear at once instead of zooming in, so there is less animating to draw.",
              domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", better: .bool(false), standard: .bool(true), takes: .newApps, impact: 1),
        Tweak(id: "magnification", title: "Dock magnification off",
              why: "Icons stop growing under the pointer, which redraws the Dock on every mouse move across it.",
              domain: "com.apple.dock", key: "magnification", better: .bool(false), standard: .bool(false), takes: .dock, impact: 1),
        Tweak(id: "minimise", title: "Simpler minimise effect",
              why: "Windows shrink into the Dock with Scale instead of the Genie effect, which bends every frame of the window.",
              domain: "com.apple.dock", key: "mineffect", better: .string("scale"), standard: .string("genie"), takes: .dock, impact: 1),
        Tweak(id: "exposeSpeed", title: "Faster Mission Control",
              why: "Mission Control's animation runs in a tenth of a second instead of about half a second.",
              domain: "com.apple.dock", key: "expose-animation-duration", better: .double(0.1), standard: .double(0.5), takes: .dock, impact: 1),
    ]

    /// Fits more icons in a full menu bar, so macOS stops hiding some behind the notch.
    public static let menuBar: [Tweak] = [
        Tweak(id: "menuSpacing", title: "Tighter menu bar spacing",
              why: "Less space between menu bar icons, so more of them fit beside the notch instead of being hidden.",
              domain: "NSGlobalDomain", key: "NSStatusItemSpacing", currentHost: true, better: .int(6), standard: .int(16), takes: .logout, impact: 1),
        Tweak(id: "menuPadding", title: "Smaller menu bar highlight",
              why: "The highlight around a clicked icon is narrower, which also saves room.",
              domain: "NSGlobalDomain", key: "NSStatusItemSelectionPadding", currentHost: true, better: .int(6), standard: .int(16), takes: .logout, impact: 1),
    ]

    public static var all: [Tweak] { windowServer + menuBar }
    public static func named(_ id: String) -> Tweak? { all.first { $0.id == id } }
}

/// What a setting was before we changed it: a value, or not set at all.
public struct TweakBackup: Codable, Equatable, Sendable {
    public var before: [String: Tweak.Value?] = [:]
    public var at: [String: Date] = [:]
    public init() {}

    /// Remembers the original only the first time, so applying twice never loses it.
    public mutating func save(_ id: String, was: Tweak.Value?, at now: Date) {
        guard before[id] == nil else { return }
        before[id] = .some(was)
        at[id] = now
    }

    public mutating func forget(_ id: String) { before[id] = nil; at[id] = nil }
    public func has(_ id: String) -> Bool { before[id] != nil }
    public func original(_ id: String) -> Tweak.Value?? { before[id] }
}

/// What an Undo has to do: write the old value back, or delete the key we added.
public enum TweakUndo: Equatable, Sendable {
    case write(Tweak.Value), delete

    public static func plan(_ original: Tweak.Value?) -> TweakUndo {
        original.map(TweakUndo.write) ?? .delete
    }
}

// MARK: Lower priority: a busy process waits behind the apps you are using

/// Processes that do heavy work in bursts by design: lowering them costs a little time and
/// keeps the Mac responsive.
public enum BackgroundCandidates {
    static let names: Set<String> = [
        "swift-frontend", "swift-build", "swiftc", "clang", "clang++", "cc1plus", "ld", "ld64", "rustc", "cargo", "go", "gcc",
        "node", "esbuild", "webpack", "tsc", "java", "gradle", "kotlin-daemon", "ffmpeg", "HandBrakeCLI", "python3", "docker",
        "com.docker.backend", "mds_stores", "mdworker_shared", "photoanalysisd", "mediaanalysisd", "backupd", "bird", "cloudd",
        "Dropbox", "OneDrive", "Google Drive", "zip", "unzip", "tar", "xz", "brew", "ruby", "xcodebuild", "XCBBuildService",
    ]

    /// Why lowering this one helps, when there is something specific to say.
    public static func note(_ name: String) -> String? {
        switch name {
        case "swift-frontend", "swiftc", "clang", "clang++", "cc1plus", "rustc", "gcc", "ld", "ld64", "xcodebuild", "XCBBuildService", "swift-build":
            return "A compiler: builds use every core on purpose. At lower priority the build carries on, a little slower, and the Mac stays responsive."
        case "mds_stores", "mdworker_shared":
            return "Spotlight indexing. It catches up later at lower priority."
        case "photoanalysisd", "mediaanalysisd":
            return "Photos analysing your library. It has no deadline."
        case "backupd":
            return "Time Machine. The backup finishes a little later."
        default:
            return names.contains(name) ? "Batch work with no one waiting on each second of it." : nil
        }
    }
}

// MARK: Displays: how many pixels WindowServer draws for each

public struct DisplayPixels: Equatable, Sendable {
    public let name: String
    public let builtIn: Bool
    /// What WindowServer renders, before scaling down to the panel.
    public let rendered: (w: Int, h: Int)
    /// The panel's own pixels, when macOS says.
    public let native: (w: Int, h: Int)?
    /// The size things look like ("looks like 1710 x 1107").
    public let looksLike: (w: Int, h: Int)?
    public let hz: Double?

    public static func == (a: DisplayPixels, b: DisplayPixels) -> Bool {
        a.name == b.name && a.builtIn == b.builtIn && a.rendered == b.rendered && a.native?.w == b.native?.w && a.native?.h == b.native?.h
            && a.looksLike?.w == b.looksLike?.w && a.looksLike?.h == b.looksLike?.h && a.hz == b.hz
    }

    /// Rendered pixels over the panel's: above 1 means a scaled ("More space") resolution,
    /// drawn larger and shrunk every frame.
    public var overdraw: Double? {
        guard let n = native, n.w > 0, n.h > 0 else { return nil }
        return Double(rendered.w * rendered.h) / Double(n.w * n.h)
    }

    static func size(_ s: String?) -> (w: Int, h: Int)? {
        guard let s, let r = s.range(of: #"(\d+)\s*x\s*(\d+)"#, options: .regularExpression) else { return nil }
        let parts = s[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// `system_profiler SPDisplaysDataType -json`.
    public static func parse(_ data: Data) -> [DisplayPixels] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gpus = o["SPDisplaysDataType"] as? [[String: Any]] else { return [] }
        let all: [[String: Any]] = gpus.flatMap { ($0["spdisplays_ndrvs"] as? [[String: Any]]) ?? [] }
        return all.compactMap { (d: [String: Any]) -> DisplayPixels? in
            guard let rendered = size(d["_spdisplays_pixels"] as? String) else { return nil }
            let res = d["_spdisplays_resolution"] as? String
            var hz: Double?
            if let res, let r = res.range(of: #"@\s*([\d.]+)\s*Hz"#, options: .regularExpression) {
                hz = Double(res[r].filter { $0.isNumber || $0 == "." })
            }
            return DisplayPixels(name: d["_name"] as? String ?? "Display",
                               builtIn: (d["spdisplays_connection_type"] as? String) == "spdisplays_internal",
                               rendered: rendered, native: size(d["spdisplays_pixelresolution"] as? String),
                               looksLike: size(res), hz: hz)
        }
    }
}
