import XCTest
@testable import SentinelCore

private func ps(_ pid: Int32, _ cpu: Double, _ path: String = "/usr/bin/yes", uid: UInt32 = getuid()) -> ProcessSample {
    ProcessSample(pid: pid, uid: uid, cpu: cpu, path: path)
}

final class ParserTests: XCTestCase {
    func testParsesPathsWithSpacesAndCommaDecimals() {
        let out = """
          13560     0 171,6  11856 /usr/libexec/PerfPowerServices
          18060   501  37.8 375632 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/154.0.8037.95/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
            garbage line
        """
        let s = ProcessSampler.parse(out)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0], ProcessSample(pid: 13560, uid: 0, cpu: 171.6, path: "/usr/libexec/PerfPowerServices", rssKB: 11856))
        XCTAssertEqual(s[1].rssKB, 375632)
        XCTAssertTrue(s[0].isRoot)
        XCTAssertEqual(s[1].cpu, 37.8)
        XCTAssertTrue(s[1].isChromeRenderer)
        XCTAssertEqual(s[1].displayName, "Chrome tab (renderer 18060)")
        XCTAssertEqual(s[1].name, "Google Chrome Helper (Renderer)")
    }

    func testLiveSampleSeesThisProcessAndRootDaemons() throws {
        let all = try ProcessSampler.sample()
        XCTAssertTrue(all.contains { $0.pid == getpid() }, "own process missing")
        XCTAssertTrue(all.contains { $0.pid == 1 && $0.isRoot }, "launchd (root) missing: root CPU would be invisible")
    }
}

final class StartTimeTests: XCTestCase {
    func testStartTimesForThisProcessAndARootDaemon() throws {
        let mine = try XCTUnwrap(ProcessSampler.startTime(of: getpid()))
        XCTAssertLessThan(mine, Date())
        XCTAssertGreaterThan(mine, Date().addingTimeInterval(-3600))
        let launchd = try XCTUnwrap(ProcessSampler.startTime(of: 1), "root processes must be readable")
        XCTAssertLessThanOrEqual(launchd, mine)
        XCTAssertNil(ProcessSampler.startTime(of: 99_999_999))
    }
}

final class DetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSteadyHotProcessAlertsOnceAfterTheWindow() {
        let d = Detector(threshold: 80, window: 120)
        var alerts = 0
        for i in 0...60 { alerts += d.update([ps(42, 95)], at: t0 + Double(i) * 5).count }
        XCTAssertEqual(alerts, 1, "one alert per episode, not one per sample")
    }

    func testNothingBeforeTheWindow() {
        let d = Detector(threshold: 80, window: 120)
        for i in 0..<24 { XCTAssertTrue(d.update([ps(42, 95)], at: t0 + Double(i) * 5).isEmpty) }
        XCTAssertEqual(d.update([ps(42, 95)], at: t0 + 120).count, 1)
    }

    func testBurstsNeverAlert() {
        // 30 s hot, 5 s cool, repeated: a build. Never a full 120 s window.
        let d = Detector(threshold: 80, window: 120)
        var alerts = 0
        var t = t0
        for _ in 0..<20 {
            for _ in 0..<6 { alerts += d.update([ps(7, 99)], at: t).count; t += 5 }
            alerts += d.update([ps(7, 10)], at: t).count; t += 5
        }
        XCTAssertEqual(alerts, 0)
    }

    func testCoolingDownStartsANewEpisode() {
        let d = Detector(threshold: 80, window: 10)
        XCTAssertTrue(d.update([ps(1, 90)], at: t0).isEmpty)
        XCTAssertEqual(d.update([ps(1, 90)], at: t0 + 10).count, 1)
        XCTAssertTrue(d.update([ps(1, 5)], at: t0 + 15).isEmpty)
        XCTAssertTrue(d.update([ps(1, 90)], at: t0 + 20).isEmpty)
        XCTAssertEqual(d.update([ps(1, 90)], at: t0 + 30).count, 1)
    }

    func testAVanishedPidIsForgotten() {
        let d = Detector(threshold: 80, window: 10)
        _ = d.update([ps(1, 90)], at: t0)
        _ = d.update([], at: t0 + 5)
        XCTAssertTrue(d.update([ps(1, 90)], at: t0 + 10).isEmpty, "a reused pid inherited the old episode")
    }
}

final class SafetyTests: XCTestCase {
    func testProtectedProcessesAreNeverKillable() {
        for name in ["WindowServer", "kernel_task", "launchd", "loginwindow", "Dock", "Finder"] {
            let s = ps(500, 99, "/System/whatever/\(name)", uid: 0)
            XCTAssertFalse(Safety.canKillManually(s), name)
            XCTAssertEqual(Killer.kill(s), .refused("\(name) is protected"))
        }
        XCTAssertFalse(Safety.canKillManually(ps(1, 99, "/sbin/anything", uid: 0)), "pid 1")
        XCTAssertFalse(Safety.canKillManually(ps(getpid(), 99, "/tmp/me")), "self")
    }

    func testRootIsManualOnly() {
        let root = ps(13560, 171, "/usr/libexec/PerfPowerServices", uid: 0)
        XCTAssertTrue(Safety.canKillManually(root))
        XCTAssertFalse(Safety.canAutoKill(root))
        XCTAssertTrue(Safety.canAutoKill(ps(999, 99)))
    }
}

final class PolicyTests: XCTestCase {
    func testDefaultsToAlertAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = PolicyStore(fileURL: url)
        XCTAssertEqual(p.policy(for: "/usr/bin/yes"), .alert)
        p.set(.autoKill, for: "/usr/bin/yes")
        p.set(.ignore(until: nil), for: "/vm")
        let reloaded = PolicyStore(fileURL: url)
        XCTAssertEqual(reloaded.policy(for: "/usr/bin/yes"), .autoKill)
        XCTAssertEqual(reloaded.policy(for: "/vm"), .ignore(until: nil))
    }

    func testTimedIgnoreExpires() {
        let p = PolicyStore(fileURL: nil)
        let now = Date()
        p.set(.ignore(until: now + 3600), for: "/x")
        XCTAssertEqual(p.policy(for: "/x", at: now), .ignore(until: now + 3600))
        XCTAssertEqual(p.policy(for: "/x", at: now + 3601), .alert)
    }

    func testRateLimiterAllowsThreeAnHour() {
        let r = RateLimiter(limit: 3, period: 3600)
        let t = Date()
        XCTAssertTrue(r.allow("a", at: t))
        XCTAssertTrue(r.allow("a", at: t + 10))
        XCTAssertTrue(r.allow("a", at: t + 20))
        XCTAssertFalse(r.allow("a", at: t + 30))
        XCTAssertTrue(r.allow("b", at: t + 30), "limits are per executable")
        XCTAssertTrue(r.allow("a", at: t + 3601), "the hour rolls")
    }
}

final class SentinelTests: XCTestCase {
    func make(_ samples: @escaping () -> [ProcessSample], killed: @escaping (ProcessSample) -> Void = { _ in }) -> Sentinel {
        Sentinel(
            detector: Detector(threshold: 80, window: 10),
            policies: PolicyStore(fileURL: nil),
            history: History(fileURL: nil),
            sampler: samples,
            killer: { killed($0); return .terminated })
    }

    func testAlertPolicyAlerts() throws {
        let s = make({ [ps(5, 99)] })
        let t = Date()
        XCTAssertTrue(try s.tick(at: t).isEmpty)
        XCTAssertEqual(try s.tick(at: t + 10), [.alert(ps(5, 99))])
        XCTAssertEqual(s.history.entries.last?.kind, .flagged)
    }

    func testAutoKillStopsAtTheRateLimit() throws {
        var kills = 0
        var cpu = 99.0
        let s = make({ [ps(5, cpu)] }, killed: { _ in kills += 1 })
        s.policies.set(.autoKill, for: "/usr/bin/yes")
        var t = Date()
        var withheld = 0
        for _ in 0..<5 {
            cpu = 99
            _ = try s.tick(at: t); t += 10
            for e in try s.tick(at: t) { if case .autoKillWithheld = e { withheld += 1 } }
            t += 5
            cpu = 1
            _ = try s.tick(at: t); t += 5
        }
        XCTAssertEqual(kills, 3)
        XCTAssertEqual(withheld, 2)
    }

    func testRootIsNeverAutoKilled() throws {
        var kills = 0
        let root = ps(13560, 171, "/usr/libexec/PerfPowerServices", uid: 0)
        let s = make({ [root] }, killed: { _ in kills += 1 })
        s.policies.set(.autoKill, for: root.path)
        let t = Date()
        _ = try s.tick(at: t)
        let events = try s.tick(at: t + 10)
        XCTAssertEqual(kills, 0)
        XCTAssertEqual(events, [.autoKillWithheld(root, reason: "runs as root, needs the admin password")])
    }

    func testIgnoredAndProtectedStaySilent() throws {
        let s = make({ [ps(5, 99, "/vm"), ps(395, 99, "/x/WindowServer", uid: 88)] })
        s.policies.set(.ignore(until: nil), for: "/vm")
        let t = Date()
        _ = try s.tick(at: t)
        XCTAssertTrue(try s.tick(at: t + 10).isEmpty)
    }
}

/// The real thing: a CPU burner is seen by the real sampler, flagged, and killed.
final class IntegrationTests: XCTestCase {
    func testRealBurnerIsDetectedAndKilled() throws {
        let burner = Process()
        burner.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        burner.standardOutput = FileHandle.nullDevice
        try burner.run()
        defer { if burner.isRunning { burner.terminate() } }
        let pid = burner.processIdentifier

        // ps reports a decayed average, so give it a few seconds to climb.
        var seen: ProcessSample?
        for _ in 0..<40 {
            usleep(250_000)
            seen = try ProcessSampler.sample().first { $0.pid == pid }
            if let s = seen, s.cpu >= 50 { break }
        }
        let s = try XCTUnwrap(seen, "burner not in ps output")
        XCTAssertGreaterThanOrEqual(s.cpu, 50, "burner never looked hot")

        let d = Detector(threshold: 50, window: 1)
        let t = Date()
        _ = d.update([s], at: t)
        XCTAssertEqual(d.update([s], at: t + 1).map(\.sample.pid), [pid])

        XCTAssertEqual(Killer.kill(s), .terminated)
        burner.waitUntilExit()
        XCTAssertFalse(Killer.isAlive(pid))
    }
}

final class HistoryWindowTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testAveragesAreEnergyLike() {
        let h = CPUHistory(retention: 3600, interval: 5)
        // 60 min of recording; pid 9 hot (100%) only for the last 6 min.
        for i in 0..<720 {
            let t = t0 + Double(i) * 5
            let hot = i >= 648
            h.record([ProcessSample(pid: 9, uid: 501, cpu: hot ? 100 : 0, path: "/x"), ProcessSample(pid: 2, uid: 501, cpu: 50, path: "/y")], at: t)
        }
        let now = t0 + 719 * 5
        XCTAssertEqual(h.average(9, over: 60, at: now), 100, accuracy: 1)
        XCTAssertEqual(h.average(9, over: 3600, at: now), 10, accuracy: 1)
        XCTAssertEqual(h.average(2, over: 900, at: now), 50, accuracy: 1)
        XCTAssertEqual(h.totalAverage(over: 60, at: now), 150, accuracy: 1)
    }

    func testAFreshStartDoesNotDeflate() {
        let h = CPUHistory(interval: 5)
        for i in 0..<12 { h.record([ProcessSample(pid: 3, uid: 501, cpu: 80, path: "/z")], at: t0 + Double(i) * 5) }
        XCTAssertEqual(h.average(3, over: 3600, at: t0 + 55), 80, accuracy: 1, "one minute of data must not read as 80/60")
    }

    func testDeadPidLosesItsHistory() {
        let h = CPUHistory(interval: 5)
        h.record([ProcessSample(pid: 4, uid: 501, cpu: 90, path: "/a")], at: t0)
        h.record([], at: t0 + 5)
        h.record([ProcessSample(pid: 4, uid: 501, cpu: 0, path: "/b")], at: t0 + 10)
        XCTAssertEqual(h.average(4, over: 60, at: t0 + 10), 0)
    }

    func testSparklineBuckets() {
        let h = CPUHistory(interval: 5)
        for i in 0..<12 { h.record([ProcessSample(pid: 5, uid: 501, cpu: i < 6 ? 0 : 60, path: "/s")], at: t0 + Double(i) * 5) }
        let line = h.sparkline(5, over: 60, buckets: 2, at: t0 + 60)
        XCTAssertEqual(line.count, 2)
        XCTAssertLessThan(line[0], line[1])
    }
}

final class DailyUsageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 36_000 * 100)  // on an hour boundary

    func testCoreSecondsAddUpByPathAcrossPids() {
        let u = DailyUsage(fileURL: nil)
        u.record([], at: t0)
        // Two renderers of one binary at 50% each for one minute, then a restart under a new pid.
        for i in 1...12 {
            u.record([ProcessSample(pid: 10, uid: 501, cpu: 50, path: "/r"), ProcessSample(pid: 11, uid: 501, cpu: 50, path: "/r"),
                      ProcessSample(pid: i < 7 ? 20 : 21, uid: 501, cpu: 25, path: "/w")], at: t0 + Double(i) * 5)
        }
        let rows = u.summaries(at: t0 + 60)
        XCTAssertEqual(rows.map(\.key), ["/r", "/w"])
        XCTAssertEqual(rows[0].coreSeconds, 60, accuracy: 0.01)
        XCTAssertEqual(rows[0].average, 100, accuracy: 0.01)
        XCTAssertEqual(rows[1].average, 25, accuracy: 0.01)
        XCTAssertEqual(rows[0].peak, 50)
        XCTAssertEqual(rows[0].hourly.count, 24)
        XCTAssertEqual(rows[0].hourly.last!, 100, accuracy: 0.01)
    }

    func testSleepGapIsNotCountedAndOldHoursAgeOut() {
        let u = DailyUsage(fileURL: nil)
        u.record([], at: t0)
        u.record([ProcessSample(pid: 1, uid: 501, cpu: 100, path: "/a")], at: t0 + 5)
        // Asleep for two hours: the step is capped.
        u.record([ProcessSample(pid: 1, uid: 501, cpu: 100, path: "/a")], at: t0 + 7205)
        XCTAssertEqual(u.sampled(at: t0 + 7205), 20, accuracy: 0.01)
        u.record([ProcessSample(pid: 1, uid: 501, cpu: 0, path: "/a")], at: t0 + 27 * 3600)
        XCTAssertTrue(u.summaries(at: t0 + 27 * 3600).isEmpty, "a day old usage is gone")
    }

    func testGroupingAndPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let u = DailyUsage(fileURL: url)
        u.record([], at: t0)
        u.record([ProcessSample(pid: 1, uid: 501, cpu: 40, path: "/A.app/Contents/MacOS/A"),
                  ProcessSample(pid: 2, uid: 501, cpu: 60, path: "/A.app/Contents/Helpers/H.app/Contents/MacOS/H")], at: t0 + 5)
        u.save()
        let back = DailyUsage(fileURL: url)
        let rows = back.summaries(at: t0 + 5, group: { AppIdentity.groupKey(of: $0) }, name: { AppIdentity.appName(of: $0) })
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "A")
        XCTAssertEqual(rows[0].coreSeconds, 5, accuracy: 0.01)
    }
}

final class InsightsTests: XCTestCase {
    func input(_ samples: [ProcessSample], total1m: Double = 100, total60m: Double = 100, thermal: Int = 0,
               events: [HistoryEntry] = []) -> InsightInput {
        InsightInput(cores: 10, samples: samples, total1m: total1m, total15m: total60m, total60m: total60m,
                     avg15m: [:], recordedMinutes: 30, daily: [], dailySampled: 0, totalHourly: [], hourStarts: [],
                     events: events, thermal: thermal, lowPower: false)
    }

    func testWindowServerBlamesScreenCapture() {
        let out = Insights.generate(input([ProcessSample(pid: 395, uid: 88, cpu: 42, path: "/x/WindowServer"),
                                           ProcessSample(pid: 7, uid: 501, cpu: 8, path: "/x/SkyComputerUseService")]))
        let ws = out.first { $0.id == "ws-capture" }
        XCTAssertNotNil(ws)
        XCTAssertTrue(ws!.detail.contains("SkyComputerUseService"))
        XCTAssertNotNil(ws!.why)
        XCTAssertFalse(ws!.steps.isEmpty)
        XCTAssertEqual(ws!.related.map(\.sample.name), ["WindowServer", "SkyComputerUseService"])
        XCTAssertNotNil(ws!.related[1].about)
    }

    func testHeatComesFirstAndQuietIsGood() {
        let out = Insights.generate(input([], total1m: 50, thermal: 2))
        XCTAssertEqual(out.first?.id, "thermal")
        XCTAssertTrue(out.contains { $0.id == "quiet" && $0.tone == .good })
    }

    func testUnfamiliarDaemonIsExplainedAndCopiesAddUp() {
        let samples = [ProcessSample(pid: 1, uid: 501, cpu: 90, path: "/x/mediaanalysisd")]
            + (2...5).map { ProcessSample(pid: Int32($0), uid: 501, cpu: 6, path: "/x/claude") }
        let out = Insights.generate(input(samples))
        XCTAssertTrue(out.contains { $0.id == "why-mediaanalysisd" })
        XCTAssertTrue(out.contains { $0.id == "many-claude" && $0.title.hasPrefix("4 claude") })
    }

    func testRepeatOffender() {
        let e = (0..<3).map { _ in HistoryEntry(date: Date(), kind: .flagged, pid: 1, name: "knowledgeconstructiond", path: "/k", cpu: 95, detail: "") }
        XCTAssertTrue(Insights.generate(input([], events: e)).contains { $0.id == "repeat-knowledgeconstructiond" })
    }
}

final class AppIdentityTests: XCTestCase {
    func testOutermostBundle() {
        let r = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(AppIdentity.bundlePath(of: r), "/Applications/Google Chrome.app")
        XCTAssertEqual(AppIdentity.appName(of: r), "Google Chrome")
        XCTAssertNil(AppIdentity.bundlePath(of: "/usr/libexec/PerfPowerServices"))
        XCTAssertEqual(AppIdentity.appName(of: "/usr/libexec/PerfPowerServices"), "PerfPowerServices")
        XCTAssertTrue(AppIdentity.isSystem("/usr/libexec/PerfPowerServices"))
        XCTAssertFalse(AppIdentity.isSystem("/Users/me/.local/bin/claude"))
    }

    func testProtectedOverrideStillRefusesLaunchdAndSelf() {
        XCTAssertEqual(Killer.killProtectedAsAdmin(ProcessSample(pid: 1, uid: 0, cpu: 1, path: "/sbin/launchd")), .refused("launchd cannot be killed"))
        XCTAssertEqual(Killer.killProtectedAsAdmin(ProcessSample(pid: getpid(), uid: getuid(), cpu: 1, path: "/me")), .refused("me cannot be killed"))
        XCTAssertEqual(Killer.sudoCommand(for: ProcessSample(pid: 395, uid: 88, cpu: 1, path: "/x/WindowServer")), "sudo kill -TERM 395")
    }
}
