import CoreServices
import Foundation

// MARK: Disk space

/// The startup disk: what is used, what is free, and what macOS can free by itself (purgeable:
/// iCloud copies, caches, local Time Machine snapshots).
public struct DiskSpace: Equatable, Sendable {
    public var total: UInt64
    /// Free right now.
    public var free: UInt64
    /// Free plus what macOS would clear for an app that needs the room.
    public var available: UInt64

    public init(total: UInt64, free: UInt64, available: UInt64) {
        self.total = total
        self.free = free
        self.available = max(available, free)
    }

    public var purgeable: UInt64 { available - free }
    public var used: UInt64 { total > available ? total - available : 0 }
    public var usedShare: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public static func read(_ path: String = "/") -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
        let free = UInt64(max(v.volumeAvailableCapacity ?? 0, 0))
        return DiskSpace(total: UInt64(total), free: free, available: UInt64(max(v.volumeAvailableCapacityForImportantUsage ?? Int64(free), 0)))
    }

    public enum Level: Int, Sendable { case ok, low, critical }

    /// Critical under 5% or 10 GB, low under 15% or 25 GB. A full disk stops updates, slows
    /// swap and can stop apps saving.
    public var level: Level {
        let share = total == 0 ? 1 : Double(available) / Double(total)
        if share < 0.05 || available < 10 << 30 { return .critical }
        if share < 0.15 || available < 25 << 30 { return .low }
        return .ok
    }
}

// MARK: Timeline

/// Disk use every 10 minutes for 90 days, and the size of each known folder at each scan.
public final class StorageHistory {
    public struct Point: Codable, Equatable, Sendable {
        public var t: Int
        public var used: UInt64
        public var free: UInt64
        public var purgeable: UInt64
        public init(t: Int, used: UInt64, free: UInt64, purgeable: UInt64) {
            self.t = t; self.used = used; self.free = free; self.purgeable = purgeable
        }
        public var date: Date { Date(timeIntervalSince1970: Double(t)) }
    }

    public struct Scan: Codable, Equatable, Sendable {
        public var t: Int
        /// Known folder key (`StoragePlace.key`) to bytes.
        public var sizes: [String: UInt64]
        /// Known folder key to its biggest items (name to bytes), for what grew inside it.
        /// Nil on scans from before this was kept and once older than `childRetain`.
        public var children: [String: [String: UInt64]]?
        public init(t: Int, sizes: [String: UInt64], children: [String: [String: UInt64]]? = nil) {
            self.t = t; self.sizes = sizes; self.children = children
        }
        public var date: Date { Date(timeIntervalSince1970: Double(t)) }
    }

    struct File: Codable { var points: [Point]; var scans: [Scan] }

    public private(set) var points: [Point] = []
    public private(set) var scans: [Scan] = []
    private let fileURL: URL?
    private let readOnly: Bool
    public static let step = 600
    public static let retain = 90 * 86_400
    /// Item sizes inside folders are kept for the longest "What grew" range, not all 90 days.
    public static let childRetain = 31 * 86_400
    /// Biggest items kept per folder. An item missing from a full list is unknown, not gone.
    public static let childLimit = 30

    public init(fileURL: URL?, readOnly: Bool = false) {
        self.fileURL = fileURL
        self.readOnly = readOnly
        if let url = fileURL, let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) {
            points = f.points
            scans = f.scans
        }
    }

    /// One point per 10 minutes: the latest reading wins.
    public func record(_ d: DiskSpace, at now: Date) {
        let t = Int(now.timeIntervalSince1970) / Self.step * Self.step
        let p = Point(t: t, used: d.used, free: d.available, purgeable: d.purgeable)
        if let last = points.last, last.t == t {
            points[points.count - 1] = p
        } else {
            points.append(p)
            trim(t)
            save()
        }
    }

    public func record(scan sizes: [String: UInt64], children: [String: [String: UInt64]]? = nil, at now: Date) {
        scans.append(Scan(t: Int(now.timeIntervalSince1970), sizes: sizes, children: children))
        trim(Int(now.timeIntervalSince1970))
        save()
    }

    private func trim(_ t: Int) {
        let cutoff = t - Self.retain
        points.removeAll { $0.t < cutoff }
        scans.removeAll { $0.t < cutoff }
        for i in scans.indices where scans[i].children != nil && scans[i].t < t - Self.childRetain { scans[i].children = nil }
    }

    public func since(_ date: Date) -> [Point] {
        let t = Int(date.timeIntervalSince1970)
        return points.filter { $0.t >= t }
    }

    public func save() {
        guard !readOnly, let url = fileURL, let data = try? JSONEncoder().encode(File(points: points, scans: scans)) else { return }
        Diagnostics.write(data, to: url, what: url.lastPathComponent)
    }
}

// MARK: Known places

/// Folders worth knowing the size of, what they are and whether they can be cleaned.
public struct StoragePlace: Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    /// Relative to the home folder.
    public let path: String
    public let symbol: String
    public let about: String
    public let clean: Clean?
    public var id: String { key }

    public enum Clean: Equatable, Sendable {
        /// Delete what is inside; it is rebuilt when needed.
        case deleteContents
        /// Run a tool that knows what is safe to remove.
        case command(path: String, args: [String])
        /// Empty the Trash through Finder.
        case emptyTrash
    }

    public static let all: [StoragePlace] = [
        .init(key: "trash", name: "Trash", path: ".Trash", symbol: "trash.fill",
              about: "Files you deleted. They still take space until the Trash is emptied.", clean: .emptyTrash),
        .init(key: "downloads", name: "Downloads", path: "Downloads", symbol: "arrow.down.circle.fill",
              about: "Everything you have downloaded. Installers and old files pile up here.", clean: nil),
        .init(key: "desktop", name: "Desktop", path: "Desktop", symbol: "menubar.dock.rectangle", about: "Files on the desktop.", clean: nil),
        .init(key: "documents", name: "Documents", path: "Documents", symbol: "doc.fill", about: "Your documents (and projects kept there).", clean: nil),
        .init(key: "pictures", name: "Pictures and Photos library", path: "Pictures", symbol: "photo.fill",
              about: "Includes the Photos library. Photos can keep only small copies on the Mac with Optimize Mac Storage.", clean: nil),
        .init(key: "movies", name: "Movies", path: "Movies", symbol: "film.fill", about: "Videos, screen recordings, iMovie and Final Cut libraries.", clean: nil),
        .init(key: "music", name: "Music", path: "Music", symbol: "music.note", about: "Music library, GarageBand and downloaded podcasts.", clean: nil),
        .init(key: "caches", name: "App caches", path: "Library/Caches", symbol: "archivebox.fill",
              about: "Files apps keep to go faster. Safe to lose but they come back; clean single big ones instead of all.", clean: nil),
        .init(key: "logs", name: "Logs", path: "Library/Logs", symbol: "doc.text.fill", about: "Diagnostic logs. Old ones are safe to delete.", clean: .deleteContents),
        .init(key: "derivedData", name: "Xcode build files", path: "Library/Developer/Xcode/DerivedData", symbol: "hammer.fill",
              about: "Xcode's build products and indexes. Safe to delete: Xcode rebuilds them on the next build.", clean: .deleteContents),
        .init(key: "deviceSupport", name: "Xcode device support", path: "Library/Developer/Xcode/iOS DeviceSupport", symbol: "iphone",
              about: "Debug symbols for every iOS version a device was plugged in with. Safe to delete; rebuilt when needed.", clean: .deleteContents),
        .init(key: "xcodeArchives", name: "Xcode archives", path: "Library/Developer/Xcode/Archives", symbol: "shippingbox.fill",
              about: "Builds you archived for release. Keep the ones you may need to symbolicate crashes.", clean: nil),
        .init(key: "simulators", name: "iOS simulators", path: "Library/Developer/CoreSimulator", symbol: "ipad.and.iphone",
              about: "Simulator devices and their apps. Simulators for iOS versions no longer installed can go.",
              clean: .command(path: "/usr/bin/xcrun", args: ["simctl", "delete", "unavailable"])),
        .init(key: "iosBackups", name: "iPhone and iPad backups", path: "Library/Application Support/MobileSync/Backup", symbol: "iphone.gen3",
              about: "Local device backups. Delete old ones in Finder: select the device, Manage Backups.", clean: nil),
        .init(key: "docker", name: "Docker", path: "Library/Containers/com.docker.docker", symbol: "shippingbox.circle.fill",
              about: "Docker's virtual disk with images and containers. Shrink it with docker system prune, or in Docker's settings.", clean: nil),
        .init(key: "rancher", name: "Rancher Desktop", path: "Library/Application Support/rancher-desktop", symbol: "shippingbox.circle",
              about: "Rancher Desktop's virtual machine disk with images and containers.", clean: nil),
        .init(key: "mail", name: "Mail", path: "Library/Mail", symbol: "envelope.fill", about: "Mail's local copies of messages and attachments.", clean: nil),
        .init(key: "messages", name: "Messages", path: "Library/Messages", symbol: "message.fill",
              about: "Messages history and attachments. Settings can keep messages for a year instead of forever.", clean: nil),
        .init(key: "homebrew", name: "Homebrew downloads", path: "Library/Caches/Homebrew", symbol: "mug.fill",
              about: "Downloaded bottles and old versions. brew cleanup removes them.",
              clean: .command(path: "/opt/homebrew/bin/brew", args: ["cleanup", "--prune=all"])),
        .init(key: "npm", name: "npm cache", path: ".npm/_cacache", symbol: "cube.box.fill", about: "Packages npm downloaded. Safe to delete.", clean: .deleteContents),
        .init(key: "pip", name: "pip cache", path: "Library/Caches/pip", symbol: "cube.box", about: "Packages pip downloaded. Safe to delete.", clean: .deleteContents),
        .init(key: "yarn", name: "Yarn cache", path: "Library/Caches/Yarn", symbol: "cube", about: "Packages Yarn downloaded. Safe to delete.", clean: .deleteContents),
        .init(key: "gradle", name: "Gradle cache", path: ".gradle/caches", symbol: "cube.transparent", about: "Gradle's downloads and build cache. Safe to delete.", clean: .deleteContents),
        .init(key: "maven", name: "Maven repository", path: ".m2/repository", symbol: "cube.transparent.fill", about: "Java libraries Maven downloaded. Safe to delete; downloaded again when needed.", clean: .deleteContents),
        .init(key: "cargo", name: "Cargo registry", path: ".cargo/registry", symbol: "cube.fill", about: "Rust crates Cargo downloaded. Safe to delete.", clean: .deleteContents),
        .init(key: "goMod", name: "Go modules", path: "go/pkg/mod", symbol: "cube.fill", about: "Go's module cache. Clean with go clean -modcache.", clean: nil),
    ]

    public static func named(_ key: String) -> StoragePlace? { all.first { $0.key == key } }
}

// MARK: Sizes

public enum DiskUsage {
    /// Bytes on disk for a file, or everything under a folder. Stops at `deadline`, flagging the
    /// result as partial. Unreadable folders (privacy protected) count as nil.
    public static func size(of url: URL, deadline: Date = .distantFuture) -> (bytes: UInt64, partial: Bool)? {
        measure(url, deadline: deadline, byChild: false).map { ($0.bytes, $0.partial) }
    }

    /// Like `size`, and also the bytes under each item directly inside the folder, from the
    /// same walk.
    public static func measure(_ url: URL, deadline: Date = .distantFuture, byChild: Bool = true)
        -> (bytes: UInt64, partial: Bool, children: [String: UInt64])? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        guard v.isDirectory == true else { return (UInt64(v.totalFileAllocatedSize ?? 0), false, [:]) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        var total: UInt64 = 0
        var n = 0
        var children: [String: UInt64] = [:]
        var child = ""
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            let b = UInt64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            total += b
            // The walk is depth first: everything after a level-1 item is inside it until the next one.
            if byChild {
                if e?.level == 1 { child = f.lastPathComponent }
                children[child, default: 0] += b
            }
            n += 1
            if n % 2000 == 0, Date() > deadline { return (total, true, children) }
        }
        return (total, false, children)
    }

    /// Size of each known place that exists and can be read.
    public static func places(home: URL, deadline: TimeInterval = 45, skip: Set<String> = []) -> [String: UInt64] {
        measurePlaces(home: home, deadline: deadline, skip: skip).sizes
    }

    /// Size of each known place, and its biggest items (at most `StorageHistory.childLimit`,
    /// 1 MB and over) for "What grew".
    public static func measurePlaces(home: URL, deadline: TimeInterval = 45, skip: Set<String> = [])
        -> (sizes: [String: UInt64], children: [String: [String: UInt64]]) {
        var out: [String: UInt64] = [:]
        var kids: [String: [String: UInt64]] = [:]
        let list = StoragePlace.all.filter { p in !skip.contains { p.path.hasPrefix($0) } }
        // One folder at a time: measuring them all at once took every core for several
        // seconds. Slower, and never in the way.
        let end = Date().addingTimeInterval(deadline)
        for p in list {
            if let s = measure(home.appendingPathComponent(p.path), deadline: end) {
                out[p.key] = s.bytes
                let top = s.children.filter { $0.value >= 1 << 20 }.sorted { $0.value > $1.value }.prefix(StorageHistory.childLimit)
                kids[p.key] = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
            }
        }
        return (out, kids)
    }
}

// MARK: Folder tree

/// Sizes of every folder under home down to a few levels, for "where is my space".
public struct FolderTree: Codable, Equatable, Sendable {
    /// Relative path ("Library/Caches") to bytes; "" is the whole home folder.
    public var sizes: [String: UInt64]
    public var at: Date
    public var seconds: Double
    public var files: Int
    /// Folders macOS would not let us read.
    public var unreadable: [String]

    public init(sizes: [String: UInt64], at: Date, seconds: Double, files: Int, unreadable: [String]) {
        self.sizes = sizes; self.at = at; self.seconds = seconds; self.files = files; self.unreadable = unreadable
    }

    public static let maxDepth = 4
    /// Cloud folders hold placeholders and iCloud copies; walking them is slow and says little.
    public static let skipped: Set<String> = ["Library/CloudStorage", "Library/Mobile Documents", "Library/Metadata/CoreSpotlight"]

    /// Walks the folder. `progress` gets bytes and files counted so far; `cancelled` stops early.
    /// Other apps' containers: without Full Disk Access, reading them makes macOS ask
    /// "would like to access data from other apps", and waits for an answer.
    public static let otherApps: Set<String> = ["Library/Containers", "Library/Group Containers"]
    /// Folders macOS guards one at a time ("would like to access files in your Downloads
    /// folder"). Without Full Disk Access they are left alone, so there are no prompts at all.
    public static let personal: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]

    /// What to leave out of a scan of `home`: everything macOS would ask about, unless the app
    /// has Full Disk Access.
    public static func guarded(fullAccess: Bool) -> Set<String> {
        fullAccess ? [] : otherApps.union(personal)
    }

    /// Whether `path` lies inside one of `skip` (relative to `home`).
    public static func isInside(_ path: String, _ skip: Set<String>, home: String) -> Bool {
        let base = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(base) else { return false }
        let rel = String(path.dropFirst(base.count))
        return skip.contains { rel == $0 || rel.hasPrefix($0 + "/") }
    }

    public static func scan(_ root: URL, skip: Set<String> = skipped, progress: (UInt64, Int) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) -> FolderTree {
        let started = Date()
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        var sizes: [String: UInt64] = [:]
        var unreadable: [String] = []
        var files = 0
        // The enumerator may spell the root differently (/var against /private/var), so the
        // prefix to cut comes from the first item it returns.
        var cut: Int?
        var denied: [URL] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { url, _ in
            denied.append(url)
            return true
        })
        var total: UInt64 = 0
        while let url = e?.nextObject() as? URL {
            if cut == nil { cut = url.deletingLastPathComponent().path.count + 1 }
            let rel = String(url.path.dropFirst(cut ?? 0))
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skip.contains(rel) { e?.skipDescendants() }
                continue
            }
            let b = UInt64(v.totalFileAllocatedSize ?? 0)
            guard b > 0 else { continue }
            files += 1
            total += b
            var depth = 0
            var idx = rel.startIndex
            while depth < maxDepth, let slash = rel[idx...].firstIndex(of: "/") {
                sizes[String(rel[..<slash]), default: 0] += b
                idx = rel.index(after: slash)
                depth += 1
            }
            if files % 5000 == 0 {
                progress(total, files)
                if cancelled() { break }
            }
        }
        sizes[""] = total
        let c = cut ?? 0
        unreadable = denied.map { String($0.path.dropFirst(c)) }.filter { !$0.isEmpty }
        // Small folders are not worth keeping.
        sizes = sizes.filter { $0.value >= 20 << 20 || !$0.key.contains("/") }
        return FolderTree(sizes: sizes, at: Date(), seconds: Date().timeIntervalSince(started), files: files,
                          unreadable: Array(Set(unreadable.map { $0.split(separator: "/").prefix(3).joined(separator: "/") })).sorted())
    }

    /// Direct subfolders of `path`, largest first.
    public func children(of path: String) -> [(path: String, bytes: UInt64)] {
        let depth = path.isEmpty ? 0 : path.split(separator: "/").count
        let prefix = path.isEmpty ? "" : path + "/"
        return sizes.filter { k, _ in !k.isEmpty && k.hasPrefix(prefix) && k.split(separator: "/").count == depth + 1 }
            .map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    /// The folders where the space really is: big, and not just a wrapper around one big
    /// subfolder (that subfolder is listed instead).
    public func culprits(min: UInt64 = 1 << 30, limit: Int = 15) -> [(path: String, bytes: UInt64)] {
        // A package (Photos library, app, bundle) is one thing to the owner: list it whole,
        // never the folders inside it.
        let packages = [".photoslibrary", ".app", ".bundle", ".musiclibrary", ".fcpbundle", ".imovielibrary", ".tvlibrary"]
        func isPackage(_ p: String) -> Bool { packages.contains { p.hasSuffix($0) } }
        func inPackage(_ p: String) -> Bool { packages.contains { p.contains($0 + "/") } }
        let big = sizes.filter { !$0.key.isEmpty && $0.value >= min && !inPackage($0.key) }
        var picked: [(String, UInt64)] = []
        for (path, bytes) in big {
            if isPackage(path) { picked.append((path, bytes)); continue }
            let kids = children(of: path)
            if let top = kids.first, Double(top.bytes) >= 0.7 * Double(bytes) { continue }
            picked.append((path, bytes))
        }
        // Drop a folder when a listed folder inside it holds most of it.
        picked = picked.filter { p in
            !picked.contains { q in q.0.hasPrefix(p.0 + "/") && Double(q.1) >= 0.5 * Double(p.1) }
        }
        return Array(picked.sorted { $0.1 > $1.1 }.prefix(limit)).map { (path: $0.0, bytes: $0.1) }
    }
}

// MARK: Files found with Spotlight

/// One file or folder found on disk.
public struct FoundItem: Equatable, Sendable, Identifiable, Codable {
    public var path: String
    public var bytes: UInt64
    public var modified: Date?
    /// When it was last opened (Spotlight), or added to its folder for Downloads.
    public var used: Date?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, bytes: UInt64, modified: Date? = nil, used: Date? = nil) {
        self.path = path; self.bytes = bytes; self.modified = modified; self.used = used
    }
}

public enum Spotlight {
    /// Paths matching a Spotlight query, from `mdfind`.
    public static func find(_ query: String, in dir: String? = nil) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.qualityOfService = .background
        p.arguments = (dir.map { ["-onlyin", $0] } ?? []) + ["-0", query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else {
            Diagnostics.report("storage", "Spotlight search (mdfind) would not start")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { Diagnostics.report("storage", "Spotlight search failed (mdfind exit \(p.terminationStatus))") }
        return data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    public static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    public static func item(_ path: String, folderDeadline: TimeInterval = 10, lastUsed wantUsed: Bool = false) -> FoundItem? {
        let url = URL(fileURLWithPath: path)
        guard let s = DiskUsage.size(of: url, deadline: Date().addingTimeInterval(folderDeadline)) else { return nil }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return FoundItem(path: path, bytes: s.bytes, modified: mod, used: wantUsed ? lastUsed(path) : nil)
    }
}

// MARK: Kinds of clutter

public enum Clutter {
    /// Disk images, installer packages and archives that are usually done with once used.
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "img"]
    public static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]

    public enum Kind: String, Sendable { case installer, archive, video, image, document, folder, app, other }

    public static func kind(of path: String, isFolder: Bool = false) -> Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "app" { return .app }
        if isFolder { return .folder }
        if installerExtensions.contains(ext) { return .installer }
        if archiveExtensions.contains(ext) { return .archive }
        if ["mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "mpg"].contains(ext) { return .video }
        if ["jpg", "jpeg", "png", "heic", "gif", "tiff", "raw", "cr2", "nef", "arw", "dng"].contains(ext) { return .image }
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "csv"].contains(ext) { return .document }
        return .other
    }

    /// What a big file probably is, in plain words.
    public static func about(_ path: String) -> String? {
        let p = path.lowercased()
        if p.hasSuffix("docker.raw") { return "Docker's virtual disk. Shrink it with docker system prune or in Docker's settings, not by deleting it." }
        if p.contains("rancher-desktop/lima") { return "Rancher Desktop's virtual machine disk. Prune images in Rancher Desktop." }
        if p.contains(".photoslibrary") { return "The Photos library. Use Photos, Settings, iCloud, Optimize Mac Storage." }
        if p.contains("/library/containers/") || p.contains("/library/application support/") { return "Data an app keeps for itself. Clean it from inside the app." }
        if p.contains("coresimulator") { return "An iOS simulator device." }
        if p.contains("mobilesync/backup") { return "An iPhone or iPad backup." }
        switch kind(of: path) {
        case .installer: return "An installer or disk image. Once the app is installed it is usually not needed."
        case .archive: return "A compressed archive. If you have unpacked it, the archive is a second copy."
        case .video: return "A video."
        case .app: return "An app."
        default: return nil
        }
    }

    /// Top-level `node_modules` folders only: nested ones are part of their parent.
    public static func topNodeModules(_ paths: [String]) -> [String] {
        paths.filter { p in
            let parts = p.components(separatedBy: "/node_modules")
            return parts.count == 2 && parts[1].isEmpty
        }
    }

    /// A folder of photos: how many, how big, and the newest.
    public struct PhotoFolder: Equatable, Sendable, Identifiable, Codable {
        public let path: String
        public let count: Int
        public let bytes: UInt64
        public let newest: Date?
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// Groups photos by the folder they sit in. Photos inside a Photos library are left out:
    /// the library is handled as a whole.
    public static func photoFolders(_ images: [FoundItem], min: UInt64 = 200 << 20) -> [PhotoFolder] {
        let loose = images.filter { !$0.path.contains(".photoslibrary/") && !$0.path.contains("/Library/") }
        let groups = Dictionary(grouping: loose) { ($0.path as NSString).deletingLastPathComponent }
        return groups.map { dir, items in
            PhotoFolder(path: dir, count: items.count, bytes: items.reduce(0) { $0 + $1.bytes },
                        newest: items.compactMap(\.modified).max())
        }
        .filter { $0.bytes >= min }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Not touched in this long: worth archiving or deleting.
    public static func isStale(_ date: Date?, days: Double, at now: Date) -> Bool {
        guard let d = date else { return false }
        return now.timeIntervalSince(d) >= days * 86_400
    }
}

// MARK: Findings

/// Growth, forecasts and jumps from the disk timeline.
public enum StorageAnalysis {
    /// Bytes a day, from a least-squares line through the points. nil with under a day of data.
    public static func growthPerDay(_ points: [StorageHistory.Point]) -> Double? {
        guard let first = points.first, let last = points.last, last.t - first.t >= 86_400 else { return nil }
        let xs = points.map { Double($0.t - first.t) / 86_400 }
        let ys = points.map { Double($0.used) }
        let n = Double(points.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        guard den != 0 else { return nil }
        // A big cleanup late in the week can leave the fitted line rising while the disk ended
        // the week emptier than it started; the screen then said both. The net change wins then.
        let slope = num / den
        let net = (Double(last.used) - Double(first.used)) / (Double(last.t - first.t) / 86_400)
        return (slope > 0) == (net > 0) ? slope : net
    }

    /// Days until the free space runs out at this pace. nil when not filling up.
    public static func daysUntilFull(free: UInt64, perDay: Double?) -> Double? {
        guard let g = perDay, g > 100 * 1_048_576 else { return nil }
        return Double(free) / g
    }

    public struct Jump: Equatable, Sendable, Identifiable {
        public let from: Date
        public let to: Date
        /// Positive when space was used, negative when freed.
        public let bytes: Int64
        public var id: Date { from }
    }

    /// Changes of at least `min` within an hour, newest first.
    public static func jumps(_ points: [StorageHistory.Point], min: UInt64 = 2 << 30) -> [Jump] {
        var out: [Jump] = []
        var i = 0
        while i < points.count {
            let start = points[i]
            var j = i
            while j + 1 < points.count, points[j + 1].t - start.t <= 3600 { j += 1 }
            let d = Int64(points[j].used) - Int64(start.used)
            if j > i, d.magnitude >= min {
                out.append(Jump(from: start.date, to: points[j].date, bytes: d))
                i = j
            } else {
                i += 1
            }
        }
        return out.reversed()
    }

    public struct Change: Equatable, Sendable, Identifiable {
        public let key: String
        public let from: UInt64
        public let to: UInt64
        public var delta: Int64 { Int64(to) - Int64(from) }
        public var id: String { key }
    }

    /// How each known folder changed between the first scan after `since` and the latest.
    public static func changes(_ scans: [StorageHistory.Scan], since: Date, min: UInt64 = 200 << 20) -> [Change] {
        let t = Int(since.timeIntervalSince1970)
        guard let last = scans.last, let first = scans.first(where: { $0.t >= t }), first.t < last.t else { return [] }
        return last.sizes.compactMap { k, v in
            let was = first.sizes[k] ?? 0
            let c = Change(key: k, from: was, to: v)
            return c.delta.magnitude >= min ? c : nil
        }
        .sorted { $0.delta.magnitude > $1.delta.magnitude }
    }

    public struct ChildChange: Equatable, Sendable, Identifiable {
        /// Name of the item inside the known folder.
        public let name: String
        public let from: UInt64
        public let to: UInt64
        public var delta: Int64 { Int64(to) - Int64(from) }
        public var id: String { name }
    }

    /// Scans in range that measured what is inside `key`.
    public static func childScans(_ scans: [StorageHistory.Scan], key: String, since: Date) -> [StorageHistory.Scan] {
        let t = Int(since.timeIntervalSince1970)
        return scans.filter { $0.t >= t && $0.children?[key] != nil }
    }

    /// What changed inside known folder `key` between the first and last scan in range that
    /// measured its items, biggest change first. Nil until two such scans exist. An item absent
    /// from a full (capped) list is unknown rather than zero, so it is left out.
    public static func childChanges(_ scans: [StorageHistory.Scan], key: String, since: Date, min: UInt64 = 10 << 20) -> [ChildChange]? {
        let have = childScans(scans, key: key, since: since)
        guard let a = have.first?.children?[key], let b = have.last?.children?[key], have.count >= 2 else { return nil }
        let cap = StorageHistory.childLimit
        return Set(a.keys).union(b.keys).compactMap { name -> ChildChange? in
            if a[name] == nil, a.count >= cap { return nil }
            if b[name] == nil, b.count >= cap { return nil }
            let c = ChildChange(name: name, from: a[name] ?? 0, to: b[name] ?? 0)
            return c.delta.magnitude >= min ? c : nil
        }
        .sorted { $0.delta.magnitude > $1.delta.magnitude }
    }

    public struct Found: Sendable, Codable {
        public var places: [String: UInt64] = [:]
        public var downloads: [FoundItem] = []
        public var installers: [FoundItem] = []
        public var movies: [FoundItem] = []
        public var photoFolders: [Clutter.PhotoFolder] = []
        public var unusedApps: [FoundItem] = []
        public var nodeModules: [FoundItem] = []
        public var localSnapshots = 0
        public init() {}
    }

    static func gb(_ b: UInt64) -> String { ReportDocument.bytes(b) }

    /// The groups of found files an insight can act on.
    public enum Kind: String, Sendable {
        case installers, oldDownloads, oldNodeModules, unusedApps, oldMovies
    }

    /// The files behind an insight, the same ones its headline counts.
    public static func items(_ kind: Kind, in found: Found, at now: Date) -> [FoundItem] {
        switch kind {
        case .installers: return found.installers
        case .oldDownloads: return found.downloads.filter { Clutter.isStale($0.used ?? $0.modified, days: 90, at: now) }
        case .oldNodeModules: return found.nodeModules.filter { Clutter.isStale($0.modified, days: 90, at: now) }
        case .unusedApps: return found.unusedApps
        case .oldMovies: return found.movies.filter { Clutter.isStale($0.used ?? $0.modified, days: 180, at: now) }
        }
    }

    /// The scan's findings without these paths (moved away since).
    public static func removing(_ paths: Set<String>, from f: Found) -> Found {
        var f = f
        let keep: (FoundItem) -> Bool = { !paths.contains($0.path) }
        f.downloads = f.downloads.filter(keep)
        f.installers = f.installers.filter(keep)
        f.movies = f.movies.filter(keep)
        f.unusedApps = f.unusedApps.filter(keep)
        f.nodeModules = f.nodeModules.filter(keep)
        return f
    }

    /// Rebuildable developer caches worth cleaning, biggest first.
    static let devPlaces = ["derivedData", "deviceSupport", "simulators", "npm", "pip", "yarn", "gradle", "maven", "cargo", "homebrew"]

    public static func insights(disk: DiskSpace, points: [StorageHistory.Point], scans: [StorageHistory.Scan],
                                found: Found, at now: Date) -> [Insight] {
        var out: [Insight] = []
        let perDay = growthPerDay(points.filter { $0.t >= Int(now.timeIntervalSince1970) - 7 * 86_400 })
        switch disk.level {
        case .critical:
            var x = Insight(id: "disk-critical", tone: .critical, symbol: "externaldrive.fill.badge.exclamationmark",
                            title: "The disk is almost full: \(gb(disk.available)) left",
                            detail: "\(Int(disk.usedShare * 100))% of \(gb(disk.total)) used. macOS needs free space for swap, updates and saving files.")
            x.why = "With little free space macOS cannot grow swap, so apps slow down or quit; updates refuse to install; apps can fail to save."
            x.steps = ["Empty the Trash.", "Move old downloads and installers to the Trash.", "Delete build caches and old simulators below.", "Move big videos and photo folders to an external drive."]
            x.fixes = [.review(card: "cleanups", label: "Quick cleanups")]
            out.append(x)
        case .low:
            var x = Insight(id: "disk-low", tone: .warning, symbol: "externaldrive.fill",
                            title: "Disk space is getting low: \(gb(disk.available)) left",
                            detail: "\(Int(disk.usedShare * 100))% of \(gb(disk.total)) used.")
            x.steps = ["Start with the Trash and Downloads, then the cleanups below."]
            x.fixes = [.review(card: "cleanups", label: "Quick cleanups")]
            out.append(x)
        case .ok: break
        }
        if let days = daysUntilFull(free: disk.available, perDay: perDay), days < 60 {
            var x = Insight(id: "disk-forecast", tone: days < 14 ? .critical : .warning, symbol: "chart.line.uptrend.xyaxis",
                            title: "At this pace the disk is full in about \(Int(days.rounded())) days",
                            detail: "Use is growing by \(gb(UInt64(perDay ?? 0))) a day over the last week.")
            x.why = "A straight line through the last 7 days of readings. A one-off download skews it; steady growth usually means a cache, a VM disk or a sync folder."
            x.steps = ["Check What grew below for the folder that is growing."]
            x.fixes = [.review(card: "grew", label: "What grew")]
            out.append(x)
        }
        if let j = jumps(points.filter { $0.t >= Int(now.timeIntervalSince1970) - 86_400 }).first, j.bytes > 0 {
            var x = Insight(id: "disk-jump", tone: .info, symbol: "arrow.up.forward.square",
                            title: "\(gb(UInt64(j.bytes))) was used at \(j.from.formatted(.dateTime.weekday(.abbreviated).hour().minute()))",
                            detail: "Within an hour. Large downloads, a VM growing or a backup are the usual causes.")
            x.fixes = [.review(card: "grew", label: "What grew")]
            out.append(x)
        }
        if let t = found.places["trash"], t >= 1 << 30 {
            var x = Insight(id: "disk-trash", tone: t >= 10 << 30 ? .warning : .info, symbol: "trash.fill",
                            title: "\(gb(t)) is sitting in the Trash", detail: "Deleted files keep using space until the Trash is emptied.")
            x.fixes = [.emptyTrash]
            out.append(x)
        }
        let installers = found.installers.reduce(UInt64(0)) { $0 + $1.bytes }
        if installers >= 1 << 30 {
            var x = Insight(id: "disk-installers", tone: .info, symbol: "shippingbox.fill",
                            title: "\(gb(installers)) of installers and disk images",
                            detail: "\(found.installers.count) .dmg, .pkg and .iso files. Once installed, they are rarely needed again.")
            x.fixes = [.trashFound(.installers, count: found.installers.count), .review(card: "packages:Installers", label: "Review")]
            out.append(x)
        }
        let oldDownloads = items(.oldDownloads, in: found, at: now)
        let oldBytes = oldDownloads.reduce(UInt64(0)) { $0 + $1.bytes }
        if oldBytes >= 2 << 30 {
            var x = Insight(id: "disk-olddownloads", tone: .info, symbol: "arrow.down.circle.fill",
                            title: "\(gb(oldBytes)) in Downloads is over 3 months old",
                            detail: "\(oldDownloads.count) items not opened since they arrived.")
            x.fixes = [.trashFound(.oldDownloads, count: oldDownloads.count), .review(card: "downloads", label: "Review")]
            out.append(x)
        }
        let dev = devPlaces
            .compactMap { k in found.places[k].map { (k, $0) } }.filter { $0.1 >= 1 << 30 }
        let devBytes = dev.reduce(UInt64(0)) { $0 + $1.1 }
        if devBytes >= 5 << 30 {
            let sorted = dev.sorted { $0.1 > $1.1 }
            var x = Insight(id: "disk-dev", tone: .info, symbol: "hammer.fill",
                            title: "\(gb(devBytes)) of developer caches can be rebuilt",
                            detail: sorted.prefix(3).map { "\(StoragePlace.named($0.0)?.name ?? $0.0) \(gb($0.1))" }.joined(separator: ", ") + ".")
            x.fixes = [.cleanPlaces(keys: sorted.map(\.0)), .review(card: "cleanups", label: "Review")]
            out.append(x)
        }
        let nm = items(.oldNodeModules, in: found, at: now)
        let nmBytes = nm.reduce(UInt64(0)) { $0 + $1.bytes }
        if nmBytes >= 1 << 30 {
            var x = Insight(id: "disk-nodemodules", tone: .info, symbol: "cube.box.fill",
                            title: "\(gb(nmBytes)) of node_modules in projects untouched for 3 months",
                            detail: "\(nm.count) folders. npm install brings them back when you return to a project.")
            x.fixes = [.trashFound(.oldNodeModules, count: nm.count), .review(card: "packages:node_modules", label: "Review")]
            out.append(x)
        }
        let apps = found.unusedApps.reduce(UInt64(0)) { $0 + $1.bytes }
        if apps >= 2 << 30 {
            var x = Insight(id: "disk-apps", tone: .info, symbol: "app.badge",
                            title: "\(gb(apps)) of apps not opened in 6 months",
                            detail: found.unusedApps.prefix(3).map { $0.name.replacingOccurrences(of: ".app", with: "") }.joined(separator: ", ") + (found.unusedApps.count > 3 ? " and \(found.unusedApps.count - 3) more." : "."))
            // Apps one by one: removing all at once is too blunt.
            x.fixes = [.review(card: "packages:Unused apps", label: "Review")]
            out.append(x)
        }
        let movies = items(.oldMovies, in: found, at: now)
        let movieBytes = movies.reduce(UInt64(0)) { $0 + $1.bytes }
        if movieBytes >= 2 << 30 {
            var x = Insight(id: "disk-movies", tone: .info, symbol: "film.fill",
                            title: "\(gb(movieBytes)) of videos not watched in 6 months",
                            detail: "\(movies.count) videos. Move them to an external drive or cloud storage.")
            x.fixes = [.archiveFound(.oldMovies, count: movies.count), .review(card: "videos", label: "Review")]
            out.append(x)
        }
        let photos = found.photoFolders.filter { Clutter.isStale($0.newest, days: 365, at: now) }
        let photoBytes = photos.reduce(UInt64(0)) { $0 + $1.bytes }
        if photoBytes >= 1 << 30 {
            var x = Insight(id: "disk-photos", tone: .info, symbol: "photo.stack.fill",
                            title: "\(gb(photoBytes)) of photo folders unchanged for over a year",
                            detail: "\(photos.count) folders ready to archive to an external drive or cloud storage.")
            x.fixes = [.review(card: "photos", label: "Review")]
            out.append(x)
        }
        if let p = found.places["pictures"], p >= 20 << 30 {
            var x = Insight(id: "disk-photos-library", tone: .info, symbol: "photo.on.rectangle.angled",
                            title: "Pictures and the Photos library hold \(gb(p))",
                            detail: "Usually the biggest thing on a Mac. Photos can keep the originals in iCloud and small copies here.")
            x.steps = ["Open Photos, Settings, iCloud, and choose Optimize Mac Storage (needs iCloud Photos and enough iCloud space).",
                       "Or move the library to an external drive: quit Photos, drag the library across, then open it from there while holding Option."]
            x.fixes = [.openApp(bundleID: "com.apple.Photos", name: "Photos"), .review(card: "folders", label: "Review")]
            out.append(x)
        }
        if found.localSnapshots > 0, disk.level != .ok {
            out.append(Insight(id: "disk-snapshots", tone: .info, symbol: "clock.arrow.circlepath",
                               title: "\(found.localSnapshots) local Time Machine snapshot\(found.localSnapshots == 1 ? "" : "s")",
                               detail: "macOS deletes these by itself when space runs short; they are part of the purgeable space."))
        }
        return out
    }
}
