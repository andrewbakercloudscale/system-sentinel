import XCTest
@testable import SentinelCore

final class CheckupTests: XCTestCase {
    func testSecurityToolOutput() {
        XCTAssertEqual(CheckParse.fileVaultOn("FileVault is On."), true)
        XCTAssertEqual(CheckParse.fileVaultOn("FileVault is Off."), false)
        XCTAssertEqual(CheckParse.firewallOn("Firewall is disabled. (State = 0)"), false)
        XCTAssertEqual(CheckParse.firewallOn("Firewall is enabled. (State = 1)"), true)
        XCTAssertEqual(CheckParse.stealthOn("Firewall stealth mode is off"), false)
        XCTAssertEqual(CheckParse.gatekeeperOn("assessments enabled"), true)
        XCTAssertEqual(CheckParse.sipOn("System Integrity Protection status: enabled."), true)
        XCTAssertEqual(CheckParse.sipOn("System Integrity Protection status: disabled."), false)
    }

    func testPendingUpdates() {
        let s = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: macOS Tahoe 26.6-25G40
        \tTitle: macOS Tahoe 26.6, Version: 26.6, Size: 2048000KiB, Recommended: YES, Action: restart,
        * Label: Safari26.1
        \tTitle: Safari, Version: 26.1, Size: 200000KiB, Recommended: YES,
        """
        XCTAssertEqual(CheckParse.pendingUpdates(s), ["macOS Tahoe 26.6", "Safari"])
        XCTAssertEqual(CheckParse.pendingUpdates("No new software available."), [])
    }

    let netstat = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options
    tcp4       0      0  127.0.0.1.631          *.*                    LISTEN                 0            0  131072  131072            cupsd:23481  00080 00000006
    tcp46      0      0  *.22                   *.*                    LISTEN                 0            0  131072  131072            launchd:1    00100 00000006
    tcp46      0      0  *.59188                *.*                    LISTEN                 0            0  131072  131072         rapportd:771    00100 00000006
    tcp4       0      0  192.168.1.5.50123      93.184.216.34.80       ESTABLISHED       100          200  131072  131072  com.docker.backend:812    00100 00000006
    tcp4       0      0  192.168.1.5.50124      17.253.1.1.443         ESTABLISHED       100          200  131072  131072           Safari:900    00100 00000006
    """

    func testListenersAndClearText() {
        let l = CheckParse.listeners(netstat)
        XCTAssertEqual(l.count, 3)
        XCTAssertEqual(l.first { $0.port == 631 }?.exposed, false)
        XCTAssertEqual(l.first { $0.port == 22 }?.exposed, true)
        XCTAssertEqual(l.first { $0.port == 22 }?.process, "launchd")
        let c = CheckParse.clearText(netstat)
        XCTAssertEqual(c, [CheckParse.Connection(process: "com.docker.backend", remote: "93.184.216.34", port: 80)])
    }

    func testRiskHeuristics() {
        XCTAssertEqual(CheckParse.remoteTool("/Applications/AnyDesk.app/Contents/MacOS/AnyDesk"), "AnyDesk")
        XCTAssertNil(CheckParse.remoteTool("/Applications/Safari.app/Contents/MacOS/Safari"))
        let home = "/Users/a"
        XCTAssertTrue(CheckParse.oddLocation("/tmp/x", home: home))
        XCTAssertTrue(CheckParse.oddLocation("/Users/a/Downloads/run", home: home))
        XCTAssertTrue(CheckParse.oddLocation("/Users/a/.hidden/agent", home: home))
        XCTAssertFalse(CheckParse.oddLocation("/Users/a/.cargo/bin/rg", home: home))
        XCTAssertFalse(CheckParse.oddLocation("/Applications/X.app/Contents/MacOS/X", home: home))
        XCTAssertEqual(CheckParse.weakTransport(["NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true]]), "allows unencrypted HTTP to any site")
        XCTAssertEqual(CheckParse.weakTransport(["NSAppTransportSecurity": ["NSExceptionDomains": ["old.example.com": ["NSExceptionMinimumTLSVersion": "TLSv1.0"]]]]),
                       "accepts TLS 1.0/1.1 for old.example.com")
        XCTAssertNil(CheckParse.weakTransport([:]))
        XCTAssertEqual(CheckParse.launchItem(["Label": "x", "ProgramArguments": ["/bin/a", "-b"]]).program, "/bin/a")
    }

    func testNetworkAndSystemParsers() {
        let ping = """
        5 packets transmitted, 4 packets received, 20.0% packet loss
        round-trip min/avg/max/stddev = 10.1/12.5/20.3/3.2 ms
        """
        XCTAssertEqual(CheckParse.ping(ping)?.loss, 20)
        XCTAssertEqual(CheckParse.ping(ping)?.avg, 12.5)
        XCTAssertEqual(CheckParse.ping("2 packets transmitted, 0 packets received, 100.0% packet loss")?.loss, 100)
        let route = "   route to: default\ndestination: default\n    gateway: 192.168.1.1\n  interface: en0\n"
        XCTAssertEqual(CheckParse.defaultRoute(route).gateway, "192.168.1.1")
        XCTAssertEqual(CheckParse.defaultRoute(route).interface, "en0")
        XCTAssertEqual(CheckParse.mtu("en0: flags=8863<UP,BROADCAST> mtu 1500\n\tether 00:00"), 1500)
        XCTAssertEqual(CheckParse.clockOffset("+0.012345 +/- 0.010 time.apple.com 17.253.1.1"), 0.012345)
        XCTAssertEqual(CheckParse.spotlightOn("/:\n\tIndexing enabled. "), true)
        let d = CheckParse.backupDate("/Volumes/Backup/Backups.backupdb/Mac/2026-10-17-093012")
        XCTAssertNotNil(d)
        let now = Date()
        let c = CheckParse.crashCounts([("Slack-2026-10-18-110706.ips", now), ("Slack-2026-10-17-110706.ips", now),
                                        ("panic-full-2026-10-17-110706.ips", now), ("Old-2025-01-01-000000.ips", now.addingTimeInterval(-90 * 86_400))],
                                       since: now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(c.first?.process, "Slack")
        XCTAssertEqual(c.first?.count, 2)
        XCTAssertEqual(c.count, 1)
    }
}
