import XCTest
@testable import SentinelCore

private func ps(_ pid: Int32, _ cpu: Double, _ path: String = "/usr/bin/yes", rss: Int = 0) -> ProcessSample {
    ProcessSample(pid: pid, uid: getuid(), cpu: cpu, path: path, rssKB: rss)
}

private func input(_ samples: [ProcessSample] = []) -> InsightInput {
    InsightInput(cores: 10, samples: samples, total1m: 50, total15m: 50, total60m: 50, avg15m: [:], recordedMinutes: 60,
                 daily: [], dailySampled: 0, totalHourly: [], hourStarts: [], events: [], thermal: 0, lowPower: false)
}

private let day: TimeInterval = 86_400

final class SystemReaderTests: XCTestCase {
    func testMemoryPressureLevelsAndLiveRead() {
        XCTAssertEqual(MemoryStatus.Pressure(level: 1), .normal)
        XCTAssertEqual(MemoryStatus.Pressure(level: 2), .warning)
        XCTAssertEqual(MemoryStatus.Pressure(level: 4), .critical)
        let m = MemoryStatus.read()
        XCTAssertNotNil(m)
        XCTAssertEqual(m!.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(m!.used, 0)
        XCTAssertLessThanOrEqual(m!.used, m!.total)
    }

    func testGPUFromRegistry() {
        XCTAssertEqual(GPUReader.parse(["PerformanceStatistics": ["Device Utilization %": 37, "Renderer Utilization %": 0]]), 37)
        XCTAssertNil(GPUReader.parse(["Other": 1]))
        if let live = GPUReader.utilization() { XCTAssert((0...100).contains(live)) }
    }

    func testGPUStatusAndClients() {
        let s = GPUReader.status(["model": "Apple M4", "gpu-core-count": 10,
                                  "PerformanceStatistics": ["Device Utilization %": 12, "In use system memory": 31_555_584, "Alloc system memory": 3_220_963_328]])
        XCTAssertEqual(s?.name, "Apple M4")
        XCTAssertEqual(s?.cores, 10)
        XCTAssertEqual(s?.busy, 12)
        XCTAssertEqual(s?.memoryInUse, 31_555_584)
        XCTAssertEqual(s?.memoryAllocated, 3_220_963_328)

        let c = GPUReader.client(["IOUserClientCreator": "pid 395, WindowServer",
                                  "AppUsage": [["API": "Metal", "accumulatedGPUTime": 1_000], ["API": "Metal", "accumulatedGPUTime": 500]]])
        XCTAssertEqual(c?.pid, 395)
        XCTAssertEqual(c?.name, "WindowServer")
        XCTAssertEqual(c?.time, 1_500)
        XCTAssertEqual(GPUReader.client(["IOUserClientCreator": "pid 7, idle", "AppUsage": []])?.time, 0)
        XCTAssertNil(GPUReader.client(["IOUserClientCreator": "kernel"]))

        // 0.5 s of graphics time over 5 s is 10%; new and idle processes are left out.
        let shares = GPUReader.shares(from: [1: 0, 2: 100, 3: 9], to: [1: 500_000_000, 2: 100, 4: 1_000], seconds: 5)
        XCTAssertEqual(shares, [1: 10])
        XCTAssertEqual(GPUReader.shares(from: [1: 0], to: [1: 1], seconds: 0), [:])

        if let live = GPUReader.read() {
            XCTAssert((0...100).contains(live.busy))
            XCTAssertFalse(live.gpuTime.isEmpty, "WindowServer always draws with the graphics chip")
        }
    }

    func testNettopNamesWithDotsAndCommas() {
        let text = """
        ,bytes_in,bytes_out,
        launchd.1,1950949,194400,
        Google Chrome H.1234,5000,600,
        com.apple.Safari.Web.88,10,20,
        odd, name.77,1,2,
        garbage
        """
        let r = IOSampler.parseNettop(text)
        XCTAssertEqual(r[1]?.0, 1950949)
        XCTAssertEqual(r[1234]?.1, 600)
        XCTAssertEqual(r[88]?.0, 10)
        XCTAssertEqual(r[77]?.1, 2)
        XCTAssertEqual(r.count, 4)
    }

    func testIORatesAndGrouping() {
        let t = IOTracker()
        let now = Date()
        XCTAssertTrue(t.update([1: IOCounters(netIn: 100)], at: now).isEmpty, "first reading only sets the clock")
        let r = t.update([1: IOCounters(netIn: 3100, diskWrite: 10), 2: IOCounters(netIn: 5)], at: now.addingTimeInterval(30))
        XCTAssertEqual(r.count, 1, "pid 2 has no earlier reading")
        XCTAssertEqual(r[0].netIn, 100)
        let rows = IORow.group(r + [IORate(pid: 3, netIn: 0, netOut: 0, diskRead: 50, diskWrite: 0)],
                               processes: [ps(1, 0, "/a"), ps(3, 0, "/a")], key: { $0 }, name: { $0 })
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].pids, [1, 3])
        XCTAssertEqual(rows[0].disk, 50 + 10.0 / 30, accuracy: 0.001)
        XCTAssertEqual(IORow.rate(1_500_000), "1.5 MB/s")
        XCTAssertEqual(IORow.rate(0), "–")
        XCTAssertNotNil(IOSampler.disk(getpid()), "own process readable")
        XCTAssertFalse(IOSampler.network().isEmpty, "nettop sees something")
    }

    // Lines recorded from pmset -g log on an M4 MacBook Pro.
    let log = """
    2026-10-14 23:00:00 +0200 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:90%) 45 secs
    2026-10-15 01:10:00 +0200 DarkWake            \tDarkWake from Deep Idle [CDN] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance Using BATT (Charge:88%) 30 secs
    2026-10-15 03:10:00 +0200 DarkWake            \tDarkWake from Deep Idle [CDN] : due to wifibt/ Using BATT (Charge:86%) 30 secs
    2026-10-15 04:10:00 +0200 DarkWake            \tDarkWake from Deep Idle [CDN] : due to NUB.SPMI0.SW3 rtc/Maintenance Using BATT (Charge:85%) 30 secs
    2026-10-15 05:00:00 +0200 Wake Requests       \t[*process=powerd request=CSPNEvaluation]
    2026-10-15 07:00:00 +0200 Wake                \tWake from Deep Idle [CDNVA] : due to lid/User Using BATT (Charge:82%)
    2026-10-15 12:00:00 +0200 Sleep               \tEntering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using AC (Charge:100%) 45 secs
    2026-10-15 13:00:00 +0200 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC (Charge:100%)
    """

    func testSleepLogParseAndReport() {
        let e = SleepLog.parse(log)
        XCTAssertEqual(e.count, 7, "Wake Requests is not a wake")
        XCTAssertEqual(e[0].kind, .sleep)
        XCTAssertEqual(e[0].reason, "Clamshell Sleep")
        XCTAssertEqual(e[0].cause, "lid closed")
        XCTAssertEqual(e[0].charge, 90)
        XCTAssertTrue(e[0].onBattery)
        XCTAssertEqual(e[1].cause, "scheduled maintenance")
        XCTAssertEqual(e[2].cause, "network")
        XCTAssertEqual(e[4].cause, "lid opened")
        XCTAssertFalse(e[5].onBattery)
        XCTAssertEqual(e[6].cause, "you")

        let r = SleepLog.report(e, until: e.last!.date)
        XCTAssertEqual(r.sleeps, 2)
        XCTAssertEqual(r.asleep, 9 * 3600)
        XCTAssertEqual(r.darkWakes, 3)
        XCTAssertEqual(r.wakeCauses.first?.cause, "scheduled maintenance")
        XCTAssertEqual(r.wakeCauses.first?.count, 2)
        XCTAssertEqual(r.chargeLost, 8, "90% to 82% on battery; the AC sleep does not count")
        XCTAssertEqual(r.lossPerHour!, 1, accuracy: 0.001)

        let since = SleepLog.parse(log, since: e[5].date)
        XCTAssertEqual(since.count, 2)
        XCTAssertFalse(SleepLog.read().isEmpty)
    }

    func testSleepDrainInsight() {
        var i = input()
        i.sleep = SleepReport(asleep: 8 * 3600, sleeps: 1, darkWakes: 30, wakeCauses: [("network", 20)], chargeLost: 24, batteryAsleep: 8 * 3600)
        let x = Insights.generate(i).first { $0.id == "sleepdrain" }
        XCTAssertEqual(x?.title, "Lost 3.0% an hour while asleep")
        XCTAssertEqual(x?.fixes, [.openSettings(.battery)])
        i.sleep = SleepReport(asleep: 8 * 3600, sleeps: 1, darkWakes: 50, wakeCauses: [("network", 20)], chargeLost: 2, batteryAsleep: 8 * 3600)
        XCTAssertEqual(Insights.generate(i).first { $0.id == "darkwakes" }?.detail, "Over the last 24 hours, with the screen off. Mostly: network.")
    }
}

final class HealthAndChargeTests: XCTestCase {
    func testHealthLogOnePerDayAndProjection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = Calendar(identifier: .gregorian)
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let log = HealthLog(fileURL: url)
        // 0.1 point of health lost per day, from 95%.
        for d in 0..<30 {
            let maxCap = Int((95 - 0.1 * Double(d)) * 50)
            log.record(BatteryStatus(cycleCount: 100 + d, maxCapacity: maxCap, designCapacity: 5000), at: start.addingTimeInterval(Double(d) * day + 3600), calendar: cal)
            log.record(BatteryStatus(cycleCount: 100 + d, maxCapacity: maxCap, designCapacity: 5000), at: start.addingTimeInterval(Double(d) * day + 7200), calendar: cal)
        }
        XCTAssertEqual(log.entries.count, 30, "one per day")
        XCTAssertEqual(HealthLog(fileURL: url).entries.count, 30, "persisted")
        let p = try XCTUnwrap(HealthLog.projection(log.entries))
        // 95 to 80 at 0.1 a day is 150 days.
        XCTAssertEqual(p.timeIntervalSince(start) / day, 150, accuracy: 0.5)
        XCTAssertEqual(HealthLog.cyclesPerWeek(log.entries, at: start.addingTimeInterval(29 * day))!, 7, accuracy: 0.01)
        XCTAssertNil(HealthLog.projection(Array(log.entries.prefix(10))), "under two weeks")
        let flat = (0..<20).map { HealthLog.Entry(day: Int(start.timeIntervalSince1970) + $0 * 86_400, maxCapacity: 4500, designCapacity: 5000, cycles: 1) }
        XCTAssertNil(HealthLog.projection(flat), "not falling")
    }

    func testChargeHabits() {
        let t = 1_800_000_000
        let pts = (0..<1000).map { m in
            PowerHistory.Point(t: t + m * 60, watts: 5, onBattery: m >= 900, percent: m < 200 ? 80 : 100, n: 1)
        }
        let c = ChargeHabits.from(pts)
        XCTAssertEqual(c.pluggedMinutes, 900)
        XCTAssertEqual(c.fullMinutes, 700)
        XCTAssertEqual(c.batteryMinutes, 100)
        XCTAssertTrue(c.sitsAtFull)
        var i = input()
        i.charge = c
        XCTAssertEqual(Insights.generate(i).first { $0.id == "charge" }?.title, "Plugged in at 100% for 77% of the time")
        XCTAssertFalse(ChargeHabits.from(Array(pts.prefix(300))).sitsAtFull, "too little time to judge")
    }
}

final class FixAndRuleTests: XCTestCase {
    func testFixesAttachToInsights() {
        let now = Date()
        var i = input([ps(61741, 0, "/usr/bin/caffeinate"), ps(61742, 0, "/usr/bin/caffeinate"), ps(1, 0, "/sbin/launchd")])
        i.blockers = [61741, 61742].map {
            SleepBlocker(pid: $0, name: "caffeinate", kind: .system, reason: "", since: now.addingTimeInterval(-7200), onBehalfOf: "claude", onBehalfOfPID: 9)
        }
        i.battery = BatteryStatus(onBattery: true, percent: 10, maxCapacity: 3000, designCapacity: 5000, condition: "Check Battery")
        let all = Insights.generate(i, at: now)
        XCTAssertEqual(all.first { $0.id == "blockers" }?.fixes, [.kill(pids: [61741, 61742], label: "Let the Mac sleep (stop 2 caffeinate)")])
        XCTAssertEqual(all.first { $0.id == "lpm" }?.fixes, [.lowPowerMode, .openSettings(.battery)])
        XCTAssertEqual(all.first { $0.id == "health" }?.fixes, [.openSettings(.battery)])

        var w = input([ps(2, 60, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")])
        w.samples[0] = ProcessSample(pid: 2, uid: 88, cpu: 60, path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
        XCTAssertEqual(Insights.generate(w).first { $0.id == "ws" }?.fixes, [.optimiseScreen, .openSettings(.accessibilityDisplay), .openSettings(.displays)])

        var h = input([ps(5, 120, "/Applications/Slack.app/Contents/MacOS/Slack")])
        h.avg15m = [5: 110]
        let hog = Insights.generate(h).first { $0.id == "hog-5" }
        XCTAssertEqual(hog?.fixes, [.quit(pids: [5], name: "Slack")])
        XCTAssertTrue(FixAction.quit(pids: [5], name: "Slack").acts)
        XCTAssertFalse(FixAction.openSettings(.battery).acts)
        XCTAssertTrue(FixAction.Settings.battery.url.hasPrefix("x-apple.systempreferences:"))
    }

    func testConditionalRules() {
        let cal = Calendar(identifier: .gregorian)
        let ten = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 10))!
        let night = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 23))!
        let work = Policy.ignoreDuring(from: 9, to: 17)
        XCTAssertEqual(work.resolved(at: ten, onBattery: false, percent: nil, calendar: cal), .ignore(until: nil))
        XCTAssertEqual(work.resolved(at: night, onBattery: false, percent: nil, calendar: cal), .alert)
        let overnight = Policy.ignoreDuring(from: 22, to: 6)
        XCTAssertEqual(overnight.resolved(at: night, onBattery: false, percent: nil, calendar: cal), .ignore(until: nil))
        XCTAssertEqual(overnight.resolved(at: ten, onBattery: false, percent: nil, calendar: cal), .alert)
        let low = Policy.autoKillBelow(percent: 30)
        XCTAssertEqual(low.resolved(at: ten, onBattery: true, percent: 20), .autoKill)
        XCTAssertEqual(low.resolved(at: ten, onBattery: true, percent: 50), .alert)
        XCTAssertEqual(low.resolved(at: ten, onBattery: false, percent: 20), .alert)
        XCTAssertEqual(work.label, "ignored 09:00–17:00")
        XCTAssertEqual(low.label, "auto-kill under 30% battery")
        XCTAssertTrue(low.killsSometimes)
        XCTAssertFalse(work.killsSometimes)
    }

    func testAutoKillBelowThroughTheEngine() throws {
        var killed: [Int32] = []
        let store = PolicyStore(fileURL: nil)
        store.set(.autoKillBelow(percent: 30), for: "/usr/bin/yes")
        var percent = 50
        let make = { () -> Sentinel in
            let s = Sentinel(detector: Detector(threshold: 80, window: 10), policies: store, history: History(fileURL: nil),
                             sampler: { [ps(7, 99)] }, killer: { killed.append($0.pid); return .terminated })
            s.onBattery = { true }
            s.batteryPercent = { percent }
            return s
        }
        let t0 = Date()
        var s = make()
        try s.tick(at: t0)
        XCTAssertEqual(try s.tick(at: t0.addingTimeInterval(11)), [.alert(ps(7, 99))])
        percent = 20
        s = make()
        try s.tick(at: t0)
        try s.tick(at: t0.addingTimeInterval(11))
        XCTAssertEqual(killed, [7])
        let data = try JSONEncoder().encode([Policy.ignoreDuring(from: 9, to: 17), .autoKillBelow(percent: 30)])
        XCTAssertEqual(try JSONDecoder().decode([Policy].self, from: data), [.ignoreDuring(from: 9, to: 17), .autoKillBelow(percent: 30)])
    }

    func testOverdueBlockersReportedOnce() {
        let now = Date()
        let old = SleepBlocker(pid: 1, name: "caffeinate", kind: .system, reason: "", since: now.addingTimeInterval(-3 * 3600))
        let fresh = SleepBlocker(pid: 2, name: "Music", kind: .system, reason: "", since: now.addingTimeInterval(-60))
        let due = SleepBlockers.overdue([old, fresh], reported: [], threshold: 7200, at: now)
        XCTAssertEqual(due.map(\.pid), [1])
        XCTAssertTrue(SleepBlockers.overdue([old], reported: [SleepBlockers.reportKey(old)], threshold: 7200, at: now).isEmpty)
    }
}

final class UsageAdviceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnusualAgainstItsOwnHistory() {
        let u = DailyUsage(fileURL: nil, maxStep: 3600)
        let first = now.addingTimeInterval(-12 * 3600)
        u.record([], at: first)
        for k in 0..<12 {
            let rows = [ps(1, 10, "/Applications/Slack.app/Contents/MacOS/Slack"), ps(2, 50, "/usr/bin/build")]
            u.record(rows, at: first.addingTimeInterval(Double(k) * 3600 + 1800))
            u.record(rows, at: first.addingTimeInterval(Double(k) * 3600 + 3599))
        }
        let typical = u.typicalByGroup(at: now) { AppIdentity.groupKey(of: $0) }
        let slack = AppIdentity.groupKey(of: "/Applications/Slack.app/Contents/MacOS/Slack")
        XCTAssertEqual(typical[slack]!, 10, accuracy: 0.5)
        let found = Unusual.find(current: [slack: ("Slack", 60, [11]), "/usr/bin/build": ("build", 60, [2]), "new": ("New", 90, [3])], typical: typical)
        XCTAssertEqual(found.map(\.name), ["Slack"], "build is at its usual, New has no history")
        XCTAssertEqual(found[0].ratio, 6, accuracy: 0.5)
        XCTAssertTrue(Unusual.find(current: [slack: ("Slack", 60, [1])], typical: [:]).isEmpty)

        var i = input([ps(11, 60, "/Applications/Slack.app/Contents/MacOS/Slack")])
        i.unusual = found
        let x = Insights.generate(i).first { $0.id.hasPrefix("unusual-") }
        XCTAssertEqual(x?.title, "Slack is working 6 times harder than usual")
        XCTAssertEqual(x?.fixes, [.quit(pids: [11], name: "Slack")], "pid 1 would be launchd: never offered")
    }

    func testPartPowerAddsUpByPart() {
        let w = PartPower.watts([
            .init(name: "CPU Energy", unit: "mJ", value: 5000),
            .init(name: "GPU Energy", unit: "nJ", value: 3_000_000_000),
            .init(name: "ANE", unit: "mJ", value: 0),
            .init(name: "DRAM", unit: "mJ", value: 1000),
            .init(name: "DIE_1_CPU Energy", unit: "mJ", value: 5000),
            .init(name: "PCPU0", unit: "mJ", value: 99999),
            .init(name: "DISP", unit: "mJ", value: 500),
            .init(name: "DISPEXT", unit: "mJ", value: 500),
        ], seconds: 5)
        XCTAssertEqual(w.cpu ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(w.gpu ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(w.ane, 0)
        XCTAssertEqual(w.dram ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(w.display ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(w.total, 3.0, accuracy: 0.001)
        XCTAssertNil(PartPower.watts([], seconds: 0).gpu)
    }

    func testScreenLight() {
        // Recorded on an M4 MacBook Pro at about a third brightness.
        let l = ScreenLight.parse(["BrightnessMilliNits": ["min": 8134, "value": 168350, "max": 2140848],
                                   "BrightnessMicroAmps": ["min": 196, "value": 3737, "max": 56476]])!
        XCTAssertEqual(l.nits, 168.35, accuracy: 0.01)
        XCTAssertEqual(l.maxNits, 2140.848, accuracy: 0.01)
        XCTAssertEqual(l.currentShare!, 6.6, accuracy: 0.1)
        XCTAssertNil(ScreenLight.parse(["brightness": ["value": 1, "max": 2]]))
    }

    func testGPUSavings() {
        let ai = GPUApp(key: "/usr/local/bin/ollama", name: "ollama", share: 80, pids: [42], front: false)
        let screen = GPUApp(key: "WindowServer", name: "WindowServer", share: 20, pids: [1], front: false)
        let tiny = GPUApp(key: "x", name: "Tiny", share: 8, pids: [7], front: false)
        let byPID = [Int32(42): ProcessSample(pid: 42, uid: 501, cpu: 1, path: "/usr/local/bin/ollama")]
        let list = GPUSavings.list(apps: [ai, screen, tiny], busy: 85, onBattery: true, lowPower: false, byPID: byPID)
        XCTAssertEqual(list.map(\.title), ["Unload ollama's model when you are done", "Make the screen cheaper to draw", "Turn on Low Power Mode"])
        XCTAssertEqual(list[0].fixes, [.quit(pids: [42], name: "ollama")])
        XCTAssertEqual(list[1].fixes, [.optimiseScreen, .openSettings(.displays)])
        XCTAssertTrue(GPUSavings.list(apps: [tiny], busy: 10, onBattery: true, lowPower: false, byPID: [:]).isEmpty)
    }

    func testGPUInsights() {
        let game = "/Applications/Game.app/Contents/MacOS/Game"
        var i = input([ps(21, 30, game), ps(22, 5, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"),
                       ps(23, 5, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")])
        i.gpuMinutes = 2
        i.gpuApps = [GPUApp(key: game, name: "Game", share: 90, pids: [21], front: false)]
        XCTAssertTrue(Insights.generate(i).filter { $0.id.hasPrefix("gpu-") }.isEmpty, "needs 5 minutes of readings")

        i.gpuMinutes = 5
        var x = Insights.generate(i).first { $0.id.hasPrefix("gpu-") }
        XCTAssertEqual(x?.title, "Game is using the graphics chip in the background")
        XCTAssertEqual(x?.tone, .warning)
        XCTAssertEqual(x?.fixes, [.quit(pids: [21], name: "Game")])

        // In front, a game at 40% is expected; at 90% it is worth knowing, with Low Power Mode on battery.
        i.gpuApps = [GPUApp(key: game, name: "Game", share: 40, pids: [21], front: true)]
        XCTAssertNil(Insights.generate(i).first { $0.id.hasPrefix("gpu-") })
        i.gpuApps = [GPUApp(key: game, name: "Game", share: 90, pids: [21], front: true)]
        i.battery = BatteryStatus(present: true, onBattery: true)
        x = Insights.generate(i).first { $0.id.hasPrefix("gpu-") }
        XCTAssertEqual(x?.title, "Game is using 90% of the graphics chip")
        XCTAssertEqual(x?.tone, .info)
        XCTAssertEqual(x?.fixes, [.quit(pids: [21], name: "Game"), .lowPowerMode])

        // The screen itself: optimise it rather than quit WindowServer.
        i.gpuApps = [GPUApp(key: "WindowServer", name: "WindowServer", share: 70, pids: [22], front: false)]
        x = Insights.generate(i).first { $0.id.hasPrefix("gpu-") }
        XCTAssertEqual(x?.id, "gpu-screen")
        XCTAssertEqual(x?.fixes, [.optimiseScreen, .openSettings(.displays)])

        // A browser in the background: find the tab.
        i.gpuApps = [GPUApp(key: "/Applications/Google Chrome.app", name: "Google Chrome", share: 30, pids: [23], front: false)]
        x = Insights.generate(i).first { $0.id.hasPrefix("gpu-") }
        XCTAssertEqual(x?.symbol, "play.rectangle.fill")
        XCTAssert(x?.steps.first?.contains("Task Manager") ?? false)
        XCTAssertEqual(GPUApp(key: "/Applications/Research.app", name: "Research", share: 0, pids: [], front: false).kind, .other, "'search' is not Arc")
        XCTAssertEqual(GPUApp(key: "/opt/homebrew/bin/ollama", name: "ollama", share: 0, pids: [], front: false).kind, .ai)
    }

    func testMemoryInsightNamesTheHeaviest() {
        var i = input([ps(11, 1, "/Applications/Chrome.app/Contents/MacOS/Chrome", rss: 4_000_000), ps(12, 1, "/usr/bin/small", rss: 1000)])
        i.memory = MemoryStatus(pressure: .warning, total: 16 << 30, used: 15 << 30, compressed: 3 << 30, swapUsed: 5 << 30, swapTotal: 6 << 30)
        let x = Insights.generate(i).first { $0.id == "memory" }
        XCTAssertEqual(x?.title, "Memory is tight: 5.0 GB in swap")
        XCTAssertEqual(x?.related.first?.sample.pid, 11)
        XCTAssertEqual(x?.fixes, [.quit(pids: [11], name: "Chrome")])
        i.memory?.pressure = .normal
        XCTAssertNil(Insights.generate(i).first { $0.id == "memory" })
    }

    func testImpact() {
        let a = Impact(name: "Chrome", at: now, wattsBefore: 14, wattsAfter: 6, cpuBefore: 300, cpuAfter: 80, energyLeft: 42)
        // 42 Wh: 3 h at 14 W, 7 h at 6 W.
        XCTAssertEqual(a.minutesGained!, 240, accuracy: 0.01)
        XCTAssertTrue(a.helped)
        XCTAssertEqual(a.summary, "power 14.0 W → 6.0 W, CPU 3.0 cores → 80% of a core, about 4h 0m more battery")
        let b = Impact(name: "x", at: now, wattsBefore: nil, wattsAfter: nil, cpuBefore: 50, cpuAfter: 45, energyLeft: nil)
        XCTAssertFalse(b.helped)
        XCTAssertNil(b.minutesGained)
    }

    func testDisplayTipsAndTabWeights() {
        let d = [DisplayInfo(name: "Built-in", builtIn: true, width: 3024, height: 1964, refresh: 120, brightness: 0.9),
                 DisplayInfo(name: "LG", builtIn: false, width: 3840, height: 2160, refresh: 144, brightness: nil)]
        let t = DisplayAdvice.tips(d, gpu: 70, onBattery: true)
        XCTAssertEqual(t.count, 4)
        XCTAssertTrue(t[0].hasPrefix("The screen is at 90% brightness"))
        XCTAssertTrue(DisplayAdvice.tips([DisplayInfo(name: "B", builtIn: true, width: 1, height: 1, refresh: 120, brightness: 0.4)], gpu: 5, onBattery: false).isEmpty)

        XCTAssertEqual(TabWeight.of(url: "https://www.youtube.com/watch?v=1").score, 3)
        XCTAssertEqual(TabWeight.of(url: "https://meet.google.com/abc").reason, "video call")
        XCTAssertEqual(TabWeight.of(url: "https://claude.ai/chat").score, 2)
        XCTAssertEqual(TabWeight.of(url: "https://example.com").score, 1)
        XCTAssertEqual(TabWeight.of(url: "https://notyoutube.com").score, 1, "suffix must be a whole domain")
    }

    func testReportDocument() {
        let weekly = WeeklyReport(apps: [.init(name: "Chrome", coreHours: 12.5, share: 40)], coreHours: 31, hoursWatched: 60,
                                  busiestDay: now, busiestDayCoreHours: 9, batteryHours: 5, averageWatts: 8.2, flagged: 3, killed: 1)
        let doc = ReportDocument.build(machine: "Mac16,13", weekly: weekly, today: ["A line."],
                                       battery: BatteryStatus(cycleCount: 132, maxCapacity: 4500, designCapacity: 5000, condition: "Normal"),
                                       projection: now.addingTimeInterval(400 * day),
                                       sleep: SleepReport(asleep: 7200, sleeps: 1, darkWakes: 4, wakeCauses: [("network", 3)], chargeLost: 2, batteryAsleep: 7200),
                                       memory: MemoryStatus(pressure: .warning, total: 16 << 30, used: 12 << 30, compressed: 0, swapUsed: 1 << 30, swapTotal: 2 << 30),
                                       at: now)
        XCTAssertEqual(doc.sections.map(\.heading), ["The week", "Heaviest apps", "Today", "Battery", "Sleep, last 24 hours", "Memory"])
        let md = doc.markdown
        XCTAssertTrue(md.hasPrefix("# System Sentinel report\n"))
        XCTAssertTrue(md.contains("1. Chrome: 12.5 core-hours, 40% of all CPU\n"), "numbered list, no bullet")
        XCTAssertTrue(md.contains("- Holds 90% of its original capacity after 132 cycles."))
        XCTAssertTrue(md.contains("- Lost 1.0% of charge an hour while asleep on battery."))
        XCTAssertTrue(md.contains("- Under pressure: 12.0 GB of 16.0 GB used, 1.0 GB in swap."))
    }
}

final class HeatWatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSustainedPowerAlertsOnceThenCoolsDown() {
        var w = HeatWatch(thresholdWatts: 20, minutes: 3, cooldown: 1800)
        XCTAssertNil(w.update(watts: 30, thermal: 0, at: t0))
        XCTAssertNil(w.update(watts: 10, thermal: 0, at: t0.addingTimeInterval(60)), "a dip resets the stretch")
        var fired: [HeatWatch.Reason] = []
        for s in stride(from: 120.0, through: 600, by: 5) {
            if let r = w.update(watts: s < 400 ? 24 : 40, thermal: 0, at: t0.addingTimeInterval(s)) { fired.append(r) }
        }
        XCTAssertEqual(fired, [.power(watts: 24, minutes: 3)], "after 3 minutes above, then quiet")
        XCTAssertNotNil({ () -> HeatWatch.Reason? in
            var x = w
            var last: HeatWatch.Reason?
            for s in stride(from: 2400.0, through: 2700, by: 5) { last = x.update(watts: 40, thermal: 0, at: t0.addingTimeInterval(s)) ?? last }
            return last
        }(), "fires again after the cooldown")
    }

    func testHeatAlertsAtOnceAndEscalates() {
        var w = HeatWatch(thresholdWatts: 0)
        XCTAssertNil(w.update(watts: nil, thermal: 1, at: t0), "fair is normal under load")
        XCTAssertEqual(w.update(watts: nil, thermal: 2, at: t0.addingTimeInterval(5)), .heat(state: 2))
        XCTAssertNil(w.update(watts: nil, thermal: 2, at: t0.addingTimeInterval(10)))
        XCTAssertEqual(w.update(watts: nil, thermal: 3, at: t0.addingTimeInterval(15)), .heat(state: 3), "critical breaks the cooldown")
        XCTAssertNil(w.update(watts: nil, thermal: 3, at: t0.addingTimeInterval(20)))
        var off = HeatWatch(thresholdWatts: 0, watchHeat: false)
        XCTAssertNil(off.update(watts: nil, thermal: 3, at: t0))
    }
}

final class QuietTests: XCTestCase {
    func testAllQuietGivesWayToOtherWarnings() {
        var i = input()
        i.total1m = 20
        XCTAssertTrue(Insights.generate(i).contains { $0.id == "quiet" })
        i.memory = MemoryStatus(pressure: .warning, total: 16 << 30, used: 15 << 30, compressed: 0, swapUsed: 5 << 30, swapTotal: 6 << 30)
        XCTAssertFalse(Insights.generate(i).contains { $0.id == "quiet" })
    }
}
