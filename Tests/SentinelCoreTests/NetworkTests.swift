import XCTest
@testable import SentinelCore

final class NetworkTests: XCTestCase {
    // Real `netstat -anv` lines, trimmed of the trailing columns that are not read.
    let tcp = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options
    tcp4       0    377  192.168.0.90.57004     17.253.111.203.443     ESTABLISHED       402866        21713  131072  131404  softwareupdated:8008   00102 00020000
    tcp4       0      0  127.0.0.1.57039        127.0.0.1.17777        SYN_SENT               0            0  131072  131072             curl:1200   00104 00000008
    tcp4       0      0  172.20.10.2.64745      17.253.111.203.80      CLOSE_WAIT          4512          248  131072  131412           trustd:406    00122 00020000
    tcp4       0      0  192.168.0.90.60000     142.251.155.119.443    ESTABLISHED         9000         4000  131072  131404  Google Chrome He:8224   00102 00020000
    tcp4       0      0  *.22                   *.*                    LISTEN                 0            0  131072  131072           launchd:1      00102 00020000
    """
    let udp = """
    Proto Recv-Q Send-Q  Local Address          Foreign Address        rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options
    udp4       0      0  192.168.0.90.49592     142.251.155.119.443     17196         6588 1048576   29040 Google Chrome He:8224   00102 00000000
    """

    func testParsesNetstat() {
        let c = NetParse.netstat(tcp)
        XCTAssertEqual(c.count, 4, "LISTEN lines are left out")
        XCTAssertEqual(c[0].remoteHost, "17.253.111.203")
        XCTAssertEqual(c[0].remotePort, 443)
        XCTAssertEqual(c[0].rx, 402866)
        XCTAssertEqual(c[0].tx, 21713)
        XCTAssertEqual(c[0].pid, 8008)
        XCTAssertEqual(c[0].process, "softwareupdated")
        XCTAssertTrue(c[1].isLocal)
        XCTAssertFalse(c[2].isOpen, "CLOSE_WAIT is finished")
        XCTAssertEqual(c[3].process, "Google Chrome He", "names with spaces")
        XCTAssertEqual(c[3].pid, 8224)
        let u = NetParse.netstat(udp)
        XCTAssertEqual(u.first?.proto, .udp)
        XCTAssertEqual(u.first?.rx, 17196)
        XCTAssertEqual(u.first?.pid, 8224)
    }

    func testParsesNettopInItsColumnOrder() {
        let t = NetParse.nettop("""
        ,packets_in,bytes_in,packets_out,bytes_out,
        launchd.1,0,0,0,0,
        apsd.364,2278,3244954,4038,4394383,
        Google Chrome H.8224,10,5000,4,600,
        """)
        XCTAssertEqual(t[364]?.bytesIn, 3244954)
        XCTAssertEqual(t[364]?.bytesOut, 4394383)
        XCTAssertEqual(t[364]?.packetsIn, 2278)
        XCTAssertEqual(t[8224]?.name, "Google Chrome H")
        XCTAssertEqual(t[8224]?.packetsOut, 4)
    }

    func testDNSServers() {
        XCTAssertEqual(NetParse.dnsServers("""
        resolver #1
          nameserver[0] : 100.64.0.1
          nameserver[1] : 100.64.0.2
        resolver #2
          nameserver[0] : 1.1.1.1
          nameserver[1] : 100.64.0.1
        """), ["100.64.0.1", "100.64.0.2", "1.1.1.1"])
    }

    private func conn(_ local: String, _ host: String, _ port: Int = 443, _ state: String = "ESTABLISHED",
                      rx: UInt64 = 0, tx: UInt64 = 0, pid: Int32 = 10, name: String = "app") -> NetConn {
        NetConn(proto: .tcp, local: local, remoteHost: host, remotePort: port, state: state, rx: rx, tx: tx, pid: pid, process: name)
    }

    func testShortTLSSessionsAreCaught() {
        let t = ConnectionTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        t.update([], at: t0)
        // Opens and is gone 3 s later with 2 KB received: a failed handshake.
        t.update([conn("a.1", "9.9.9.9", rx: 2000, tx: 517)], at: t0.addingTimeInterval(3))
        t.update([], at: t0.addingTimeInterval(6))
        // Opened and closed between two samples: first seen already in TIME_WAIT.
        t.update([conn("a.2", "9.9.9.9", 443, "TIME_WAIT", rx: 1500, tx: 517)], at: t0.addingTimeInterval(9))
        // A healthy one: lives long and receives plenty.
        t.update([conn("a.3", "8.8.8.8", rx: 500_000)], at: t0.addingTimeInterval(12))
        t.update([conn("a.3", "8.8.8.8", rx: 900_000)], at: t0.addingTimeInterval(60))
        t.update([], at: t0.addingTimeInterval(63))
        // A reachability probe: connects and closes, sends nothing. Not a handshake.
        t.update([conn("a.5", "1.1.1.1", 443, "TIME_WAIT")], at: t0.addingTimeInterval(64))
        // Plain HTTP that drops is not TLS.
        t.update([conn("a.4", "7.7.7.7", 80, rx: 10)], at: t0.addingTimeInterval(66))
        t.update([], at: t0.addingTimeInterval(69))
        let short = t.events.filter { $0.kind == .shortTLS }
        XCTAssertEqual(short.map(\.host), ["9.9.9.9", "9.9.9.9"])
        let grouped = ConnectionProblem.group(t.events, since: t0)
        XCTAssertEqual(grouped.first?.count, 2)
        XCTAssertEqual(grouped.first?.host, "9.9.9.9")
    }

    func testUnansweredConnects() {
        let t = ConnectionTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        t.update([conn("b.1", "10.0.0.5", 8443, "SYN_SENT")], at: t0)
        t.update([conn("b.1", "10.0.0.5", 8443, "SYN_SENT")], at: t0.addingTimeInterval(3))
        XCTAssertTrue(t.events.isEmpty, "not yet: under 5 s")
        t.update([conn("b.1", "10.0.0.5", 8443, "SYN_SENT")], at: t0.addingTimeInterval(6))
        t.update([conn("b.1", "10.0.0.5", 8443, "SYN_SENT")], at: t0.addingTimeInterval(9))
        XCTAssertEqual(t.events.map(\.kind), [.noAnswer], "reported once")
    }

    func testFlowsCountOnlyNewBytes() {
        let t = ConnectionTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_020)
        t.update([conn("c.1", "5.5.5.5", rx: 1000, tx: 100)], at: t0)
        t.update([conn("c.1", "5.5.5.5", rx: 4000, tx: 300)], at: t0.addingTimeInterval(3))
        t.update([conn("c.1", "5.5.5.5", rx: 4000, tx: 300), conn("c.2", "5.5.5.5", rx: 500, tx: 0)], at: t0.addingTimeInterval(6))
        let f = t.flows(since: t0.addingTimeInterval(-60))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f.first?.rx, 4500)
        XCTAssertEqual(f.first?.tx, 300)
        XCTAssertEqual(t.open.count, 2)
    }

    func testThroughput() {
        var tp = Throughput(keep: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        tp.record(rx: 1_000, tx: 1_000, at: t0)
        XCTAssertNil(tp.latest, "needs two readings")
        tp.record(rx: 31_000, tx: 4_000, at: t0.addingTimeInterval(3))
        XCTAssertEqual(tp.latest?.down, 10_000)
        XCTAssertEqual(tp.latest?.up, 1_000)
        tp.record(rx: 10, tx: 10, at: t0.addingTimeInterval(6))
        XCTAssertEqual(tp.points.count, 1, "a counter reset gives no reading")
        tp.record(rx: 3_010, tx: 10, at: t0.addingTimeInterval(100))
        XCTAssertEqual(tp.points.count, 1, "old readings drop out")
    }

    func testInterfaceCountersRead() {
        let c = InterfaceCounters.read()
        XCTAssertNotNil(c["lo0"], "loopback is always there")
    }

    func testWiFiQuality() {
        XCTAssertEqual(WiFiInfo(rssi: -50, noise: -95, txRate: 800).quality, .excellent)
        XCTAssertEqual(WiFiInfo(rssi: -65, noise: -92, txRate: 400).quality, .good)
        XCTAssertEqual(WiFiInfo(rssi: -72, noise: -90, txRate: 100).quality, .fair)
        XCTAssertEqual(WiFiInfo(rssi: -80, noise: -90, txRate: 20).quality, .poor)
        XCTAssertEqual(WiFiInfo(rssi: -60, noise: -70, txRate: 100).quality, .poor, "strong signal, but drowned in noise")
    }

    func testLinkKind() {
        XCTAssertEqual(NetworkLink().kind, "Offline")
        XCTAssertEqual(NetworkLink(interface: "en0", gateway: "172.20.10.1").kind, "Personal Hotspot")
        XCTAssertEqual(NetworkLink(interface: "en0", wifi: WiFiInfo(rssi: -50, noise: -90, txRate: 300)).kind, "Wi-Fi")
        XCTAssertEqual(NetworkLink(interface: "en5").kind, "Ethernet")
        XCTAssertEqual(NetworkLink.vpn(processNames: ["Finder", "ZscalerTunnel"]), "Zscaler")
        XCTAssertNil(NetworkLink.vpn(processNames: ["Finder"]))
        XCTAssertEqual(NetworkLink.vpn(processNames: ["nesessionmanager", "ZscalerTunnel"]), "Zscaler", "the named client, not the generic service")
    }

    func testInsights() {
        let now = Date()
        let wifi = NetworkLink(interface: "en0", gateway: "192.168.0.1", wifi: WiFiInfo(rssi: -82, noise: -90, txRate: 24, channel: 6, band: 2.4))
        let problem = ConnectionProblem(kind: .shortTLS, process: "Slack", pids: [42], host: "slack.com", port: 443, count: 40, last: now)
        let apps = [NetworkAnalysis.AppRow(key: "falcon", name: "CrowdStrike", pids: [7], down: 0, up: 2_000_000,
                                           totalIn: 1 << 20, totalOut: 5 << 30, connections: 4)]
        let health = LinkHealth(routerMs: 80, routerLoss: 10, internetMs: 120, internetLoss: 10, dnsMs: 40, at: now)
        let ids = NetworkAnalysis.insights(link: wifi, health: health, problems: [problem], apps: apps, at: now).map(\.id)
        XCTAssertTrue(ids.contains("net-wifi-weak"))
        XCTAssertTrue(ids.contains("net-wifi-24"))
        XCTAssertTrue(ids.contains("net-wifi-rate"))
        XCTAssertTrue(ids.contains("net-router"), "a bad router link is blamed on the room, not the internet")
        XCTAssertFalse(ids.contains("net-internet"))
        XCTAssertTrue(ids.contains("net-tls-Slack"))
        XCTAssertTrue(ids.contains("net-uploading"))
        XCTAssertTrue(ids.contains("net-bigsender"))

        // Failures against several hosts by one app make one insight that names them.
        let many = ["1.1.1.1", "8.8.8.8", "9.9.9.9"].map {
            ConnectionProblem(kind: .shortTLS, process: "burst", pids: [9], host: $0, port: 443, count: 9, last: now)
        }
        let tls = NetworkAnalysis.insights(link: NetworkLink(interface: "en5"), health: nil, problems: many, apps: [], at: now)
        XCTAssertEqual(tls.map(\.id), ["net-tls-burst"])
        XCTAssertTrue(tls[0].title.hasSuffix("3 hosts"))
        XCTAssertTrue(tls[0].detail.contains("27 secure connections"))

        // A healthy router but slow internet behind a VPN points at the VPN.
        let vpn = NetworkLink(interface: "en0", gateway: "192.168.0.1", vpn: "Zscaler")
        let slow = LinkHealth(routerMs: 3, routerLoss: 0, internetMs: 220, internetLoss: 0, dnsMs: 20, at: now)
        let i = NetworkAnalysis.insights(link: vpn, health: slow, problems: [], apps: [], at: now)
        XCTAssertEqual(i.map(\.id), ["net-internet"])
        XCTAssertTrue(i[0].detail.contains("Zscaler"))

        XCTAssertEqual(NetworkAnalysis.insights(link: NetworkLink(), health: nil, problems: [], apps: [], at: now).map(\.id), ["net-offline"])
    }

    func testPathMTU() {
        // A VPN that lets 1400-byte packets through, payload 1372.
        var tries = 0
        let p = PathMTU.find(interfaceMTU: 1500) { tries += 1; return $0 <= 1372 }
        XCTAssertEqual(p, 1400)
        XCTAssertLessThanOrEqual(tries, 9, "a binary search, not a scan")
        XCTAssertEqual(PathMTU.find(interfaceMTU: 1500) { _ in true }, 1500)
        XCTAssertNil(PathMTU.find(interfaceMTU: 1500) { _ in false })

        let now = Date()
        let h = LinkHealth(routerMs: 2, routerLoss: 0, internetMs: 20, internetLoss: 0, dnsMs: 20, pathMTU: 1380, interfaceMTU: 1500, at: now)
        XCTAssertTrue(h.fragments)
        let i = NetworkAnalysis.insights(link: NetworkLink(interface: "en0", vpn: "Zscaler"), health: h, problems: [], apps: [], at: now)
        XCTAssertEqual(i.map(\.id), ["net-mtu"])
        XCTAssertEqual(i[0].tone, .warning, "under 1400 hurts")
        XCTAssertTrue(i[0].detail.contains("Zscaler"))
        let fine = LinkHealth(pathMTU: 1500, interfaceMTU: 1500, at: now)
        XCTAssertFalse(fine.fragments)
    }

    func testZeroTrust() {
        XCTAssertEqual(NetworkLink.vpn(processNames: ["tailscaled", "ZscalerTunnel"]), "Zscaler", "the zero trust client wins")
        XCTAssertTrue(NetworkLink(interface: "en0", vpn: "Zscaler").zeroTrust)
        XCTAssertFalse(NetworkLink(interface: "en0", vpn: "Tailscale").zeroTrust)
        XCTAssertFalse(NetworkLink(interface: "en0").zeroTrust)

        let now = Date()
        let ztn = NetworkLink(interface: "en0", gateway: "192.168.0.1", vpn: "Zscaler")
        let tcp = LinkHealth(routerMs: 4, routerLoss: 0, internetMs: 30, internetLoss: 0, dnsMs: 20, icmpBlocked: true, at: now)
        let i = NetworkAnalysis.insights(link: ztn, health: tcp, problems: [], apps: [], at: now)
        XCTAssertEqual(i.map(\.id), ["net-ztn"], "pings blocked but TCP fine is not an outage")
        XCTAssertEqual(i[0].tone, .info)
        XCTAssertTrue(i[0].title.contains("Zscaler"))

        let down = LinkHealth(routerMs: 4, routerLoss: 0, internetLoss: 100, at: now)
        let d = NetworkAnalysis.insights(link: ztn, health: down, problems: [], apps: [], at: now)
        XCTAssertEqual(d.first?.id, "net-down")
        XCTAssertTrue(d.first?.detail.contains("Zscaler is connected") ?? false)
    }

    func testTCPPing() throws {
        // A listening socket on loopback answers the handshake without accept().
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && Darwin.listen(fd, 8) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        try XCTSkipUnless(bound, "no loopback socket")
        let port = UInt16(bigEndian: addr.sin_port)
        let r = TCPPing.ping("127.0.0.1", port: port, count: 3, interval: 0)
        XCTAssertEqual(r.loss, 0)
        XCTAssertLessThan(r.avg ?? 999, 100)
        close(fd)
        XCTAssertNil(TCPPing.handshake("127.0.0.1", port: port, timeout: 1), "refused once nothing listens")
        XCTAssertNil(TCPPing.handshake("not-an-ip"))
    }
}
