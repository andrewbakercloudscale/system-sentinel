import XCTest
@testable import SentinelCore

final class RestartPolicyTests: XCTestCase {
    func testAllowsThreeRestartsInTenMinutes() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(RestartPolicy.allows(past: [], now: now))
        XCTAssertTrue(RestartPolicy.allows(past: [now - 60, now - 120], now: now))
        XCTAssertFalse(RestartPolicy.allows(past: [now - 60, now - 120, now - 300], now: now))
    }

    func testOldRestartsDoNotCount() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(RestartPolicy.allows(past: [now - 700, now - 900, now - 60, now - 30], now: now))
        XCTAssertEqual(RestartPolicy.recent([now - 700, now - 30], now: now), [now - 30])
    }
}

final class RootKillTests: XCTestCase {
    func testRootKillChecksStartTime() {
        XCTAssertEqual(Killer.rootKill(42, signal: "TERM", stamp: "Sun Nov 15 09:14:02 2026"),
                       #"[ "$(echo $(LC_ALL=C /bin/ps -o lstart= -p 42))" = "Sun Nov 15 09:14:02 2026" ] && /bin/kill -TERM 42"#)
        XCTAssertNil(Killer.rootKill(42, signal: "HUP", stamp: "x"))
        // A real process: its own stamp matches, so the command would run.
        let me = ProcessInfo.processInfo.processIdentifier
        let cmd = Killer.rootKill(me, signal: "TERM")
        XCTAssertNotNil(cmd)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd!.replacingOccurrences(of: " && /bin/kill -TERM \(me)", with: "")]
        try? p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, cmd!)
    }
}
