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
