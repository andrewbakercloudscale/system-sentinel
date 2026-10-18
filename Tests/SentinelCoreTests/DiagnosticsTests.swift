import XCTest
@testable import SentinelCore

final class DiagnosticsTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        Diagnostics.log = nil
    }

    func testRecordAndFoldRepeats() {
        let log = ErrorLog(fileURL: nil)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        log.record("save", "disk full", at: t0)
        log.record("checkup", "softwareupdate timed out", at: t0.addingTimeInterval(10))
        log.record("save", "disk full", at: t0.addingTimeInterval(20))
        let s = log.summary()
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.first?.message, "disk full", "most recent first")
        XCTAssertEqual(s.first?.count, 2)
        XCTAssertEqual(s.first?.first, t0)
        XCTAssertEqual(s.first?.last, t0.addingTimeInterval(20))
        XCTAssertEqual(log.summary(since: t0.addingTimeInterval(15)).map(\.count), [1], "only the last week, say")
    }

    func testPersistsAcrossLaunches() {
        let url = dir.appendingPathComponent("errors.log")
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        ErrorLog(fileURL: url).record("update", "gh not found", at: t)
        let again = ErrorLog(fileURL: url)
        XCTAssertEqual(again.all, [ErrorLog.Entry(date: t, area: "update", message: "gh not found")])
    }

    func testRotatesBeforeTheLimit() throws {
        let url = dir.appendingPathComponent("errors.log")
        let log = ErrorLog(fileURL: url, maxBytes: 1000)
        for i in 0..<60 { log.record("save", "failure number \(i)") }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 1000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path), "the older file is kept")
        // Reading back takes both files, newest last, and nothing older than one rotation.
        let back = ErrorLog(fileURL: url).all
        XCTAssertEqual(back.last?.message, "failure number 59")
        XCTAssertLessThan(back.count, 60)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1.1").path))
    }

    func testIgnoresDamagedLines() throws {
        let url = dir.appendingPathComponent("errors.log")
        ErrorLog(fileURL: url).record("save", "ok line")
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data("{not json\n".utf8))
        try h.close()
        XCTAssertEqual(ErrorLog(fileURL: url).all.map(\.message), ["ok line"])
    }

    func testWriteReportsFailures() {
        let log = ErrorLog(fileURL: nil)
        Diagnostics.log = log
        let good = dir.appendingPathComponent("a/b.json")
        XCTAssertTrue(Diagnostics.write(Data("{}".utf8), to: good, what: "test file"))
        XCTAssertTrue(log.all.isEmpty)
        // A path under a file cannot be written.
        let bad = good.appendingPathComponent("under-a-file.json")
        XCTAssertFalse(Diagnostics.write(Data("{}".utf8), to: bad, what: "memory history"))
        XCTAssertEqual(log.all.first?.area, "save")
        XCTAssertTrue(log.all.first?.message.hasPrefix("Could not save memory history") ?? false)
    }

    func testStaleJobs() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var h = TaskHealth(started: t0)
        // Just launched: nothing is late yet.
        XCTAssertEqual(h.stale(at: t0.addingTimeInterval(30)), [])
        h.ran(.sampling, at: t0.addingTimeInterval(5))
        h.ran(.energy, at: t0.addingTimeInterval(15))
        // Sampling every 5 s: late after 3 intervals plus a minute.
        XCTAssertFalse(h.stale(at: t0.addingTimeInterval(5 + 70)).contains(.sampling))
        XCTAssertTrue(h.stale(at: t0.addingTimeInterval(5 + 80)).contains(.sampling))
        // Six-hourly jobs never run count from launch, with half an hour of grace.
        XCTAssertFalse(h.stale(at: t0.addingTimeInterval(18 * 3600)).contains(.checkup))
        XCTAssertTrue(h.stale(at: t0.addingTimeInterval(19 * 3600)).contains(.checkup))
        // A job that is off is never late.
        XCTAssertFalse(h.stale(at: t0.addingTimeInterval(30 * 3600), skip: [.updateCheck]).contains(.updateCheck))
    }

    func testCrashMarker() throws {
        let marker = CrashMarker(fileURL: dir.appendingPathComponent("running"))
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(marker.launch(at: t0), "first launch")
        marker.cleanExit()
        XCTAssertNil(marker.launch(at: t0.addingTimeInterval(100)), "after a normal quit")
        // No quit this time: the next launch finds the marker with the last start time.
        let unclean = try XCTUnwrap(marker.launch(at: t0.addingTimeInterval(200)))
        XCTAssertEqual(unclean.timeIntervalSince1970, t0.addingTimeInterval(100).timeIntervalSince1970, accuracy: 0.01)
    }

    func testCrashReportMustBeNewerThanTheRun() throws {
        let reports = dir.appendingPathComponent("DiagnosticReports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let started = Date().addingTimeInterval(-3600)
        func make(_ name: String, at date: Date) throws {
            let url = reports.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try make("SystemSentinel-2026-01-01-000000.ips", at: started.addingTimeInterval(-86_400))
        try make("OtherApp-2026-01-02-000000.ips", at: started.addingTimeInterval(60))
        // Only old reports and other apps': a force quit or power cut, not a crash.
        XCTAssertNil(CrashMarker.report(for: "SystemSentinel", after: started, in: reports))
        try make("SystemSentinel-2026-01-02-000100.ips", at: started.addingTimeInterval(120))
        try make("SystemSentinel-2026-01-02-000200.ips", at: started.addingTimeInterval(300))
        XCTAssertEqual(CrashMarker.report(for: "SystemSentinel", after: started, in: reports)?.lastPathComponent,
                       "SystemSentinel-2026-01-02-000200.ips", "the newest")
        XCTAssertNil(CrashMarker.report(for: "SystemSentinel", after: started, in: dir.appendingPathComponent("missing")))
    }
}
