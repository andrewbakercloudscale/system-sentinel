import AppKit
import SentinelCore
import SwiftUI

/// The Storage tab's data: disk space every minute, a scan of known folders and Spotlight
/// finds every 6 hours, and a walk of the home folder once a day.
@MainActor
final class StorageStore: ObservableObject {
    @Published var disk: DiskSpace?
    @Published var found = StorageAnalysis.Found()
    @Published var foundAt: Date?
    @Published var largeFiles: [FoundItem] = []
    @Published var tree: FolderTree?
    @Published var scanning = false
    @Published var treeProgress: (bytes: UInt64, files: Int)?
    @Published var insights: [Insight] = []
    /// Actions running, by key, so their buttons show progress.
    @Published var working: Set<String> = []
    /// False when macOS hides the Trash (and Mail, Messages…) without Full Disk Access.
    @Published var fullAccess = true

    let history: StorageHistory
    private let treeURL: URL
    private var timer: Timer?
    private var treeCancelled = false
    var toast: (Model.Toast) -> Void = { _ in }
    let home = FileManager.default.homeDirectoryForCurrentUser

    init(supportDir: URL, readOnly: Bool) {
        history = StorageHistory(fileURL: supportDir.appendingPathComponent("storage-90d.json"), readOnly: readOnly)
        treeURL = supportDir.appendingPathComponent("storage-tree.json")
        if let d = try? Data(contentsOf: treeURL), let t = try? JSONDecoder().decode(FolderTree.self, from: d) { tree = t }
        readDisk()
        // Snapshots run from a throwaway, ad-hoc signed copy that macOS sees as a new app every
        // build, so scanning Downloads and Documents there asks for permission every time.
        guard !readOnly else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodic() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.scan() }
    }

    private func periodic() {
        readDisk()
        let now = Date()
        if !scanning, foundAt.map({ now.timeIntervalSince($0) >= 6 * 3600 }) ?? true { scan() }
        if treeProgress == nil, tree.map({ now.timeIntervalSince($0.at) >= 86_400 }) ?? true, foundAt != nil { scanTree() }
    }

    func readDisk() {
        guard let d = DiskSpace.read() else { return }
        disk = d
        history.record(d, at: Date())
        refreshInsights()
    }

    func refreshInsights() {
        guard let d = disk else { return }
        insights = StorageAnalysis.insights(disk: d, points: history.points, scans: history.scans, found: found, at: Date())
    }

    // MARK: Scans

    /// Known folders, Downloads, and what Spotlight finds: installers, videos, photos, old apps,
    /// node_modules and big files.
    func scan() {
        guard !scanning else { return }
        scanning = true
        let home = self.home
        Task.detached(priority: .utility) {
            let result = StorageStore.findEverything(home: home)
            await MainActor.run {
                self.found = result.found
                self.largeFiles = result.large
                self.fullAccess = result.fullAccess
                self.foundAt = Date()
                self.scanning = false
                self.history.record(scan: result.found.places, at: Date())
                self.refreshInsights()
            }
        }
    }

    nonisolated static func findEverything(home: URL) -> (found: StorageAnalysis.Found, large: [FoundItem], fullAccess: Bool) {
        var f = StorageAnalysis.Found()
        let h = home.path
        let fm = FileManager.default
        let fullAccess = (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".Trash").path)) != nil
        f.places = DiskUsage.places(home: home, skip: fullAccess ? [] : FolderTree.otherApps)

        // Downloads: what is at the top, with when it arrived.
        let dl = home.appendingPathComponent("Downloads")
        f.downloads = ((try? fm.contentsOfDirectory(at: dl, includingPropertiesForKeys: [.addedToDirectoryDateKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url -> FoundItem? in
                guard var item = Spotlight.item(url.path, folderDeadline: 5) else { return nil }
                item.used = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate ?? item.modified
                return item
            }
            .sorted { $0.bytes > $1.bytes }

        let names = Clutter.installerExtensions.map { "kMDItemFSName == \"*.\($0)\"c" }.joined(separator: " || ")
        f.installers = Spotlight.find("(\(names)) && kMDItemFSSize > 10485760", in: h)
            .filter { !$0.contains("/Library/") && !$0.contains("/.Trash/") }
            .compactMap { Spotlight.item($0) }
            .sorted { $0.bytes > $1.bytes }

        f.movies = Spotlight.find("kMDItemContentTypeTree == \"public.movie\" && kMDItemFSSize > 104857600", in: h)
            .filter { !$0.contains("/Library/") && !$0.contains("/.Trash/") }
            .compactMap { Spotlight.item($0, lastUsed: true) }
            .sorted { $0.bytes > $1.bytes }

        let images = Spotlight.find("kMDItemContentTypeTree == \"public.image\" && kMDItemFSSize > 102400", in: h)
            .filter { !$0.contains("/Library/") && !$0.contains(".photoslibrary/") && !$0.contains("/.Trash/") }
            .compactMap { p -> FoundItem? in
                let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey])
                return v.map { FoundItem(path: p, bytes: UInt64($0.totalFileAllocatedSize ?? 0), modified: $0.contentModificationDate) }
            }
        f.photoFolders = Clutter.photoFolders(images)

        let me = Bundle.main.bundlePath
        f.unusedApps = (Spotlight.find("kMDItemContentType == \"com.apple.application-bundle\" && kMDItemLastUsedDate < $time.today(-180)", in: "/Applications")
            + Spotlight.find("kMDItemContentType == \"com.apple.application-bundle\" && kMDItemLastUsedDate < $time.today(-180)", in: home.appendingPathComponent("Applications").path))
            .filter { p in p != me && !p.dropFirst().contains(".app/") && !p.hasPrefix("/Applications/Utilities") && !p.contains("/Library/") }
            .compactMap { Spotlight.item($0, lastUsed: true) }
            .filter { $0.bytes >= 50 << 20 }
            .sorted { $0.bytes > $1.bytes }

        f.nodeModules = Clutter.topNodeModules(Spotlight.find("kMDItemFSName == \"node_modules\"", in: h))
            .filter { !$0.contains("/Library/") && !$0.contains("/.Trash/") }
            .compactMap { p -> FoundItem? in
                guard var item = Spotlight.item(p, folderDeadline: 5) else { return nil }
                // The project's own date says when it was last worked on.
                let project = (p as NSString).deletingLastPathComponent
                item.modified = (try? URL(fileURLWithPath: project).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? item.modified
                return item
            }
            .filter { $0.bytes >= 50 << 20 }
            .sorted { $0.bytes > $1.bytes }

        let snap = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        f.localSnapshots = snap.split(separator: "\n").filter { $0.contains("com.apple") }.count

        let large = Spotlight.find("kMDItemFSSize > 524288000", in: h)
            .filter { !$0.contains("/.Trash/") }
            .compactMap { Spotlight.item($0, folderDeadline: 0, lastUsed: true) }
            .filter { $0.bytes >= 500 << 20 }
            .sorted { $0.bytes > $1.bytes }
        return (f, Array(large.prefix(30)), fullAccess)
    }

    /// Walks the whole home folder for the folder breakdown. Minutes on a big disk, in the background.
    func scanTree() {
        guard treeProgress == nil else { return }
        treeProgress = (0, 0)
        treeCancelled = false
        let home = self.home, url = treeURL
        let skip = fullAccess ? FolderTree.skipped : FolderTree.skipped.union(FolderTree.otherApps)
        Task.detached(priority: .background) {
            let t = FolderTree.scan(home, skip: skip, progress: { b, n in
                Task { @MainActor in if self.treeProgress != nil { self.treeProgress = (b, n) } }
            }, cancelled: { StorageStore.cancelFlag })
            let cancelled = StorageStore.cancelFlag
            StorageStore.cancelFlag = false
            if !cancelled, let data = try? JSONEncoder().encode(t) { try? data.write(to: url, options: .atomic) }
            await MainActor.run {
                if !cancelled { self.tree = t }
                self.treeProgress = nil
            }
        }
    }

    nonisolated(unsafe) static var cancelFlag = false
    func cancelTree() { StorageStore.cancelFlag = true }

    // MARK: Actions

    private func afterCleanup(_ title: String, before: DiskSpace?, detail: String? = nil) {
        readDisk()
        let freed = (disk?.available ?? 0) > (before?.available ?? 0) ? (disk?.available ?? 0) - (before?.available ?? 0) : 0
        toast(Model.Toast(ok: true, title: freed >= 1 << 20 ? "\(title): \(ReportDocument.bytes(freed)) freed" : title, detail: detail))
        scan()
    }

    func emptyTrash() {
        guard !working.contains("trash") else { return }
        working.insert("trash")
        let before = disk
        Task.detached {
            let ok = StorageStore.osascript("tell application \"Finder\" to empty trash")
            // Finder empties in the background; give it a moment before measuring.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                self.working.remove("trash")
                if ok { self.afterCleanup("Trash emptied", before: before) }
                else { self.toast(Model.Toast(ok: false, title: "The Trash was not emptied", detail: "Allow System Sentinel to control Finder in System Settings, Privacy & Security, Automation.")) }
            }
        }
    }

    func moveToTrash(_ items: [FoundItem], key: String) {
        guard !items.isEmpty, !working.contains(key) else { return }
        working.insert(key)
        Task.detached {
            var moved: UInt64 = 0, n = 0
            var failed: [String] = []
            for i in items {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: i.path), resultingItemURL: nil)
                    moved += i.bytes; n += 1
                } catch { failed.append(i.name) }
            }
            let (m, count, bad) = (moved, n, failed)
            await MainActor.run {
                let (moved, n, failed) = (m, count, bad)
                self.working.remove(key)
                let detail = failed.isEmpty ? "Empty the Trash to get the space back."
                    : "Could not move \(failed.prefix(3).joined(separator: ", ")): it needs an administrator. Drag it to the Trash in Finder."
                self.toast(Model.Toast(ok: failed.isEmpty, title: "Moved \(n) item\(n == 1 ? "" : "s") (\(ReportDocument.bytes(moved))) to the Trash", detail: detail))
                self.scan()
            }
        }
    }

    func clean(_ place: StoragePlace) {
        guard let how = place.clean, !working.contains(place.key) else { return }
        if how == .emptyTrash { return emptyTrash() }
        let dir = home.appendingPathComponent(place.path)
        // A folder replaced by a symlink (say ~/.npm/_cacache pointing at Documents) must not
        // have its target emptied: only the real folder at the expected place is cleaned.
        if how == .deleteContents, dir.resolvingSymlinksInPath().path != dir.standardizedFileURL.path
            || ((try? FileManager.default.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType) == .typeSymbolicLink {
            toast(Model.Toast(ok: false, title: "\(place.name) was not cleaned", detail: "\(place.path) is a link to somewhere else, so it was left alone."))
            return
        }
        working.insert(place.key)
        let before = disk
        Task.detached {
            var problem: String?
            switch how {
            case .deleteContents:
                for c in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    do { try FileManager.default.removeItem(at: c) } catch { problem = "Some files could not be deleted." }
                }
            case .command(let path, let args):
                let tool = FileManager.default.isExecutableFile(atPath: path) ? path : (path.hasSuffix("/brew") ? "/usr/local/bin/brew" : path)
                if !FileManager.default.isExecutableFile(atPath: tool) { problem = "\(URL(fileURLWithPath: path).lastPathComponent) is not installed." }
                else { _ = StorageStore.run(tool, args) }
            case .emptyTrash: break
            }
            let issue = problem
            await MainActor.run {
                let problem = issue
                self.working.remove(place.key)
                if let p = problem { self.toast(Model.Toast(ok: false, title: "\(place.name) only partly cleaned", detail: p)) }
                else { self.afterCleanup("\(place.name) cleaned", before: before) }
            }
        }
    }

    /// Moves items to a folder the user picks, usually an external drive, to archive them.
    func archive(_ items: [FoundItem], key: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move here"
        panel.message = "Choose where to move \(items.count == 1 ? items[0].name : "\(items.count) items") (\(ReportDocument.bytes(items.reduce(0) { $0 + $1.bytes }))), for example an external drive."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        working.insert(key)
        let before = disk
        Task.detached {
            var failed: [String] = []
            for i in items {
                let src = URL(fileURLWithPath: i.path)
                do { try FileManager.default.moveItem(at: src, to: dest.appendingPathComponent(src.lastPathComponent)) }
                catch { failed.append(i.name) }
            }
            let bad = failed
            await MainActor.run {
                let failed = bad
                self.working.remove(key)
                if failed.isEmpty { self.afterCleanup("Moved to \(dest.lastPathComponent)", before: before) }
                else { self.toast(Model.Toast(ok: false, title: "Not everything was moved", detail: "Failed: \(failed.prefix(3).joined(separator: ", ")).")) }
            }
        }
    }

    static func confirm(_ title: String, _ text: String, button: String, destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.buttons[0].hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    nonisolated static func osascript(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @discardableResult
    nonisolated static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
