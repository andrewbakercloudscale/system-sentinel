import XCTest
@testable import SentinelCore

private func ps(_ pid: Int32, _ cpu: Double, _ path: String = "/usr/bin/yes") -> ProcessSample {
    ProcessSample(pid: pid, uid: getuid(), cpu: cpu, path: path)
}

private func input(_ samples: [ProcessSample] = []) -> InsightInput {
    InsightInput(cores: 10, samples: samples, total1m: 50, total15m: 50, total60m: 50, avg15m: [:], recordedMinutes: 60,
                 daily: [], dailySampled: 0, totalHourly: [], hourStarts: [], events: [], thermal: 0, lowPower: false)
}

final class BatteryTests: XCTestCase {
    // Recorded on an M4 MacBook Pro on battery.
    let registry: [String: Any] = [
        "Amperage": 0, "InstantAmperage": 0, "Voltage": 13246, "CurrentCapacity": 100, "AppleRawMaxCapacity": 5357,
        "NominalChargeCapacity": 5501, "DesignCapacity": 5760, "CycleCount": 132, "Temperature": 3004,
        "IsCharging": false, "ExternalConnected": false, "FullyCharged": true, "AvgTimeToEmpty": 65535,
        "BatteryInstalled": true, "PermanentFailureStatus": 0, "PowerTelemetryData": ["SystemLoad": 6924, "BatteryPower": 0],
    ]
    let source: [String: Any] = [
        "Power Source State": "Battery Power", "Current Capacity": 100, "Time to Empty": -1, "Is Charging": 0,
        "DesignCycleCount": 1000, "BatteryHealth": "Check Battery", "Type": "InternalBattery",
    ]

    func testParsesARealBatteryOnBattery() {
        let b = PowerReader.parse(registry: registry, source: source, lowPowerMode: false)
        XCTAssertTrue(b.onBattery)
        XCTAssertFalse(b.charging)
        XCTAssertEqual(b.percent, 100)
        XCTAssertEqual(b.watts!, 6.924, accuracy: 0.001)
        XCTAssertNil(b.minutesToEmpty, "-1 means still estimating")
        XCTAssertEqual(b.cycleCount, 132)
        XCTAssertEqual(b.designCycles, 1000)
        XCTAssertEqual(b.health!, 5357.0 / 5760 * 100, accuracy: 0.01)
        XCTAssertEqual(b.condition, "Normal", "IOPS's \"Check Battery\" was a false alarm on this healthy battery")
        XCTAssertEqual(b.temperature!, 30.04, accuracy: 0.001)
        XCTAssertEqual(b.voltage!, 13.246, accuracy: 0.001)
        // 5357 mAh at 13.2 V is about 71 Wh; at 6.9 W that is about 10 hours.
        XCTAssertEqual(b.energyLeft!, 70.96, accuracy: 0.1)
        XCTAssertEqual(b.minutesLeft!, 614, accuracy: 2)
    }

    func testFallsBackToAmperageAndReadsSignedCurrent() {
        var r = registry
        r["PowerTelemetryData"] = nil
        r["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -1500))
        let b = PowerReader.parse(registry: r, source: source, lowPowerMode: true)
        XCTAssertEqual(b.watts!, 1.5 * 13.246, accuracy: 0.01)
        XCTAssertTrue(b.lowPowerMode)
    }

    func testChargingAndHealthyBattery() {
        var s = source
        s["Power Source State"] = "AC Power"
        s["Is Charging"] = 1
        s["Time to Full Charge"] = 42
        s["BatteryHealth"] = "Good"
        var r = registry
        r["AdapterDetails"] = ["Watts": 96]
        let b = PowerReader.parse(registry: r, source: s, lowPowerMode: false)
        XCTAssertFalse(b.onBattery)
        XCTAssertTrue(b.charging)
        XCTAssertEqual(b.minutesToFull, 42)
        XCTAssertNil(b.minutesLeft)
        XCTAssertEqual(b.condition, "Normal")
        XCTAssertEqual(b.adapterWatts, 96)
    }

    func testWeakChargerStillDrains() {
        // Recorded on an M4 MacBook Pro on an 8 W USB brick: 7.5 W in, 17.4 W used, battery -9.9 W.
        var s = source
        s["Power Source State"] = "AC Power"
        s["Is Charging"] = 1
        var r = registry
        r["CurrentCapacity"] = 50
        r["PowerTelemetryData"] = ["SystemLoad": 17436, "SystemPowerIn": 7495,
                                   "BatteryPower": NSNumber(value: UInt64(bitPattern: -9941))]
        let b = PowerReader.parse(registry: r, source: s, lowPowerMode: false)
        XCTAssertEqual(b.powerIn!, 7.495, accuracy: 0.001)
        XCTAssertEqual(b.batteryWatts!, -9.941, accuracy: 0.001)
        XCTAssertTrue(b.losingOnPower)
        XCTAssertNotNil(b.minutesLeftOnPower)

        r["PowerTelemetryData"] = ["SystemLoad": 8000, "SystemPowerIn": 60000, "BatteryPower": 50000]
        let c = PowerReader.parse(registry: r, source: s, lowPowerMode: false)
        XCTAssertEqual(c.batteryWatts!, 50, accuracy: 0.001)
        XCTAssertFalse(c.losingOnPower)
        XCTAssertNil(PowerReader.parse(registry: r, source: source, lowPowerMode: false).powerIn, "no charger on battery")
    }

    func testAppleHealthFromSystemProfiler() {
        let json = #"{"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":{"sppower_battery_cycle_count":132,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"97%"}}]}"#
        let h = PowerReader.parseAppleHealth(Data(json.utf8))
        XCTAssertEqual(h?.condition, "Normal")
        XCTAssertEqual(h?.maxPercent, 97)
        let bad = #"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_health":"Service Recommended"}}]}"#
        XCTAssertEqual(PowerReader.parseAppleHealth(Data(bad.utf8))?.condition, "Service Recommended")
        XCTAssertNil(PowerReader.parseAppleHealth(Data("{}".utf8)))
    }

    func testLiveReadDoesNotCrash() {
        _ = PowerReader.read()
        _ = SleepBlockers.read()
    }
}

final class SleepBlockerTests: XCTestCase {
    func testCaffeinateOnBehalfOfAndKinds() {
        let raw: [Int32: [[String: Any]]] = [
            61741: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "caffeinate command-line tool",
                     "Process Name": "caffeinate", "AssertStartWhen": "2026-10-17 08:39:46 +0000",
                     "Details": "caffeinate asserting on behalf of 'claude' (pid 61739)"]],
            13585: [["AssertType": "PreventUserIdleDisplaySleep", "AssertName": "caffeinate command-line tool",
                     "Process Name": "caffeinate", "AssertStartWhen": "2026-10-11 10:00:00 +0000",
                     "Details": "caffeinate asserting on behalf of 'nano' (pid 13584)"]],
            335: [["AssertType": "UserIsActive", "AssertName": "com.apple.powermanagement.lidopen", "Process Name": "powerd"]],
            97395: [["AssertType": "PreventUserIdleSystemSleep", "Process Name": "caffeinate", "AssertName": "x",
                     "Details": "caffeinate asserting for 300 secs", "TimeoutSeconds": 300]],
        ]
        let b = SleepBlockers.parse(raw)
        XCTAssertEqual(b.count, 3, "powerd's UserIsActive is not a blocker")
        XCTAssertEqual(b[0].pid, 13585, "oldest first")
        XCTAssertEqual(b[0].kind, .display)
        XCTAssertEqual(b[0].onBehalfOf, "nano")
        XCTAssertEqual(b[0].onBehalfOfPID, 13584)
        XCTAssertEqual(b[1].onBehalfOf, "claude")
        XCTAssertEqual(b[1].kind, .system)
        XCTAssertNil(b[2].onBehalfOf)
        XCTAssertEqual(b[2].timeout, 300)
    }

    func testLongBlockersBecomeAnInsight() {
        let now = Date()
        var i = input([ps(61741, 0, "/usr/bin/caffeinate"), ps(61739, 5, "/usr/local/bin/claude")])
        i.blockers = [SleepBlocker(pid: 61741, name: "caffeinate", kind: .system, reason: "caffeinate",
                                   since: now.addingTimeInterval(-25 * 3600), onBehalfOf: "claude", onBehalfOfPID: 61739),
                      SleepBlocker(pid: 9, name: "Music", kind: .system, reason: "playing", since: now.addingTimeInterval(-60))]
        let x = Insights.generate(i, at: now).first { $0.id == "blockers" }
        XCTAssertNotNil(x)
        XCTAssertEqual(x?.title, "1 thing is keeping your Mac awake")
        XCTAssertTrue(x!.detail.contains("claude"))
        XCTAssertTrue(x!.detail.contains("25h"))
        XCTAssertEqual(x!.related.map(\.sample.pid), [61741], "the caffeinate itself, so Kill frees the Mac")
        XCTAssertEqual(x!.related[0].about, "Keeps the Mac awake for claude for 25h 0m")
        XCTAssertEqual(x!.related[0].parent, "claude (pid 61739)")
    }
}

final class EnergyTests: XCTestCase {
    func testParsesTheSecondTopSample() {
        let out = """
        Processes: 900 total
        PID    POWER IDLEW
        10     99.0  5
        PID    POWER IDLEW
        43780  34.2  42942
        15788  6,4   275857+
        bad line
        """
        let r = EnergySampler.parse(out)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[43780]?.power, 34.2)
        XCTAssertEqual(r[15788]?.power, 6.4)
        XCTAssertEqual(r[15788]?.idleWakeups, 275857)
        XCTAssertNil(r[10], "first sample has no interval")
    }

    func testWakeupRatesAndGrouping() {
        let t = WakeupTracker()
        let start = Date()
        XCTAssertEqual(t.update([1: (10, 1000)], at: start).first?.wakeups, 0)
        let e = t.update([1: (12, 4000), 2: (3, 50)], at: start.addingTimeInterval(30))
        XCTAssertEqual(e.first { $0.pid == 1 }?.wakeups, 100)
        XCTAssertEqual(e.first { $0.pid == 2 }?.wakeups, 0, "new pid has no rate yet")

        let rows = EnergyRow.group(
            [EnergySample(pid: 1, power: 12, wakeups: 100), EnergySample(pid: 3, power: 8, wakeups: 20),
             EnergySample(pid: 2, power: 30, wakeups: 1), EnergySample(pid: 99, power: 50, wakeups: 0)],
            processes: [ps(1, 0, "/A.app/Contents/MacOS/A"), ps(3, 0, "/A.app/Contents/MacOS/A"), ps(2, 0, "/usr/bin/b")],
            key: { $0 }, name: { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(rows.map(\.name), ["b", "A"], "unknown pid 99 dropped; heaviest first")
        XCTAssertEqual(rows[1].power, 20)
        XCTAssertEqual(rows[1].wakeups, 120)
        XCTAssertEqual(rows[1].pids, [1, 3])
    }

    func testHealthRAGCountsTheGPU() {
        var s = HealthRAG.Signals()
        s.gpu = 40
        XCTAssertEqual(HealthRAG.of(s).rag, .green)
        s.gpu = 65
        XCTAssertEqual(HealthRAG.of(s).rag, .amber)
        XCTAssertEqual(HealthRAG.of(s).reasons.first?.text, "GPU 65%")
        s.gpu = 95
        XCTAssertEqual(HealthRAG.of(s).rag, .red)
        XCTAssertEqual(HealthRAG.of(s).reasons.first?.symbol, "square.stack.3d.up.fill")
    }

    func testHealthRAGTakesTheWorstRisk() {
        var s = HealthRAG.Signals()
        XCTAssertEqual(HealthRAG.of(s).rag, .green)
        s.load = 10
        s.disk = 1
        s.diskFree = 20 << 30
        XCTAssertEqual(HealthRAG.of(s).rag, .amber)
        XCTAssertEqual(HealthRAG.of(s).reasons.first?.symbol, "internaldrive")
        s.pressure = 2
        let h = HealthRAG.of(s)
        XCTAssertEqual(h.rag, .red)
        XCTAssertEqual(h.reasons.map(\.rag), [.red, .amber], "red first")
        s = HealthRAG.Signals()
        s.onBattery = true
        s.battery = 8
        XCTAssertEqual(HealthRAG.of(s).rag, .red)
        s.onBattery = false
        XCTAssertEqual(HealthRAG.of(s).rag, .green, "low battery on the charger is fine")
    }

    func testLoadRAG() {
        XCTAssertEqual(LoadRAG.of(load: 15, flagged: false), .green)
        XCTAssertEqual(LoadRAG.of(load: 40, flagged: false), .amber)
        XCTAssertEqual(LoadRAG.of(load: 70, flagged: false), .red)
        XCTAssertEqual(LoadRAG.of(load: 5, flagged: true), .red, "a flagged process is always red")
    }

    func testBatteryMinutes() {
        XCTAssertEqual(BatteryMath.appWatts(share: 0.5, totalWatts: 12.5), 5)
        XCTAssertEqual(BatteryMath.appWatts(share: 0.5, totalWatts: 2), 0)
        XCTAssertEqual(BatteryMath.minutesPerHour(appWatts: 5, watts: 10), 30)
        // 60 Wh at 10 W is 6 h; at 5 W, 12 h: 6 hours gained.
        XCTAssertEqual(BatteryMath.minutesGained(energyLeft: 60, watts: 10, appWatts: 5), 360, accuracy: 0.01)
        XCTAssertEqual(BatteryMath.minutesGained(energyLeft: 60, watts: 10, appWatts: 10), 0)
    }

    func testAppEnergyIsWattHoursAboveBaseline() {
        // An hour at 14.5 W is 12 Wh above the 2.5 W baseline; minutes below it add nothing.
        let hour = (0..<60).map { PowerHistory.Point(t: $0 * 60, watts: 14.5, onBattery: true, percent: 80, n: 1) }
        let idle = [PowerHistory.Point(t: 3600, watts: 1, onBattery: true, percent: 80, n: 1)]
        XCTAssertEqual(BatteryMath.appEnergy(hour + idle), 12, accuracy: 0.001)
        XCTAssertEqual(BatteryMath.appEnergy([]), 0)
    }

    func testHeavyAppOnBatteryNamesItsCost() {
        var i = input([ps(1, 80, "/Applications/Chrome.app/Contents/MacOS/Chrome")])
        i.battery = BatteryStatus(onBattery: true, percent: 50, watts: 12.5, maxCapacity: 5000, designCapacity: 5000, voltage: 12)
        i.energy = [EnergyRow(key: "chrome", name: "Chrome", power: 60, wakeups: 600, pids: [1]),
                    EnergyRow(key: "x", name: "X", power: 40, wakeups: 0, pids: [])]
        let all = Insights.generate(i)
        let drain = all.first { $0.id == "drain-chrome" }
        // 60% of (12.5 - 2.5) W = 6 W, 6 / 12.5 of each hour = 28.8 minutes.
        XCTAssertEqual(drain?.title, "Chrome costs about 28 minutes of battery an hour")
        XCTAssertEqual(drain?.tone, .warning)
        XCTAssertNotNil(drain?.why, "30 Wh left: quitting it gains hours")
        XCTAssertEqual(drain?.related.first?.sample.pid, 1)
        XCTAssertNotNil(all.first { $0.id == "wakeups-chrome" })
        XCTAssertNil(all.first { $0.id == "lpm" }, "50% is not low")
    }

    func testPluggedInHasNoDrainButLowBatterySuggestsLowPowerMode() {
        var i = input()
        i.battery = BatteryStatus(onBattery: false, percent: 20, watts: 20)
        i.energy = [EnergyRow(key: "a", name: "A", power: 90, wakeups: 0, pids: [])]
        XCTAssertFalse(Insights.generate(i).contains { $0.id.hasPrefix("drain-") || $0.id == "lpm" })
        i.battery?.onBattery = true
        i.battery?.percent = 12
        XCTAssertEqual(Insights.generate(i).first { $0.id == "lpm" }?.tone, .warning)
        i.battery?.lowPowerMode = true
        XCTAssertNil(Insights.generate(i).first { $0.id == "lpm" })
    }

    func testBackgroundWorkOnBatteryAndHealth() {
        var i = input([ps(5, 60, "/System/Library/CoreServices/backupd")])
        i.battery = BatteryStatus(onBattery: true, percent: 80, maxCapacity: 4000, designCapacity: 5760, condition: "Check Battery")
        let all = Insights.generate(i)
        XCTAssertEqual(all.first { $0.id == "bg-battery" }?.title, "Time Machine running on battery")
        let h = all.first { $0.id == "health" }
        XCTAssertEqual(h?.title, "macOS says: Check Battery")
        XCTAssertTrue(h!.detail.contains("69%"))
    }
}

final class CoreAndRuleTests: XCTestCase {
    func testPerCoreLoadSplitsEfficiencyFirst() {
        typealias T = CoreLoad.Ticks
        let a = [T(user: 0, system: 0, idle: 0, nice: 0), T(user: 0, system: 0, idle: 0, nice: 0), T(user: UInt64(UInt32.max) - 10, system: 0, idle: 0, nice: 0)]
        let b = [T(user: 25, system: 25, idle: 50, nice: 0), T(user: 0, system: 0, idle: 100, nice: 0), T(user: 89, system: 0, idle: 0, nice: 0)]
        let l = CoreLoad.between(a, b, efficiencyCount: 2)
        XCTAssertEqual(l.perCore, [50, 0, 100], "the third counter wrapped at 32 bits")
        XCTAssertEqual(l.efficiencyAverage, 25)
        XCTAssertEqual(l.performanceAverage, 100)
        XCTAssertEqual(CoreLoad(perCore: [1, 2], efficiencyCount: 5).efficiencyCount, 2)
        let live = CoreSampler()
        XCTAssertNil(live.sample(), "first reading has no interval")
        XCTAssertEqual(live.sample()?.perCore.count, ProcessInfo.processInfo.processorCount)
    }

    func testBackgroundItemPlists() {
        let a = BackgroundItems.parse(["Label": "com.google.keystone.agent", "ProgramArguments": ["/Library/Google/ksinstall", "--x"],
                                       "RunAtLoad": true, "StartInterval": 3600], plist: "/p.plist", scope: .user)
        XCTAssertEqual(a?.vendor, "Google")
        XCTAssertEqual(a?.name, "ksinstall")
        XCTAssertEqual(a?.interval, 3600)
        XCTAssertTrue(a!.runAtLoad)
        XCTAssertFalse(a!.keepAlive)
        let b = BackgroundItems.parse(["Label": "zscaler", "Program": "/opt/z", "KeepAlive": ["SuccessfulExit": false]], plist: "/q", scope: .system)
        XCTAssertTrue(b!.keepAlive)
        XCTAssertEqual(b?.vendor, "zscaler")
        XCTAssertNil(BackgroundItems.parse(["Program": "/x"], plist: "/r", scope: .user), "no label")
        let c = BackgroundItems.parse(["Label": "ninja.burst", "ProgramArguments": ["/bin/zsh", "-lc", "/Users/me/bin/burst.sh --loop"]], plist: "/s", scope: .user)
        XCTAssertEqual(c?.name, "burst.sh")
        XCTAssertNil(c?.processPath, "every zsh would match")
        XCTAssertEqual(a?.processPath, "/Library/Google/ksinstall")
        _ = BackgroundItems.scan()
    }

    func testBackgroundItemRemoveCommand() {
        let u = BackgroundItems.parse(["Label": "it's.x", "Program": "/x"], plist: "/Users/me/Library/LaunchAgents/it's.x.plist", scope: .user)!
        let cmd = BackgroundItems.removeCommand(u, uid: 501, trash: "/Users/me/.Trash")
        XCTAssertTrue(cmd.hasPrefix("/bin/launchctl bootout 'gui/501/it'\\''s.x' 2>/dev/null; /bin/mv '/Users/me/Library/LaunchAgents/it'\\''s.x.plist' '/Users/me/.Trash/it'\\''s.x "), cmd)
        let d = BackgroundItems.parse(["Label": "com.z", "Program": "/z"], plist: "/Library/LaunchDaemons/com.z.plist", scope: .system)!
        XCTAssertTrue(BackgroundItems.removeCommand(d, uid: 501, trash: "/t").hasPrefix("/bin/launchctl bootout 'system/com.z'"))
    }

    func testAutoKillOnBatteryOnlyOnBattery() throws {
        var killed: [Int32] = []
        let store = PolicyStore(fileURL: nil)
        store.set(.autoKillOnBattery, for: "/usr/bin/yes")
        let s = Sentinel(detector: Detector(threshold: 80, window: 10), policies: store, history: History(fileURL: nil),
                         sampler: { [ps(7, 99)] }, killer: { killed.append($0.pid); return .terminated })
        var battery = false
        s.onBattery = { battery }
        let t0 = Date()
        try s.tick(at: t0)
        let plugged = try s.tick(at: t0.addingTimeInterval(11))
        XCTAssertEqual(plugged, [.alert(ps(7, 99))])
        XCTAssertTrue(killed.isEmpty)

        battery = true
        let s2 = Sentinel(detector: Detector(threshold: 80, window: 10), policies: store, history: History(fileURL: nil),
                          sampler: { [ps(7, 99)] }, killer: { killed.append($0.pid); return .terminated })
        s2.onBattery = { battery }
        try s2.tick(at: t0)
        try s2.tick(at: t0.addingTimeInterval(11))
        XCTAssertEqual(killed, [7])

        let data = try JSONEncoder().encode([Policy.autoKillOnBattery])
        XCTAssertEqual(try JSONDecoder().decode([Policy].self, from: data), [.autoKillOnBattery])
    }
}

final class ReportTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPowerHistoryAveragesPerMinuteAndSummarises() {
        let h = PowerHistory(fileURL: nil)
        let t = now
        h.record(BatteryStatus(onBattery: true, percent: 80, watts: 10), at: t)
        h.record(BatteryStatus(onBattery: true, percent: 80, watts: 20), at: t.addingTimeInterval(5))
        XCTAssertEqual(h.points.count, 1)
        XCTAssertEqual(h.points[0].watts, 15)
        h.record(BatteryStatus(onBattery: true, percent: 80, watts: nil), at: t.addingTimeInterval(10))
        XCTAssertEqual(h.points[0].n, 2, "no reading, no point")
        for m in 1...20 {
            h.record(BatteryStatus(onBattery: true, percent: 80 - m / 2, watts: 10), at: t.addingTimeInterval(Double(m) * 60))
        }
        h.record(BatteryStatus(onBattery: false, percent: 90, watts: 30), at: t.addingTimeInterval(21 * 60))
        let s = BatterySummary.from(h.points)
        XCTAssertEqual(s.minutes, 22)
        XCTAssertEqual(s.batteryMinutes, 21)
        XCTAssertEqual(s.peakWatts, 30)
        XCTAssertEqual(s.drainPerHour!, 30, accuracy: 0.01, "10% in 20 minutes; the charge back up is ignored")
        // Older than 7 days ages out.
        h.record(BatteryStatus(onBattery: false, percent: 90, watts: 5), at: t.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(h.points.count, 1)
    }

    func testPowerHistoryPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        PowerHistory(fileURL: url).record(BatteryStatus(onBattery: true, percent: 50, watts: 8), at: now)
        XCTAssertEqual(PowerHistory(fileURL: url).points.first?.watts, 8)
    }

    private func usage(hoursOfLoad load: [Double]) -> DailyUsage {
        let u = DailyUsage(fileURL: nil, maxStep: 3600)
        // Each hour sampled from its first second to its last, so no hour leaks into the next.
        let first = now.addingTimeInterval(-Double(load.count) * 3600)
        u.record([], at: first)
        for (k, l) in load.enumerated() {
            let rows = [ps(1, l, "/Applications/A.app/Contents/MacOS/A"), ps(2, l / 4, "/usr/bin/b")]
            u.record(rows, at: first.addingTimeInterval(Double(k) * 3600 + 1800))
            u.record(rows, at: first.addingTimeInterval(Double(k) * 3600 + 3599))
        }
        return u
    }

    func testTypicalTotalAndComparison() {
        let u = usage(hoursOfLoad: Array(repeating: 40, count: 10) + [200])
        XCTAssertEqual(u.typicalTotal(at: now)!, 50, accuracy: 0.5, "the current and previous hour are left out")
        XCTAssertNil(usage(hoursOfLoad: [40, 40]).typicalTotal(at: now), "too little history")

        var i = input()
        i.total60m = 250
        i.typicalTotal = 50
        XCTAssertEqual(Insights.generate(i).first { $0.id == "vsusual" }?.title, "The Mac is 5 times busier than usual this hour")
        i.total60m = 60
        XCTAssertNil(Insights.generate(i).first { $0.id == "vsusual" })
    }

    func testWeeklyReport() {
        let u = usage(hoursOfLoad: Array(repeating: 100, count: 30))
        let events = [HistoryEntry(date: now, kind: .flagged, pid: 1, name: "A", path: "/a", cpu: 99, detail: ""),
                      HistoryEntry(date: now, kind: .autoKilled, pid: 1, name: "A", path: "/a", cpu: 99, detail: ""),
                      HistoryEntry(date: now.addingTimeInterval(-9 * 86_400), kind: .killed, pid: 1, name: "A", path: "/a", cpu: 99, detail: "")]
        let power = (0..<90).map { PowerHistory.Point(t: Int(now.timeIntervalSince1970) - $0 * 60, watts: 10, onBattery: $0 < 60, percent: 50, n: 1) }
        let r = WeeklyReport.build(usage: u, power: power, events: events, at: now)
        XCTAssertEqual(r.apps.first?.name, "A")
        XCTAssertEqual(r.apps.first!.share, 80, accuracy: 0.5)
        XCTAssertEqual(r.coreHours, 37.5, accuracy: 1.5)
        XCTAssertEqual(r.batteryHours, 1)
        XCTAssertEqual(r.averageWatts, 10)
        XCTAssertEqual(r.flagged, 1)
        XCTAssertEqual(r.killed, 1, "the 9 day old kill is out of the week")
        XCTAssertNotNil(r.busiestDay)
        XCTAssertTrue(r.text.contains("A used the most CPU (80%)"))
    }

    func testDaySummary() {
        let u = usage(hoursOfLoad: [100, 100, 100])
        let blockers = [SleepBlocker(pid: 1, name: "caffeinate", kind: .system, reason: "", since: now.addingTimeInterval(-7200))]
        let power = BatterySummary(minutes: 120, batteryMinutes: 60, averageWatts: 9, averageBatteryWatts: 8, peakWatts: 20, drainPerHour: 12)
        let lines = DaySummary.lines(daily: u.summaries(at: now), sampled: u.sampled(at: now), totalHourly: u.totalHourly(at: now),
                                     hourStarts: DailyUsage.hourStarts(at: now, hours: 24).map { Date(timeIntervalSince1970: Double($0)) },
                                     power: power, blockers: blockers, cores: 10, at: now)
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[1].hasPrefix("Most CPU time: A 80%"))
        XCTAssertEqual(lines[3], "On battery for 1h 0m, drawing 8.0 W on average, using 12% an hour.")
        XCTAssertTrue(lines[4].hasPrefix("1 sleep blocker has"))
    }
}

final class EnergyGlitchTests: XCTestCase {
    func testImpossibleImpactIsDroppedAndOldOutliersRemoved() {
        let out = EnergySampler.parse("PID POWER IDLEW\n358 167150900.0 3\n12 45.2 10+\n")
        XCTAssertNil(out[358])
        XCTAssertEqual(out[12]?.power, 45.2)

        let u = DailyUsage(fileURL: nil)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        u.record([ProcessSample(pid: 1, uid: 0, cpu: 167_150_900, path: "/usr/sbin/syslogd"),
                  ProcessSample(pid: 2, uid: 501, cpu: 20, path: "/bin/app")], at: t)
        u.record([ProcessSample(pid: 1, uid: 0, cpu: 167_150_900, path: "/usr/sbin/syslogd"),
                  ProcessSample(pid: 2, uid: 501, cpu: 20, path: "/bin/app")], at: t.addingTimeInterval(5))
        XCTAssertEqual(u.dropOutliers(above: EnergySampler.maxImpact), 1)
        XCTAssertNil(u.entries["/usr/sbin/syslogd"])
        XCTAssertNotNil(u.entries["/bin/app"])
    }
}

final class BatteryETATests: XCTestCase {
    func testLastHourPaceLeadsWhenThereIsOne() {
        // 88% now, falling about 10% an hour: 8 to 9 hours left, whatever macOS says.
        let hour = (0..<60).map { PowerHistory.Point(t: $0 * 60, watts: 9, onBattery: true, percent: 99 - $0 * 11 / 60, n: 1) }
        let b = BatteryStatus(onBattery: true, percent: 88, watts: 13, minutesToEmpty: 880, maxCapacity: 5000, designCapacity: 5000, voltage: 12)
        let eta = BatteryETA.of(b, lastHour: hour)
        XCTAssertEqual(eta?.basis, .recentPace)
        XCTAssertEqual(Double(eta?.minutes ?? 0), 519, accuracy: 5)
        XCTAssertEqual(eta?.macOS, 880)
        XCTAssertEqual(eta?.currentDraw, Int(5000.0 * 0.88 * 12 / 1000 / 13 * 60))
    }

    func testFallsBackToMacOSThenCurrentDrawAndNothingWhenPluggedIn() {
        let b = BatteryStatus(onBattery: true, percent: 50, watts: 10, minutesToEmpty: 200, maxCapacity: 5000, designCapacity: 5000, voltage: 12)
        XCTAssertEqual(BatteryETA.of(b, lastHour: [])?.basis, .macOS)
        var c = b
        c.minutesToEmpty = nil
        XCTAssertEqual(BatteryETA.of(c, lastHour: [])?.basis, .currentDraw)
        c.onBattery = false
        XCTAssertNil(BatteryETA.of(c, lastHour: []))
    }

    func testLowBatteryWarnsAt20And5Minutes() {
        var w = LowBatteryWarning()
        XCTAssertNil(w.update(minutesLeft: 45, draining: true))
        XCTAssertEqual(w.update(minutesLeft: 19, draining: true), 20)
        XCTAssertNil(w.update(minutesLeft: 15, draining: true))
        XCTAssertNil(w.update(minutesLeft: nil, draining: true))
        XCTAssertEqual(w.update(minutesLeft: 5, draining: true), 5)
        XCTAssertNil(w.update(minutesLeft: 3, draining: true))
        // Plugged in and charging: starts over.
        XCTAssertNil(w.update(minutesLeft: nil, draining: false))
        XCTAssertEqual(w.update(minutesLeft: 18, draining: true), 20)
        // A sudden drop past both warns once, at 5.
        var v = LowBatteryWarning()
        XCTAssertEqual(v.update(minutesLeft: 4, draining: true), 5)
        XCTAssertNil(v.update(minutesLeft: 2, draining: true))
    }

    func testMinutesIfUnplugged() {
        // 5000 mAh at 50% and 12 V is 30 Wh; at 10 W that lasts 3 hours.
        let b = BatteryStatus(onBattery: false, percent: 50, watts: 10, maxCapacity: 5000, voltage: 12)
        XCTAssertEqual(b.minutesIfUnplugged, 180)
        XCTAssertNil(BatteryStatus(percent: 50, watts: 0.2, maxCapacity: 5000, voltage: 12).minutesIfUnplugged)
    }

    func testMinutesUntilFull() {
        // Half of 5000 mAh at 12 V is 30 Wh to go; at 15 W in, 2 hours.
        let b = BatteryStatus(charging: true, percent: 50, maxCapacity: 5000, batteryWatts: 15, voltage: 12)
        XCTAssertEqual(b.minutesUntilFull, 120)
        var mac = b
        mac.minutesToFull = 95
        XCTAssertEqual(mac.minutesUntilFull, 95)
        XCTAssertNil(BatteryStatus(charging: false, percent: 50).minutesUntilFull)
    }
}
