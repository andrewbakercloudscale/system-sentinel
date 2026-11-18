import CoreServices
import Foundation

/// Which folders under the home folder have the most files changing: what Spotlight is busy
/// re-reading. macOS does not say what Spotlight is indexing (its workers get each file
/// handed over and let go at once), but it indexes every file that changes, so the folders
/// changing most are the ones keeping it busy.
public final class FolderChurn: @unchecked Sendable {
    public struct Folder: Equatable, Sendable, Identifiable {
        public var id: String { path }
        /// Full path of the folder.
        public let path: String
        /// File changes in it over the window.
        public let changes: Int
        /// Build output, packages or caches: rebuilt by a tool, never worth searching.
        public let generated: Bool
    }

    public let window: TimeInterval
    private let home: String
    private let lock = NSLock()
    /// Changes per folder per minute: [minute: [folder: count]].
    private var minutes: [Int: [String: Int]] = [:]
    private var stream: FSEventStreamRef?

    public init(home: String = NSHomeDirectory(), window: TimeInterval = 300) {
        self.home = home
        self.window = window
    }

    deinit { stop() }

    /// Folders whose names say a tool writes them: what changes most in a build and is
    /// never worth finding with Spotlight.
    static let generatedNames: Set<String> = ["node_modules", "build", "dist", "target", "out", "DerivedData", "Pods",
                                               "venv", "__pycache__", "coverage", "tmp", "logs", "cache", "Caches", "vendor"]

    /// The folder a changed file is counted under, or nil when Spotlight would not index it:
    /// outside the home folder, in ~/Library, hidden, or named .noindex. A folder a tool
    /// generates is counted whole ("~/code/app/node_modules"); anything else by its first
    /// three levels under home ("~/Desktop/github/app").
    public static func folder(of path: String, home: String) -> (path: String, generated: Bool)? {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] != "Library" else { return nil }
        // The last part is the file itself; only folders above it decide.
        let dirs = parts.dropLast()
        for d in dirs where d.hasPrefix(".") || d.hasSuffix(".noindex") { return nil }
        if parts.last?.hasPrefix(".") == true { return nil }
        if let i = dirs.firstIndex(where: { generatedNames.contains($0) }) {
            return (prefix + dirs[...i].joined(separator: "/"), true)
        }
        return (prefix + dirs.prefix(3).joined(separator: "/"), false)
    }

    /// Count changed paths, as FSEvents reports them.
    public func record(_ paths: [String], at now: Date = Date()) {
        let m = Int(now.timeIntervalSince1970 / 60)
        var add: [String: Int] = [:]
        for p in paths {
            if let f = Self.folder(of: p, home: home) { add[f.path, default: 0] += 1 }
        }
        guard !add.isEmpty else { return }
        lock.lock()
        minutes[m, default: [:]].merge(add, uniquingKeysWith: +)
        let oldest = m - Int(window / 60) - 1
        minutes = minutes.filter { $0.key >= oldest }
        lock.unlock()
    }

    /// The folders with the most changes over the window, at least `minimum` each.
    public func top(_ n: Int = 5, minimum: Int = 50, at now: Date = Date()) -> [Folder] {
        let m = Int(now.timeIntervalSince1970 / 60), from = m - Int(window / 60)
        lock.lock()
        var sum: [String: Int] = [:]
        for (k, v) in minutes where k > from { sum.merge(v, uniquingKeysWith: +) }
        lock.unlock()
        return sum.filter { $0.value >= minimum }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n)
            .map { Folder(path: $0.key, changes: $0.value, generated: Self.folder(of: $0.key + "/x", home: home)?.generated ?? false) }
    }

    /// Watch the home folder, file by file, every 3 seconds. FSEvents costs next to nothing
    /// while nothing changes; a build writing thousands of files is a few thousand strings.
    public func start() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderChurn>.fromOpaque(info).takeUnretainedValue()
            let cf = unsafeBitCast(paths, to: NSArray.self)
            me.record((cf as? [String]) ?? [], at: Date())
            _ = count
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [home] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "FolderChurn", qos: .utility))
        if FSEventStreamStart(s) { stream = s } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
