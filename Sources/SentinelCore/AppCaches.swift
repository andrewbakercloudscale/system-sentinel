import Foundation

/// One app's cache: its folder in ~/Library/Caches and, for a sandboxed app, the Caches
/// folder inside its container. Everything in them is rebuilt when the app needs it.
public struct AppCache: Identifiable, Equatable, Sendable {
    /// The folder name, usually the app's bundle id (com.microsoft.Outlook).
    public let id: String
    /// Absolute paths of the cache folders.
    public var folders: [String]
    public var bytes: UInt64

    public init(id: String, folders: [String], bytes: UInt64) {
        self.id = id
        self.folders = folders
        self.bytes = bytes
    }
}

public enum AppCaches {
    /// Smaller caches are not listed.
    public static let minimumBytes: UInt64 = 1 << 20

    /// Apple's own apps whose cache is worth offering: the rest of com.apple.* belongs to
    /// macOS (pending downloads, iCloud state, some protected), so it is left alone.
    static let appleApps: Set<String> = ["com.apple.Safari", "com.apple.mail", "com.apple.Music", "com.apple.TV",
                                         "com.apple.Maps", "com.apple.news", "com.apple.podcasts", "com.apple.Notes"]

    /// Folders in ~/Library/Caches that are not an app's cache to clear: macOS's own,
    /// and downloads that are slow to get back and are not rebuilt on their own.
    static let leftAlone: Set<String> = ["CloudKit", "GeoServices", "FamilyCircle", "PassKit", "com.crashlytics",
                                         "ms-playwright", "ms-playwright-go", "Homebrew", "TemporaryItems", "Metadata"]

    /// Whether a cache folder may be listed and cleared.
    public static func offered(_ name: String, own: String?) -> Bool {
        guard !name.hasPrefix("."), !leftAlone.contains(name), name != own else { return false }
        if name.hasPrefix("com.apple.") { return appleApps.contains(name) }
        return true
    }

    /// Groups the measured folders by app, drops what is not offered or too small, biggest first.
    /// `user` is ~/Library/Caches/<name>; `containers` is ~/Library/Containers/<id>/Data/Library/Caches.
    public static func group(user: [(name: String, path: String, bytes: UInt64)],
                             containers: [(id: String, path: String, bytes: UInt64)], own: String?) -> [AppCache] {
        var by: [String: AppCache] = [:]
        for f in user.map({ ($0.name, $0.path, $0.bytes) }) + containers.map({ ($0.id, $0.path, $0.bytes) }) where offered(f.0, own: own) {
            by[f.0, default: AppCache(id: f.0, folders: [], bytes: 0)].folders.append(f.1)
            by[f.0]!.bytes += f.2
        }
        return by.values.filter { $0.bytes >= minimumBytes }.sorted { ($0.bytes, $1.id) > ($1.bytes, $0.id) }
    }

    /// Whether `path` is a cache folder this may empty: exactly ~/Library/Caches/<name> or
    /// ~/Library/Containers/<id>/Data/Library/Caches, with no `..` or link in the way, so a
    /// stale or tampered list cannot point the delete anywhere else.
    public static func isCacheFolder(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/"), !path.contains("//"), !path.hasSuffix("/") else { return false }
        let rest = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard !rest.contains(".."), !rest.contains(".") else { return false }
        if rest.count == 3, rest[0] == "Library", rest[1] == "Caches" { return !rest[2].isEmpty }
        if rest.count == 6, rest[0] == "Library", rest[1] == "Containers", !rest[2].isEmpty,
           rest[3] == "Data", rest[4] == "Library", rest[5] == "Caches" { return true }
        return false
    }
}
