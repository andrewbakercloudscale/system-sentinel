import AppKit
import SentinelCore
import SwiftUI

// MARK: Measuring and clearing

extension StorageStore {
    /// Measures every app's cache in the background. Containers are only read with Full Disk
    /// Access: without it, each one asks "access data from other apps".
    func scanCaches() {
        guard !cachesMeasuring else { return }
        cachesMeasuring = true
        let home = self.home, full = fullAccess, own = Bundle.main.bundleIdentifier
        Task.detached(priority: .utility) {
            let list = StorageStore.measureCaches(home: home, containers: full, own: own)
            await MainActor.run {
                self.caches = list
                self.cachesMeasuring = false
            }
        }
    }

    nonisolated static func measureCaches(home: URL, containers: Bool, own: String?) -> [AppCache] {
        let fm = FileManager.default
        let end = Date().addingTimeInterval(30)
        let cachesDir = home.appendingPathComponent("Library/Caches")
        let user = ((try? fm.contentsOfDirectory(atPath: cachesDir.path)) ?? []).filter { AppCaches.offered($0, own: own) }.compactMap { name -> (name: String, path: String, bytes: UInt64)? in
            let url = cachesDir.appendingPathComponent(name)
            guard realFolder(url), let s = DiskUsage.size(of: url, deadline: end) else { return nil }
            return (name, url.path, s.bytes)
        }
        var boxed: [(id: String, path: String, bytes: UInt64)] = []
        if containers {
            let dir = home.appendingPathComponent("Library/Containers")
            for id in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where AppCaches.offered(id, own: own) {
                let url = dir.appendingPathComponent(id).appendingPathComponent("Data/Library/Caches")
                guard realFolder(url), let s = DiskUsage.size(of: url, deadline: end) else { continue }
                boxed.append((id, url.path, s.bytes))
            }
        }
        return AppCaches.group(user: user, containers: boxed, own: own)
    }

    /// A real folder, not a link to somewhere else (a cache folder pointed at Documents must
    /// not have Documents emptied).
    nonisolated static func realFolder(_ url: URL) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return a[.type] as? FileAttributeType == .typeDirectory && url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
    }

    /// The running app a cache belongs to, if any.
    static func runningApp(_ cache: AppCache) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.caseInsensitiveCompare(cache.id) == .orderedSame }
    }

    /// The app's name, when an installed app has this bundle id; otherwise the folder name.
    static func appName(_ cache: AppCache) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cache.id) else { return cache.id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Empties the given caches, skipping any whose app is open (it would write them straight
    /// back and could misbehave). With `quitFirst`, an open app is quit, its cache emptied
    /// and the app opened again.
    func clearCaches(_ list: [AppCache], key: String, quitFirst: Bool = false) {
        guard !working.contains(key) else { return }
        working.insert(key)
        let home = self.home.path
        var skipped: [String] = []
        var go: [AppCache] = []
        var reopen: [URL] = []
        var quitting: [NSRunningApplication] = []
        for c in list {
            if let app = Self.runningApp(c) {
                if quitFirst { quitting.append(app); if let u = app.bundleURL { reopen.append(u) }; go.append(c) }
                else { skipped.append(Self.appName(c)) }
            } else { go.append(c) }
        }
        quitting.forEach { $0.terminate() }
        Task.detached {
            // Give an app up to 15 seconds to quit; one that will not is left alone.
            var stillOpen: Set<String> = []
            if !quitting.isEmpty {
                let end = Date().addingTimeInterval(15)
                while Date() < end, quitting.contains(where: { !$0.isTerminated }) { try? await Task.sleep(nanoseconds: 300_000_000) }
                stillOpen = Set(quitting.filter { !$0.isTerminated }.compactMap { $0.bundleIdentifier?.lowercased() })
            }
            var freed: UInt64 = 0, failed = 0
            for c in go where !stillOpen.contains(c.id.lowercased()) {
                for f in c.folders {
                    let url = URL(fileURLWithPath: f)
                    guard AppCaches.isCacheFolder(f, home: home), StorageStore.realFolder(url) else { failed += 1; continue }
                    for item in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                        do { try FileManager.default.removeItem(at: item) } catch { failed += 1 }
                    }
                }
                freed += c.bytes
            }
            for u in reopen { NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil) }
            let (gone, bad, open) = (freed, failed, stillOpen)
            await MainActor.run {
                self.working.remove(key)
                var notes: [String] = []
                if !skipped.isEmpty { notes.append("Skipped \(skipped.prefix(4).joined(separator: ", ")) because \(skipped.count == 1 ? "it is" : "they are") open: use Quit and clear on \(skipped.count == 1 ? "its row" : "their rows").") }
                if !open.isEmpty { notes.append("\(open.count) app\(open.count == 1 ? "" : "s") did not quit, so \(open.count == 1 ? "its" : "their") cache was left.") }
                if bad > 0 { notes.append("\(bad) file\(bad == 1 ? "" : "s") in use could not be deleted.") }
                self.toast(Model.Toast(ok: skipped.isEmpty && open.isEmpty && bad == 0,
                                       title: "Cleared about \(ReportDocument.bytes(gone)) of caches",
                                       detail: notes.isEmpty ? "Apps rebuild them as needed, so the first launch may be a little slower." : notes.joined(separator: " ")))
                self.readDisk()
                self.scanCaches()
            }
        }
    }
}

// MARK: Card

struct CachesCard: View {
    @ObservedObject var store: StorageStore
    @State private var showAll = false
    private let tint = Tab.storage.color

    var body: some View {
        let list = store.caches ?? []
        let total = list.reduce(UInt64(0)) { $0 + $1.bytes }
        Card(title: "App caches", symbol: "archivebox.fill", tint: tint,
             trailing: AnyView(trailing(list, total: total))) {
            if store.caches == nil {
                Text(store.cachesMeasuring ? "Measuring…" : "Not measured yet.").font(.caption).foregroundStyle(.secondary)
            } else if list.isEmpty {
                Text("No app keeps a cache worth clearing.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(showAll ? list : Array(list.prefix(10))) { c in row(c, max: list.first?.bytes ?? 1) }
            if list.count > 10 {
                Button(showAll ? "Show fewer" : "Show all \(list.count)") { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            Text("Files apps keep to start and load faster. Clearing fixes an app that shows stale content or misbehaves after an update, and frees space; the app rebuilds what it needs, so it may be slower the first time. Caches of open apps are skipped: Quit and clear closes the app, clears it and opens it again."
                 + (store.fullAccess ? "" : " Sandboxed apps (Outlook, Teams…) keep theirs in their container, which needs Full Disk Access to see."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if store.caches == nil { store.scanCaches() } }
    }

    @ViewBuilder private func trailing(_ list: [AppCache], total: UInt64) -> some View {
        HStack(spacing: 8) {
            if total > 0 { Text(ReportDocument.bytes(total)).font(.callout.weight(.bold)).foregroundStyle(tint) }
            if store.working.contains("caches-all") {
                BusyButton(title: "Clearing…")
            } else if !list.isEmpty {
                let open = list.filter { StorageStore.runningApp($0) != nil }
                RowButton(title: "Clear all", symbol: "sparkles", color: Theme.heat(100), filled: true) {
                    StorageStore.confirm("Clear all \(list.count) app caches?",
                                         "Frees about \(ReportDocument.bytes(list.filter { StorageStore.runningApp($0) == nil }.reduce(0) { $0 + $1.bytes })). Apps rebuild them as needed."
                                         + (open.isEmpty ? "" : " \(open.count) open app\(open.count == 1 ? " is" : "s are") skipped: \(open.prefix(3).map(StorageStore.appName).joined(separator: ", "))."),
                                         button: "Clear all") {
                        store.clearCaches(list, key: "caches-all")
                    }
                }
            }
            RowButton(title: "Measure", symbol: "arrow.clockwise") { store.scanCaches() }
                .disabled(store.cachesMeasuring)
        }
    }

    private func row(_ c: AppCache, max: UInt64) -> some View {
        let name = StorageStore.appName(c)
        let app = StorageStore.runningApp(c)
        let key = "cache-" + c.id
        return HStack(spacing: 10) {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 24, height: 24)
            } else {
                SymbolTile(symbol: "archivebox.fill", color: tint, size: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                    if app != nil {
                        Text("open").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Tab.network.color))
                    }
                }
                Text(c.folders.map { $0.replacingOccurrences(of: store.home.path, with: "~") }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .tip(c.folders.joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            Text(ReportDocument.bytes(c.bytes)).font(.callout.weight(.bold)).monospacedDigit()
            if store.working.contains(key) || store.working.contains("caches-all") {
                BusyButton(title: "Clearing…").frame(minWidth: 110, alignment: .trailing)
            } else if app != nil {
                RowButton(title: "Quit and clear", symbol: "arrow.clockwise", color: Theme.heat(100), filled: true) {
                    StorageStore.confirm("Quit \(name) and clear its cache?",
                                         "\(name) is asked to quit (it saves its work as usual), its \(ReportDocument.bytes(c.bytes)) cache is cleared, then it opens again.",
                                         button: "Quit and clear") {
                        store.clearCaches([c], key: key, quitFirst: true)
                    }
                }
                .frame(minWidth: 110, alignment: .trailing)
            } else {
                RowButton(title: "Clear", symbol: "sparkles", color: Theme.heat(100), filled: true) {
                    StorageStore.confirm("Clear \(name)'s cache?", "Frees about \(ReportDocument.bytes(c.bytes)). \(name) rebuilds what it needs.", button: "Clear") {
                        store.clearCaches([c], key: key)
                    }
                }
                .frame(minWidth: 110, alignment: .trailing)
            }
        }
    }
}
