import XCTest
@testable import SentinelCore

private func ps(_ pid: Int32, _ cpu: Double, _ path: String = "/usr/bin/yes", uid: UInt32 = getuid()) -> ProcessSample {
    ProcessSample(pid: pid, uid: uid, cpu: cpu, path: path)
}

final class ParserTests: XCTestCase {
    func testParsesPathsWithSpacesAndCommaDecimals() {
        let out = """
          13560     0 171,6 /usr/libexec/PerfPowerServices
          18060   501  37.8 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/154.0.8037.95/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
            garbage line
        """
        let s = ProcessSampler.parse(out)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0], ProcessSample(pid: 13560, uid: 0, cpu: 171.6, path: "/usr/libexec/PerfPowerServices"))
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
