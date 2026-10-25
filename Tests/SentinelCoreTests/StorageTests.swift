import XCTest
@testable import SentinelCore

final class StorageTests: XCTestCase {
    let gb: UInt64 = 1 << 30

    func testDiskLevels() {
        XCTAssertEqual(DiskSpace(total: 500 * gb, free: 100 * gb, available: 120 * gb).level, .ok)
        XCTAssertEqual(DiskSpace(total: 300 * gb, free: 20 * gb, available: 22 * gb).level, .low)
        XCTAssertEqual(DiskSpace(total: 500 * gb, free: 5 * gb, available: 8 * gb).level, .critical)
        let d = DiskSpace(total: 500 * gb, free: 30 * gb, available: 40 * gb)
        XCTAssertEqual(d.purgeable, 10 * gb)
        XCTAssertEqual(d.used, 460 * gb)
    }

    func testGrowthForecastAndJumps() {
        // 3 days, 2 GB a day, plus a 5 GB jump on day 2.
        var points: [StorageHistory.Point] = []
        for i in 0..<(3 * 144) {
            let t = i * 600
            var used = 100 * gb + UInt64(Double(2 * gb) * Double(t) / 86_400)
            if t >= 86_400 + 3600 { used += 5 * gb }
            points.append(.init(t: t, used: used, free: 50 * gb, purgeable: 0))
        }
        let g = StorageAnalysis.growthPerDay(points)!
        XCTAssertGreaterThan(g, Double(2 * gb))
        XCTAssertLessThan(g, Double(6 * gb))
        XCTAssertEqual(StorageAnalysis.daysUntilFull(free: 50 * gb, perDay: g)!, 50 * Double(gb) / g, accuracy: 0.01)
        XCTAssertNil(StorageAnalysis.daysUntilFull(free: 50 * gb, perDay: -1))
        let jumps = StorageAnalysis.jumps(points)
        XCTAssertEqual(jumps.count, 1)
        XCTAssertGreaterThanOrEqual(jumps[0].bytes, Int64(5 * gb))
        XCTAssertNil(StorageAnalysis.growthPerDay(Array(points.prefix(10))))
        // Rising all week, then 30 GB cleared at the end: emptier than it started, so not filling.
        var cleared = points
        cleared[cleared.count - 1].used -= 30 * gb
        XCTAssertLessThan(StorageAnalysis.growthPerDay(cleared)!, 0)
    }

    func testChangesBetweenScans() {
        let scans = [StorageHistory.Scan(t: 0, sizes: ["downloads": 10 * gb, "trash": gb]),
                     StorageHistory.Scan(t: 86_400, sizes: ["downloads": 14 * gb, "trash": gb, "docker": 30 * gb])]
        let c = StorageAnalysis.changes(scans, since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(c.map(\.key), ["docker", "downloads"])
        XCTAssertEqual(c[1].delta, Int64(4 * gb))
    }

    func testCulpritsSkipWrappers() {
        let t = FolderTree(sizes: ["": 100 * gb, "Library": 60 * gb, "Library/Containers": 50 * gb,
                                   "Library/Containers/com.docker.docker": 48 * gb,
                                   "Movies": 20 * gb, "Movies/A": 6 * gb, "Movies/B": 8 * gb, "Movies/C": 7 * gb],
                           at: Date(), seconds: 1, files: 1, unreadable: [])
        let c = t.culprits()
        XCTAssertEqual(c.first?.path, "Library/Containers/com.docker.docker")
        XCTAssertTrue(c.contains { $0.path == "Movies" })
        XCTAssertFalse(c.contains { $0.path == "Library" || $0.path == "Library/Containers" })
        XCTAssertEqual(t.children(of: "Movies").map(\.path), ["Movies/B", "Movies/C", "Movies/A"])
        let photos = FolderTree(sizes: ["": 100 * gb, "Pictures": 90 * gb, "Pictures/Photos Library.photoslibrary": 90 * gb,
                                        "Pictures/Photos Library.photoslibrary/originals": 80 * gb,
                                        "Pictures/Photos Library.photoslibrary/originals/A": 9 * gb],
                                at: Date(), seconds: 1, files: 1, unreadable: [])
        XCTAssertEqual(photos.culprits().map(\.path), ["Pictures/Photos Library.photoslibrary"], "a library is listed whole")
        XCTAssertEqual(t.children(of: "").first?.path, "Library")
    }

    func testTreeScanCountsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 1 << 20).write(to: root.appendingPathComponent("a/b/one"))
        try Data(count: 1 << 20).write(to: root.appendingPathComponent("a/two"))
        defer { try? FileManager.default.removeItem(at: root) }
        let t = FolderTree.scan(root)
        XCTAssertEqual(t.files, 2)
        XCTAssertGreaterThanOrEqual(t.sizes[""] ?? 0, 2 << 20)
        XCTAssertGreaterThanOrEqual(t.sizes["a"] ?? 0, 2 << 20)
        XCTAssertNotNil(DiskUsage.size(of: root))
    }

    func testClutterKindsAndPhotoFolders() {
        XCTAssertEqual(Clutter.kind(of: "/x/Setup.DMG"), .installer)
        XCTAssertEqual(Clutter.kind(of: "/x/a.tar.gz"), .archive)
        XCTAssertEqual(Clutter.kind(of: "/x/clip.mov"), .video)
        XCTAssertEqual(Clutter.kind(of: "/Applications/X.app"), .app)
        XCTAssertEqual(Clutter.topNodeModules(["/p/node_modules", "/p/node_modules/x/node_modules", "/q/node_modules"]),
                       ["/p/node_modules", "/q/node_modules"])
        let old = Date(timeIntervalSince1970: 0)
        let images = (0..<300).map { FoundItem(path: "/Users/a/Pictures/Trip/\($0).jpg", bytes: 2 << 20, modified: old) }
            + [FoundItem(path: "/Users/a/Pictures/Photos Library.photoslibrary/originals/1.heic", bytes: 900 << 20)]
        let f = Clutter.photoFolders(images)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].count, 300)
        XCTAssertEqual(f[0].name, "Trip")
        XCTAssertTrue(Clutter.isStale(f[0].newest, days: 365, at: Date()))
    }

    func testInsights() {
        var found = StorageAnalysis.Found()
        found.places = ["trash": 12 * gb, "derivedData": 6 * gb]
        found.installers = [FoundItem(path: "/d/a.dmg", bytes: 3 * gb)]
        let ids = StorageAnalysis.insights(disk: DiskSpace(total: 500 * gb, free: 6 * gb, available: 8 * gb), points: [], scans: [],
                                           found: found, at: Date()).map(\.id)
        XCTAssertEqual(ids.first, "disk-critical")
        XCTAssertTrue(ids.contains("disk-trash"))
        XCTAssertTrue(ids.contains("disk-installers"))
        XCTAssertTrue(ids.contains("disk-dev"))
    }

    func testStorageInsightsCarryActions() {
        let now = Date()
        let old = now.addingTimeInterval(-200 * 86_400)
        var found = StorageAnalysis.Found()
        found.places = ["trash": 2 * gb, "npm": 4 * gb, "derivedData": 2 * gb]
        found.installers = [FoundItem(path: "/d/a.dmg", bytes: gb), FoundItem(path: "/d/b.pkg", bytes: gb)]
        found.downloads = [FoundItem(path: "/dl/old.zip", bytes: 3 * gb, modified: old),
                           FoundItem(path: "/dl/new.zip", bytes: 3 * gb, modified: now)]
        found.movies = [FoundItem(path: "/m/a.mov", bytes: 3 * gb, modified: old, used: old)]
        let list = StorageAnalysis.insights(disk: DiskSpace(total: 500 * gb, free: 200 * gb, available: 200 * gb), points: [], scans: [],
                                            found: found, at: now)
        func fixes(_ id: String) -> [FixAction] { list.first { $0.id == id }?.fixes ?? [] }
        XCTAssertEqual(fixes("disk-trash"), [.emptyTrash])
        XCTAssertEqual(fixes("disk-installers").first, .trashFound(.installers, count: 2))
        XCTAssertEqual(fixes("disk-olddownloads").first, .trashFound(.oldDownloads, count: 1), "only the old one")
        XCTAssertEqual(fixes("disk-dev").first, .cleanPlaces(keys: ["npm", "derivedData"]), "biggest first")
        XCTAssertEqual(fixes("disk-movies").first, .archiveFound(.oldMovies, count: 1))
        for i in list { XCTAssertFalse(i.fixes.isEmpty, "\(i.id) has no action") }

        // The buttons act on the same files the headline counts.
        XCTAssertEqual(StorageAnalysis.items(.oldDownloads, in: found, at: now).map(\.path), ["/dl/old.zip"])
        XCTAssertEqual(FixAction.trashFound(.installers, count: 2).title, "Move all 2 to the Trash")
        XCTAssertEqual(FixAction.cleanPlaces(keys: ["npm"]).title, "Clean \(StoragePlace.named("npm")!.name)")
        XCTAssertTrue(FixAction.emptyTrash.acts)
        XCTAssertFalse(FixAction.review(card: "downloads", label: "Review").acts)
    }

    func testMovedFilesLeaveTheInsights() {
        let now = Date()
        var found = StorageAnalysis.Found()
        found.installers = [FoundItem(path: "/d/a.dmg", bytes: gb), FoundItem(path: "/d/b.pkg", bytes: gb)]
        found.downloads = [FoundItem(path: "/d/a.dmg", bytes: gb)]
        let disk = DiskSpace(total: 500 * gb, free: 200 * gb, available: 200 * gb)
        XCTAssertTrue(StorageAnalysis.insights(disk: disk, points: [], scans: [], found: found, at: now).contains { $0.id == "disk-installers" })
        var after = StorageAnalysis.removing(["/d/a.dmg", "/d/b.pkg"], from: found)
        XCTAssertTrue(after.installers.isEmpty)
        XCTAssertTrue(after.downloads.isEmpty, "gone from every list")
        after.places["trash", default: 0] += 2 * gb
        let ids = StorageAnalysis.insights(disk: disk, points: [], scans: [], found: after, at: now).map(\.id)
        XCTAssertFalse(ids.contains("disk-installers"))
        XCTAssertTrue(ids.contains("disk-trash"), "the Trash now offers to be emptied")
    }

    func testAlarmWatch() {
        var w = AlarmWatch()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(w.update(over: true, holdFor: 5, at: t0))
        XCTAssertFalse(w.update(over: true, holdFor: 5, at: t0.addingTimeInterval(240)))
        XCTAssertTrue(w.update(over: true, holdFor: 5, at: t0.addingTimeInterval(300)))
        XCTAssertFalse(w.update(over: true, holdFor: 5, at: t0.addingTimeInterval(4000)), "stays quiet while still over")
        XCTAssertFalse(w.update(over: false, holdFor: 5, at: t0.addingTimeInterval(4100)))
        XCTAssertFalse(w.update(over: true, holdFor: 0, at: t0.addingTimeInterval(1000 + 300)) && false)
        var v = AlarmWatch()
        XCTAssertTrue(v.update(over: true, holdFor: 0, at: t0))
        XCTAssertFalse(v.update(over: false, holdFor: 0, at: t0.addingTimeInterval(60)))
        XCTAssertFalse(v.update(over: true, holdFor: 0, at: t0.addingTimeInterval(120)), "within the quiet hour")
        XCTAssertFalse(v.update(over: false, holdFor: 0, at: t0.addingTimeInterval(3000)))
        XCTAssertTrue(v.update(over: true, holdFor: 0, at: t0.addingTimeInterval(3700)))
    }

    func testGuardedFoldersAreLeftAloneWithoutFullAccess() {
        let g = FolderTree.guarded(fullAccess: false)
        for f in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library/Containers"] {
            XCTAssertTrue(g.contains(f), f)
        }
        XCTAssertTrue(FolderTree.guarded(fullAccess: true).isEmpty)

        let home = "/Users/me"
        XCTAssertTrue(FolderTree.isInside("/Users/me/Downloads/a.dmg", g, home: home))
        XCTAssertTrue(FolderTree.isInside("/Users/me/Music", g, home: home))
        XCTAssertTrue(FolderTree.isInside("/Users/me/Library/Containers/x/big", g, home: home))
        XCTAssertFalse(FolderTree.isInside("/Users/me/DownloadsOld/a.dmg", g, home: home), "only the folder itself")
        XCTAssertFalse(FolderTree.isInside("/Users/me/dev/node_modules", g, home: home))
        XCTAssertFalse(FolderTree.isInside("/Applications/Music.app", g, home: home))
        XCTAssertFalse(FolderTree.isInside("/Users/me/Downloads/a.dmg", [], home: home))
    }
}
