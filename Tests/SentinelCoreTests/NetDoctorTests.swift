import XCTest
@testable import SentinelCore

final class NetDoctorTests: XCTestCase {
    func testResolvers() {
        let r = NetParse.resolvers("""
        DNS configuration

        resolver #1
          search domain[0] : corp.example
          nameserver[0] : 100.64.0.1
          nameserver[1] : 100.64.0.2
          flags    : Supplemental, Request A records
          order    : 102600

        resolver #2
          nameserver[0] : 1.1.1.1
          if_index : 11 (en0)
          flags    : Request A records

        resolver #3
          domain   : int.corp
          nameserver[0] : 100.64.0.1
          flags    : Supplemental, Request A records

        resolver #4
          domain   : local
          options  : mdns

        DNS configuration (for scoped queries)

        resolver #1
          nameserver[0] : 9.9.9.9
        """)
        XCTAssertEqual(r.count, 4, "the scoped section repeats them")
        XCTAssertEqual(r[0].searchDomains, ["corp.example"])
        XCTAssertEqual(r[0].servers, ["100.64.0.1", "100.64.0.2"])
        XCTAssertTrue(r[0].supplemental)
        XCTAssertFalse(r[1].supplemental)
        XCTAssertEqual(r[2].domain, "int.corp")
        XCTAssertTrue(r[3].mdns)
    }

    func testDig() {
        let ok = NetParse.dig("""
        ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 4242
        ;; ANSWER SECTION:
        www.apple.com.		300	IN	CNAME	www.apple.com.edgekey.net.
        e6858.dsce9.akamaiedge.net. 17	IN	A	23.207.31.180

        ;; Query time: 11 msec
        ;; SERVER: 100.64.0.1#53(100.64.0.1)
        """)
        XCTAssertEqual(ok, DigResult(status: "NOERROR", ms: 11, addresses: ["23.207.31.180"]))
        let nx = NetParse.dig(";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n;; Query time: 30 msec\n")
        XCTAssertEqual(nx?.status, "NXDOMAIN")
        XCTAssertTrue(nx?.addresses.isEmpty ?? false)
        XCTAssertNil(NetParse.dig(";; connection timed out; no servers could be reached\n"))
    }

    func testHosts() {
        let h = NetParse.hosts("""
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost
        127.0.0.1 api.anthropic.com
        10.0.0.5  jira.corp git.corp # old server
        """)
        XCTAssertEqual(h, [HostsEntry(address: "127.0.0.1", names: ["api.anthropic.com"]),
                           HostsEntry(address: "10.0.0.5", names: ["jira.corp", "git.corp"])])
    }

    func testFailedLookupsAreListedNewestFirst() {
        var h = DNSHistory()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        h.record(ok: false, ms: 6012, at: t, keep: 86_400)
        h.record(ok: true, ms: 20, at: t + 60, keep: 86_400)
        h.record(ok: false, ms: 3, at: t + 120, keep: 86_400)
        let f = h.failed(since: t - 1)
        XCTAssertEqual(f.map(\.ms), [3, 6012])
        let lines = DNSHistory.describe(f)
        XCTAssertTrue(lines[0].hasSuffix("failed after 3 ms"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("no answer after 6.0 s (timed out)"), lines[1])
        XCTAssertEqual(DNSHistory.describe(f, limit: 1).last, "and 1 earlier")
    }

    func testFailedLookupNamesWhatEachServerSaid() {
        var h = DNSHistory()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let servers = [NetParse.serverLine("192.168.1.1", DigResult(status: "NXDOMAIN", ms: 12, addresses: [])),
                       NetParse.serverLine("1.1.1.1", nil),
                       NetParse.serverLine("8.8.8.8", DigResult(status: "NOERROR", ms: 20, addresses: ["17.253.144.10"]))]
        h.record(ok: false, ms: 40, at: t, servers: servers, offline: false)
        XCTAssertEqual(servers, ["192.168.1.1: NXDOMAIN in 12 ms", "1.1.1.1: no answer", "8.8.8.8: answered in 20 ms"])
        let line = DNSHistory.describe(h.failed(since: t - 1))[0]
        XCTAssertTrue(line.hasSuffix("failed after 40 ms. Servers: 192.168.1.1: NXDOMAIN in 12 ms; 1.1.1.1: no answer; 8.8.8.8: answered in 20 ms"), line)
        h.record(ok: false, ms: 6000, at: t + 60, offline: true)
        XCTAssertTrue(DNSHistory.describe(h.failed(since: t - 1))[0].contains("network was down, not DNS"))
        // Old saved history without the new fields still loads.
        let old = Data(#"{"points":[{"t":1,"ok":false}]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DNSHistory.self, from: old).points.first?.servers, nil)
        XCTAssertEqual(NetParse.mainServers([Resolver(servers: ["a", "b"]), Resolver(domain: "corp", servers: ["c"], supplemental: true), Resolver(servers: ["a"])]), ["a", "b"])
    }

    func testDNSHistory() {
        var h = DNSHistory()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        h.record(ok: true, ms: 20, at: t0)
        h.record(ok: false, ms: nil, at: t0.addingTimeInterval(3600))
        h.record(ok: true, ms: 1500, at: t0.addingTimeInterval(7200))
        XCTAssertEqual(h.failures(since: t0), 1)
        XCTAssertEqual(h.slow(since: t0), 1)
        let hours = h.hours(at: t0.addingTimeInterval(7201))
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours.last?.slow, 1)
        XCTAssertEqual(hours[hours.count - 2].failed, 1)
        h.record(ok: true, ms: 10, at: t0.addingTimeInterval(90_000), keep: 86_400)
        XCTAssertEqual(h.points.count, 3, "the first, now over a day old, drops out")
        XCTAssertEqual(h.points.first?.ok, false)
        let back = try? JSONDecoder().decode(DNSHistory.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back, h)
    }

    func testSpeedResult() throws {
        let json = """
        {"base_rtt": 26.5, "dl_throughput": 178744144, "ul_throughput": 139696672, "dl_responsiveness": 460.8,
         "ul_responsiveness": 150.2, "interface_name": "en0", "other": {"proxy_state": {"not_proxied": 465}}}
        """
        let s = try XCTUnwrap(SpeedResult.parse(Data(json.utf8), at: Date()))
        XCTAssertEqual(SpeedResult.mbps(s.down), "178 Mbit/s")
        XCTAssertEqual(s.rpm, 150.2, "the worse direction")
        XCTAssertEqual(s.responsiveness, .low)
        XCTAssertEqual(Int(s.loadedDelay ?? 0), 399)
        XCTAssertFalse(s.proxied)
        let proxied = try XCTUnwrap(SpeedResult.parse(Data(#"{"dl_throughput": 1, "ul_throughput": 1, "other": {"proxy_state": {"proxied": 3}}}"#.utf8), at: Date()))
        XCTAssertTrue(proxied.proxied)
        XCTAssertNil(SpeedResult.parse(Data("{}".utf8), at: Date()))
    }

    func testToolTrust() {
        let pem = "/Users/me/ca.pem"
        let none = ToolTrust.scan(files: [:], gitCA: nil, pem: pem)
        XCTAssertTrue(none.allSatisfy { !$0.configured })
        XCTAssertEqual(none.first { $0.tool == "git" }?.how, "git config --global http.sslCAInfo \"/Users/me/ca.pem\"")
        let some = ToolTrust.scan(files: ["/Users/me/.zshrc": "# export REQUESTS_CA_BUNDLE=x\nexport NODE_EXTRA_CA_CERTS=/x.pem\n",
                                          "/Users/me/.npmrc": "registry=https://r\n",
                                          "/Users/me/.config/pip/pip.conf": "[global]\ncert = /x.pem\n"],
                                  gitCA: "/x.pem\n", pem: pem)
        func on(_ t: String) -> Bool { some.first { $0.tool == t }?.configured ?? false }
        XCTAssertTrue(on("Node.js and npm"))
        XCTAssertTrue(on("Python (requests, pip)"), "pip.conf counts")
        XCTAssertTrue(on("git"))
        XCTAssertFalse(on("curl and OpenSSL tools"), "a commented-out line does not count")
        XCTAssertEqual(some.first { $0.tool == "Node.js and npm" }?.how, "set in .zshrc")
    }

    func testHotspotWatch() {
        var w = HotspotWatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(w.update(onHotspot: false, rx: 5_000, tx: 5_000, at: t0), [])
        XCTAssertEqual(w.update(onHotspot: true, rx: 10_000, tx: 10_000, at: t0), [.joined])
        XCTAssertEqual(w.update(onHotspot: true, rx: 50_010_000, tx: 10_000, at: t0.addingTimeInterval(60)), [])
        XCTAssertEqual(w.used, 50_000_000)
        XCTAssertEqual(w.update(onHotspot: true, rx: 600_010_000, tx: 10_000, at: t0.addingTimeInterval(120)), [.used(500_000_000)],
                       "two milestones at once say the bigger one")
        XCTAssertEqual(w.update(onHotspot: true, rx: 700_010_000, tx: 10_000, at: t0.addingTimeInterval(180)), [])
        XCTAssertEqual(w.update(onHotspot: true, rx: 1_100_010_000, tx: 10_000, at: t0.addingTimeInterval(240)), [.used(1_000_000_000)])
        XCTAssertEqual(w.update(onHotspot: false, rx: 1_100_010_000, tx: 10_000, at: t0.addingTimeInterval(600)),
                       [.left(used: 1_100_000_000, minutes: 10)])
        XCTAssertFalse(w.on)
        XCTAssertEqual(w.update(onHotspot: true, rx: 2_000_000_000, tx: 0, at: t0.addingTimeInterval(700)), [.joined], "a new spell counts from zero")
        XCTAssertEqual(w.used, 0)
    }

    func testDoctorInsights() {
        let now = Date()
        var d = DNSReport(at: now)
        d.captive = true
        d.madeUp = ["92.242.132.24"]
        d.servers = [.init(address: "100.64.0.1", domain: nil, ms: nil, status: nil),
                     .init(address: "1.1.1.1", domain: nil, ms: 12, status: "NOERROR"),
                     .init(address: "100.64.0.9", domain: "int.corp", ms: nil, status: nil)]
        d.workHost = "jira.int.corp"
        d.workResolved = false
        d.hosts = [HostsEntry(address: "10.0.0.5", names: ["git.corp"]), HostsEntry(address: "127.0.0.1", names: ["api.anthropic.com"])]
        var history = DNSHistory()
        for i in 0..<12 { history.record(ok: false, ms: nil, at: now.addingTimeInterval(Double(-i * 60))) }
        let speed = SpeedResult(down: 5_000_000, up: 1_000_000, rpmDown: 120, rpmUp: 90, idleRTT: 25, proxied: false, interface: "en0", at: now)
        let inspection = TLSInspection(host: "github.com", root: "Zscaler Root CA", rootIsSystem: false)
        let tools = ToolTrust.scan(files: [:], gitCA: nil, pem: "/x.pem")
        let list = NetworkAnalysis.doctorInsights(dns: d, history: history, speed: speed, inspection: inspection, tools: tools,
                                                  link: NetworkLink(interface: "en0", gateway: "172.20.10.1"),
                                                  hotspotUsed: 600_000_000, hotspotSince: now.addingTimeInterval(-1800),
                                                  hotspotApps: [("Dropbox", 400_000_000, [12]), ("Mail", 1_000, [13])], at: now)
        let ids = list.map(\.id)
        for id in ["net-captive", "net-dns-madeup", "net-dns-first", "net-dns-split", "net-dns-work", "net-hosts",
                   "net-dns-flaky", "net-bufferbloat", "net-slowline", "net-inspection", "net-hotspot"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let hosts = list.first { $0.id == "net-hosts" }!
        XCTAssertTrue(hosts.title.contains("git.corp") && !hosts.title.contains("anthropic"), "loopback redirects are left out")
        let hotspot = list.first { $0.id == "net-hotspot" }!
        XCTAssertEqual(hotspot.tone, .warning)
        XCTAssertTrue(hotspot.detail.contains("Dropbox") && !hotspot.detail.contains("Mail"))
        XCTAssertEqual(hotspot.fixes.first, .leaveHotspot)
        XCTAssertEqual(list.first { $0.id == "net-inspection" }?.tone, .warning, "tools not set up")

        // All well: nothing to say.
        var good = DNSReport(at: now)
        good.servers = [.init(address: "1.1.1.1", domain: nil, ms: 10, status: "NOERROR")]
        let fine = SpeedResult(down: 200_000_000, up: 100_000_000, rpmDown: 1200, rpmUp: 900, idleRTT: 20, proxied: false, interface: "en0", at: now)
        XCTAssertTrue(NetworkAnalysis.doctorInsights(dns: good, history: DNSHistory(), speed: fine,
                                                     inspection: TLSInspection(host: "github.com", root: "ISRG Root X1", rootIsSystem: true),
                                                     tools: [], link: NetworkLink(interface: "en0"), hotspotUsed: nil, hotspotSince: nil,
                                                     hotspotApps: [], at: now).isEmpty)
    }
}
