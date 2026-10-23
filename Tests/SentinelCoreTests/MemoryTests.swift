import XCTest
@testable import SentinelCore

private let GB: UInt64 = 1 << 30
private let MB: UInt64 = 1 << 20

private func status(swap: UInt64, pressure: MemoryStatus.Pressure = .normal, used: UInt64 = 12 * GB) -> MemoryStatus {
    MemoryStatus(pressure: pressure, total: 24 * GB, used: used, compressed: 2 * GB, swapUsed: swap, swapTotal: swap + GB)
}

/// One point a minute ending at `end`, from `make(i)` with i = 0 oldest.
private func timeline(_ n: Int, end: Date, _ make: (Int) -> MemoryHistory.Point) -> [MemoryHistory.Point] {
    let last = Int(end.timeIntervalSince1970) / 60 * 60
    return (0..<n).map { i in
        var p = make(i)
        p.t = last - (n - 1 - i) * 60
        return p
    }
}

private func point(swap: UInt64 = 0, pressure: Int = 0, swapIn: Double = 0, apps: [MemoryHistory.App] = []) -> MemoryHistory.Point {
    MemoryHistory.Point(t: 0, used: 12 * GB, compressed: 2 * GB, swap: swap, pressure: pressure, swapIn: swapIn, apps: apps)
}

final class MemoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecordsMinutesAndSwapRates() {
        let h = MemoryHistory(fileURL: nil)
        var m = status(swap: GB)
        m.swapIns = 100 * MB
        m.swapOuts = 50 * MB
        h.record(m, apps: [], at: now)
        m.swapIns = 150 * MB          // 50 MB in 10 s
        m.swapOuts = 50 * MB
        m.pressure = .warning
        h.record(m, apps: [.init(key: "a", name: "A", bytes: GB)], at: now.addingTimeInterval(10))
        let minuteStart = Int(now.timeIntervalSince1970) / 60 * 60
        let sameMinute = Int(now.timeIntervalSince1970 + 10) / 60 * 60 == minuteStart
        if sameMinute {
            XCTAssertEqual(h.points.count, 1)
            XCTAssertEqual(h.points[0].swapIn, 2.5 * Double(MB), accuracy: 1)   // average of 0 and 5 MB/s
            XCTAssertEqual(h.points[0].pressure, MemoryStatus.Pressure.warning.rawValue)
            XCTAssertEqual(h.points[0].apps.first?.name, "A")
        } else {
            XCTAssertEqual(h.points.count, 2)
            XCTAssertEqual(h.points[1].swapIn, 5 * Double(MB), accuracy: 1)
        }
    }

    func testSummaryFindsWhenSwapStarted() {
        let pts = timeline(60, end: now) { i in point(swap: i < 40 ? 100 * MB : 3 * GB, pressure: i >= 50 ? 1 : 0) }
        let s = MemoryAnalysis.summary(pts)
        XCTAssertEqual(s.swapSince, pts[40].date)
        XCTAssertFalse(s.swapBeforeRecords)
        XCTAssertEqual(s.peakSwap, 3 * GB)
        XCTAssertEqual(s.warningMinutes, 10)
        let all = MemoryAnalysis.summary(timeline(5, end: now) { _ in point(swap: 2 * GB) })
        XCTAssertNil(all.swapSince)
        XCTAssertTrue(all.swapBeforeRecords)
    }

    func testThrashing() {
        let pts = timeline(10, end: now) { _ in point(swap: 6 * GB, pressure: 2, swapIn: 20 * Double(MB)) }
        let ids = MemoryAnalysis.insights(points: pts, current: status(swap: 6 * GB, pressure: .warning), uptime: nil, at: now).map(\.id)
        XCTAssertTrue(ids.contains("mem-thrash"))
    }

    func testSwapGrowth() {
        let pts = timeline(70, end: now) { i in point(swap: UInt64(i) * 100 * MB) }
        let i = MemoryAnalysis.insights(points: pts, current: status(swap: 7 * GB), uptime: nil, at: now)
        XCTAssertTrue(i.contains { $0.id == "mem-swapgrow" })
    }

    func testSwapOwnerNamesWhoHoldsMemoryOutsideRAM() {
        let pts = timeline(40, end: now) { _ in point(swap: 6 * GB) }
        let apps = [MemoryHistory.App(key: "chrome", name: "Google Chrome", bytes: 5 * GB, outOfRAM: 2 * GB),
                    MemoryHistory.App(key: "vm", name: "Virtual machine", bytes: 6 * GB, outOfRAM: 6 * GB - 400 << 20),
                    MemoryHistory.App(key: "notes", name: "Notes", bytes: GB / 4, outOfRAM: 0)]
        let i = MemoryAnalysis.insights(points: pts, current: status(swap: 6 * GB), uptime: nil, apps: apps, at: now)
        let owner = i.first { $0.id == "mem-swapowner" }
        XCTAssertEqual(owner?.title.hasPrefix("Virtual machine holds"), true)
        XCTAssertEqual(owner?.tone, .info)
        XCTAssertEqual(owner?.detail.contains("Google Chrome"), true)
        XCTAssertEqual(owner?.detail.contains("Notes"), false)
        // Idle swap still gets its reassurance: the owner note is only info.
        XCTAssertTrue(i.contains { $0.id == "mem-swapidle" })
        // Small amounts outside RAM are not worth a note.
        let small = apps.map { MemoryHistory.App(key: $0.key, name: $0.name, bytes: $0.bytes, outOfRAM: 200 << 20) }
        XCTAssertFalse(MemoryAnalysis.insights(points: pts, current: status(swap: 6 * GB), uptime: nil, apps: small, at: now).contains { $0.id == "mem-swapowner" })
    }

    func testIdleSwapIsReassuringAndMentionsRestart() {
        let pts = timeline(40, end: now) { _ in point(swap: 6 * GB) }
        let i = MemoryAnalysis.insights(points: pts, current: status(swap: 6 * GB), uptime: 9 * 86_400, at: now)
        XCTAssertEqual(i.map(\.id), ["mem-swapidle"])
        XCTAssertEqual(i[0].tone, .info)
        XCTAssertTrue(i[0].detail.contains("9 days"))
    }

    func testGrowingAppIsFoundButASpikeIsNot() {
        let leak = timeline(120, end: now) { i in
            point(apps: [.init(key: "/Applications/Leaky.app", name: "Leaky", bytes: GB + UInt64(i) * 30 * MB),
                         .init(key: "/Applications/Spiky.app", name: "Spiky", bytes: i > 50 && i < 60 ? 8 * GB : GB)])
        }
        let g = MemoryAnalysis.growing(leak, at: now)
        XCTAssertEqual(g.map(\.name), ["Leaky"])
        XCTAssertGreaterThan(g[0].to, g[0].from + 3 * GB)
    }

    func testAQuitAppIsNoLongerGrowing() {
        let quit = timeline(120, end: now) { i in
            point(apps: i < 110 ? [.init(key: "vm", name: "Virtual machine (Rancher Desktop)", bytes: GB + UInt64(i) * 30 * MB)] : [])
        }
        XCTAssertTrue(MemoryAnalysis.growing(quit, at: now).isEmpty)
    }

    func testPressureOverTheDayNamesTheUsualSuspect() {
        let pts = timeline(90, end: now) { i in
            point(pressure: i < 45 ? 2 : 1, apps: [.init(key: "c", name: "Chrome", bytes: 8 * GB)])
        }
        let i = MemoryAnalysis.insights(points: pts, current: status(swap: 0), uptime: nil, at: now)
        let p = i.first { $0.id == "mem-pressure24" }
        XCTAssertNotNil(p)
        XCTAssertTrue(p?.detail.contains("Chrome") ?? false)
    }

    func testHealthy() {
        let pts = timeline(30, end: now) { _ in point() }
        XCTAssertEqual(MemoryAnalysis.insights(points: pts, current: status(swap: 0), uptime: 86_400, at: now).map(\.id), ["mem-ok"])
    }

    func testReadsThisMac() {
        let m = MemoryStatus.read()
        XCTAssertNotNil(m)
        XCTAssertGreaterThan(m?.app ?? 0, 0)
        XCTAssertNotNil(MemoryStatus.uptime())
        XCTAssertNotNil(MemoryStatus.footprint(getpid()))
    }
}

final class ClusterTimeTests: XCTestCase {
    func testUsageSplitsEfficiencyAndPerformance() {
        let a = ClusterTime(total: 1_000_000_000, performance: 400_000_000)
        let b = ClusterTime(total: 3_000_000_000, performance: 900_000_000)
        let u = ClusterTime.usage(from: a, to: b, seconds: 10)
        XCTAssertEqual(u?.efficiency ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(u?.performance ?? 0, 5, accuracy: 0.001)
        // A reused pid (counters went backwards) gives nothing rather than nonsense.
        XCTAssertNil(ClusterTime.usage(from: b, to: a, seconds: 10))
        XCTAssertTrue(ClusterTime.read(getpid()) != nil)
    }
}

final class RetentionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDaysFallBackToAWeek() {
        XCTAssertEqual(HistoryRetention.days(14), 14)
        XCTAssertEqual(HistoryRetention.days(0), 7)
        XCTAssertEqual(HistoryRetention.days(30), 7)
        XCTAssertEqual(HistoryRetention.megabytes(days: 7), 11)
        XCTAssertLessThan(HistoryRetention.megabytes(days: 28), 40)
    }

    func testMemoryKeepsAppsHourlyPastAWeek() {
        let h = MemoryHistory(fileURL: nil, retain: 28 * 86_400)
        let app = MemoryHistory.App(key: "a", name: "A", bytes: GB)
        // Two days ago is still full detail; ten days ago is thinned.
        for days in [10.0, 2.0] {
            for m in 0..<120 { h.record(status(swap: 0), apps: [app], at: now.addingTimeInterval(-days * 86_400 + Double(m) * 60)) }
        }
        h.record(status(swap: 0), apps: [app], at: now)
        let cut = Int(now.timeIntervalSince1970 - 7 * 86_400)
        let old = h.points.filter { $0.t < cut }, recent = h.points.filter { $0.t >= cut }
        XCTAssertEqual(old.count, 120, "every minute's totals stay")
        XCTAssertLessThanOrEqual(old.filter { !$0.apps.isEmpty }.count, 3, "the app list once an hour")
        XCTAssertTrue(recent.allSatisfy { !$0.apps.isEmpty })
    }

    func testShorterRetentionTrims() {
        let h = MemoryHistory(fileURL: nil, retain: 28 * 86_400)
        h.record(status(swap: 0), apps: [], at: now.addingTimeInterval(-20 * 86_400))
        h.record(status(swap: 0), apps: [], at: now.addingTimeInterval(-60))
        h.retain = 7 * 86_400
        h.record(status(swap: 0), apps: [], at: now)
        XCTAssertEqual(h.points.count, 2)

        let u = DailyUsage(fileURL: nil, retainHours: 28 * 24)
        let s = ProcessSample(pid: 1, uid: 501, cpu: 50, path: "/bin/a")
        u.record([s], at: now.addingTimeInterval(-20 * 86_400))
        u.record([s], at: now.addingTimeInterval(-20 * 86_400 + 5))
        XCTAssertEqual(u.sampled(at: now, hours: 28 * 24), 5)
        u.retainHours = 7 * 24
        u.record([s], at: now)
        XCTAssertEqual(u.sampled(at: now, hours: 28 * 24), 15, "only the new tick is left")

        var d = DNSHistory()
        d.record(ok: true, ms: 10, at: now.addingTimeInterval(-3 * 86_400))
        d.record(ok: false, ms: nil, at: now)
        XCTAssertEqual(d.failures(since: now.addingTimeInterval(-7 * 86_400)), 1)
        XCTAssertEqual(d.points.count, 2, "a week by default")
        d.record(ok: true, ms: 10, at: now, keep: 86_400)
        XCTAssertEqual(d.points.count, 2)
    }
}

final class MemoryRuleTests: XCTestCase {
    private let rules = ["rancher": MemoryRule(name: "Rancher Desktop", limit: 4 << 30)]
    private func r(_ gb: UInt64, front: Bool = false) -> [MemoryRuleWatch.Reading] {
        [.init(key: "rancher", bytes: gb << 30, frontmost: front)]
    }

    func testFiresOnlyAfterStayingOverForTheWindow() {
        let w = MemoryRuleWatch(window: 300, cooldown: 1800)
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(w.update(r(5), rules: rules, at: t), [])
        XCTAssertEqual(w.update(r(5), rules: rules, at: t + 200), [])
        XCTAssertEqual(w.update(r(5), rules: rules, at: t + 300), ["rancher"])
    }

    func testDippingUnderOrBeingInFrontResets() {
        let w = MemoryRuleWatch(window: 300, cooldown: 1800)
        let t = Date(timeIntervalSince1970: 1_000_000)
        _ = w.update(r(5), rules: rules, at: t)
        _ = w.update(r(3), rules: rules, at: t + 100)
        XCTAssertEqual(w.update(r(5), rules: rules, at: t + 300), [])
        _ = w.update(r(5, front: true), rules: rules, at: t + 400)
        XCTAssertEqual(w.update(r(5), rules: rules, at: t + 650), [])
        XCTAssertEqual(w.update(r(5), rules: rules, at: t + 950), ["rancher"])
    }

    func testCooldownStopsAQuitLoop() {
        let w = MemoryRuleWatch(window: 300, cooldown: 1800)
        let t = Date(timeIntervalSince1970: 1_000_000)
        _ = w.update(r(5), rules: rules, at: t)
        XCTAssertEqual(w.update(r(5), rules: rules, at: t + 300), ["rancher"])
        _ = w.update(r(5), rules: rules, at: t + 400)
        XCTAssertEqual(w.update(r(5), rules: rules, at: t + 800), [])
        XCTAssertEqual(w.update(r(5), rules: rules, at: t + 2200), ["rancher"])
    }

    func testNoRuleNeverFires() {
        let w = MemoryRuleWatch(window: 0)
        XCTAssertEqual(w.update([.init(key: "chrome", bytes: 99 << 30, frontmost: false)], rules: rules, at: Date()), [])
    }

    func testRulesPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("memrules-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        MemoryRuleStore(fileURL: url).set(MemoryRule(name: "Rancher Desktop", limit: 8 << 30), for: "rancher")
        XCTAssertEqual(MemoryRuleStore(fileURL: url).rules["rancher"]?.limit, 8 << 30)
        XCTAssertEqual(MemoryRule(name: "x", limit: 8 << 30).label, "auto-quit over 8 GB")
    }

    func testMovedNamesAppsThatWentOutOfRAM() {
        func p(_ t: Int, _ vm: UInt64, _ chrome: UInt64?) -> MemoryHistory.Point {
            var apps = [MemoryHistory.App(key: "vm", name: "VM", bytes: 4 << 30, outOfRAM: vm)]
            if let chrome { apps.append(.init(key: "chrome", name: "Chrome", bytes: 3 << 30, outOfRAM: chrome)) }
            return MemoryHistory.Point(t: t, used: 0, compressed: 0, swap: 0, pressure: 1, apps: apps)
        }
        let points = [p(0, 1 << 30, 500 << 20), p(60, 2 << 30, 100 << 20), p(120, 3 << 30, nil)]
        let m = MemoryAnalysis.moved(points, from: 60, to: 120)
        XCTAssertEqual(m.map(\.key), ["vm", "chrome"])
        XCTAssertEqual(m[0].delta, 1 << 30)
        XCTAssertEqual(m[1].delta, -(400 << 20))
        // Chrome is missing from the later reading: unknown, not reported.
        XCTAssertEqual(MemoryAnalysis.moved(points, from: 60, to: 180).map(\.key), ["vm"])
    }
}
