import XCTest
@testable import SentinelCore

final class DNSMapTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(DNSMap.normalize("https://Jira.Example.com:8443/browse/X-1"), "jira.example.com")
        XCTAssertEqual(DNSMap.normalize("  user@git.corp:22 "), "git.corp")
        XCTAssertEqual(DNSMap.normalize("github.com."), "github.com")
        XCTAssertEqual(DNSMap.normalize("[2606:4700::1111]:443"), "2606:4700::1111")
        XCTAssertEqual(DNSMap.normalize("2606:4700::1111"), "2606:4700::1111")
        XCTAssertNil(DNSMap.normalize("not a host"))
        XCTAssertNil(DNSMap.normalize(""))
    }

    func testAddresses() {
        XCTAssertTrue(DNSMap.isIP("10.0.0.1") && DNSMap.isIP("::1") && !DNSMap.isIP("github.com"))
        for p in ["10.1.2.3", "172.20.0.1", "192.168.1.1", "100.64.0.1", "127.0.0.1", "169.254.3.4", "fd00::1", "fe80::1", "::1"] {
            XCTAssertTrue(DNSMap.isPrivate(p), p)
        }
        for p in ["172.32.0.1", "100.128.0.1", "20.87.245.0", "2606:4700::1111"] { XCTAssertFalse(DNSMap.isPrivate(p), p) }
        XCTAssertEqual(DNSMap.cymruQuery("20.87.245.0"), "0.245.87.20.origin.asn.cymru.com")
        XCTAssertEqual(DNSMap.cymruQuery("2606:4700:4700::1111"),
                       "1.1.1.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.7.4.0.0.7.4.6.0.6.2.origin6.asn.cymru.com")
    }

    func testCymru() {
        XCTAssertEqual(NetParse.cymruOrigin("\"8075 | 20.64.0.0/10 | US | arin | 2017-10-18\"\n"),
                       NetOwner(asn: 8075, prefix: "20.64.0.0/10", country: "US"))
        XCTAssertEqual(NetParse.cymruOrigin("\"13335 209242 | 1.1.1.0/24 | AU | apnic | 2011-08-11\"")?.asn, 13335)
        XCTAssertNil(NetParse.cymruOrigin(""))
        XCTAssertEqual(NetParse.cymruName("\"8075 | US | arin | 1997-03-31 | MICROSOFT-CORP-MSN-AS-BLOCK - Microsoft Corporation, US\""), "Microsoft Corporation")
        XCTAssertEqual(NetParse.cymruName("\"13335 | US | arin | 2010-07-14 | CLOUDFLARENET, US\""), "CLOUDFLARENET")
    }

    func testRecordsAndChain() {
        let full = """
        ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
        ;; QUESTION SECTION:
        ;www.github.com.			IN	A

        ;; ANSWER SECTION:
        www.github.com.		3600	IN	CNAME	github.com.
        github.com.		60	IN	A	20.87.245.0

        ;; AUTHORITY SECTION:
        github.com.		900	IN	NS	dns1.p08.nsone.net.
        """
        let r = NetParse.records(full)
        XCTAssertEqual(r, [DNSRecord(name: "www.github.com", ttl: 3600, type: "CNAME", value: "github.com"),
                           DNSRecord(name: "github.com", ttl: 60, type: "A", value: "20.87.245.0")], "authority section left out")
        XCTAssertEqual(DNSMap.chain(r, from: "www.github.com"), ["www.github.com", "github.com"])
        XCTAssertEqual(NetParse.records(";; ->>HEADER<<- status: NXDOMAIN\n;; AUTHORITY SECTION:\n.\t\t5760\tIN\tSOA\ta.root-servers.net. x. 1 2 3 4 5\n"), [],
                       "no answer section: the authority's SOA is not a record of the name")
        let short = NetParse.records("github.com.\t\t3600\tIN\tCAA\t0 issue \"digicert.com\"\n")
        XCTAssertEqual(short.first?.value, "0 issue \"digicert.com\"")
        XCTAssertEqual(DNSMap.serial("dns1.p08.nsone.net. hostmaster.nsone.net. 1656468023 43200 7200 1209600 3600"), 1656468023)
        XCTAssertEqual(DNSMap.ttl(60), "60 s")
        XCTAssertEqual(DNSMap.ttl(3600), "60 min")
        XCTAssertEqual(DNSMap.ttl(172_800), "2 days")
    }

    func testTrace() {
        let s = """
        .			99792	IN	NS	a.root-servers.net.
        ;; Received 239 bytes from 100.64.0.1#53(100.64.0.1) in 11 ms

        com.			172800	IN	NS	a.gtld-servers.net.
        ;; Received 839 bytes from 192.5.5.241#53(f.root-servers.net) in 8 ms

        github.com.		172800	IN	NS	ns-520.awsdns-01.net.
        github.com.		172800	IN	NS	dns1.p08.nsone.net.
        ;; Received 310 bytes from 192.35.51.30#53(f.gtld-servers.net) in 167 ms

        www.github.com.		3600	IN	CNAME	github.com.
        github.com.		60	IN	A	20.87.245.0
        github.com.		900	IN	NS	dns1.p08.nsone.net.
        ;; Received 296 bytes from 205.251.198.171#53(ns-1707.awsdns-21.co.uk) in 24 ms
        """
        let t = NetParse.digTrace(s)
        XCTAssertEqual(t.count, 4)
        XCTAssertEqual(t[1].server, "f.root-servers.net")
        XCTAssertEqual(t[1].address, "192.5.5.241")
        XCTAssertEqual(t[1].zone, "com")
        XCTAssertEqual(t[2].nameServers, ["ns-520.awsdns-01.net", "dns1.p08.nsone.net"])
        XCTAssertEqual(t[2].ms, 167)
        XCTAssertFalse(t[2].isAnswer)
        XCTAssertTrue(t[3].isAnswer)
        XCTAssertFalse(t[3].isNoName)
        let none = NetParse.digTrace(".\t86400\tIN\tSOA\ta.root-servers.net. x. 1 2 3 4 5\n;; Received 1 bytes from 202.12.27.33#53(m.root-servers.net) in 165 ms\n")
        XCTAssertTrue(none.first?.isNoName ?? false)
    }

    func testTraceroute() {
        let hops = NetParse.traceroute("""
        traceroute to 20.87.245.0 (20.87.245.0), 20 hops max, 40 byte packets
         1  172.20.0.1  9.612 ms
         2  *
         3  51.10.18.184  23.777 ms
         4  *
         5  *
        """)
        XCTAssertEqual(hops.count, 5)
        XCTAssertEqual(hops[0], Hop(n: 1, address: "172.20.0.1", ms: 9.612))
        XCTAssertNil(hops[1].address)
        var route = DNSMapResult.Route(label: "x", address: "20.87.245.0")
        route.hops = hops
        XCTAssertEqual(route.shown.hops.count, 3)
        XCTAssertEqual(route.shown.silent, 2)
        XCTAssertFalse(route.reached)
    }

    func testResolverChoice() {
        let rs = [Resolver(servers: ["100.64.0.1"], searchDomains: ["corp.example"], supplemental: true),
                  Resolver(servers: ["192.168.1.1", "1.1.1.1"]),
                  Resolver(domain: "corp.example", servers: ["100.64.0.1"], supplemental: true),
                  Resolver(domain: "int.corp.example", servers: ["100.64.0.9"], supplemental: true)]
        XCTAssertEqual(DNSMap.resolver(for: "jira.int.corp.example", in: rs).0?.servers, ["100.64.0.9"], "the most specific domain")
        XCTAssertEqual(DNSMap.resolver(for: "wiki.corp.example", in: rs).0?.domain, "corp.example")
        let main = DNSMap.resolver(for: "github.com", in: rs)
        XCTAssertEqual(main.0?.servers.first, "192.168.1.1")
        XCTAssertTrue(main.1.contains("then 1.1.1.1"))
        XCTAssertNil(DNSMap.resolver(for: "printer.local", in: rs).0)
    }

    func testFindings() {
        var r = DNSMapResult(query: "jira.corp", at: Date())
        r.system = ["10.0.0.5"]
        r.systemMs = 12
        r.status = "NOERROR"
        r.answers = [.init(server: "100.64.0.1", scope: "VPN", status: "NOERROR", ms: 10, addresses: ["10.0.0.5"], cnames: []),
                     .init(server: "1.1.1.1", scope: "main", status: "NXDOMAIN", ms: 9, addresses: [], cnames: []),
                     .init(server: "8.8.8.8", scope: "main", status: nil, ms: nil, addresses: [], cnames: [])]
        var t = DNSMapResult.Target(address: "10.0.0.5")
        t.ports = [443: -1, 80: -1]
        r.targets = [t]
        var f = DNSMap.findings(r)
        XCTAssertEqual(f.first?.tone, .problem, "nothing accepts connections")
        XCTAssertTrue(f.contains { $0.text.contains("disagree") })
        XCTAssertTrue(f.contains { $0.text.contains("8.8.8.8 did not answer") })
        XCTAssertTrue(f.contains { $0.text.contains("internal address") })

        // Two providers with their own serials, same answer: a note, not a warning.
        var g = DNSMapResult(query: "github.com", at: Date())
        g.system = ["20.87.245.0"]
        g.status = "NOERROR"
        g.authorities = [.init(name: "a", address: "1.1.1.1", status: "NOERROR", ms: 5, serial: 1, addresses: ["20.87.245.0"]),
                         .init(name: "b", address: "2.2.2.2", status: "NOERROR", ms: 5, serial: 99, addresses: ["20.87.245.0"])]
        f = DNSMap.findings(g)
        XCTAssertTrue(f.allSatisfy { $0.tone >= .note })
        XCTAssertEqual(f.first?.tone, .ok)
        g.authorities[1].addresses = ["1.2.3.4"]
        XCTAssertTrue(DNSMap.findings(g).contains { $0.tone == .warning && $0.text.contains("different answers") })

        var n = DNSMapResult(query: "nope.example", at: Date())
        n.status = "NXDOMAIN"
        n.system = []
        XCTAssertEqual(DNSMap.findings(n).first?.tone, .problem)
        XCTAssertTrue(DNSMap.report(n).contains("NXDOMAIN"))
    }

    func testDoHAndRoute() {
        let cf = #"{"Status":0,"Answer":[{"name":"www.github.com","type":5,"TTL":2148,"data":"github.com."},{"name":"github.com","type":1,"TTL":60,"data":"20.87.245.0"}]}"#
        let d = NetParse.dohJSON(Data(cf.utf8))
        XCTAssertEqual(d?.status, "NOERROR")
        XCTAssertEqual(d?.addresses, ["20.87.245.0"])
        XCTAssertEqual(d?.cnames, ["github.com"])
        XCTAssertEqual(NetParse.dohJSON(Data(#"{"Status":3,"Authority":[]}"#.utf8))?.status, "NXDOMAIN")
        XCTAssertNil(NetParse.dohJSON(Data("<html>blocked</html>".utf8)))
        let r = NetParse.routeGet("   route to: 100.64.0.1\ndestination: 100.64.0.1\n    gateway: 100.64.0.1\n  interface: utun4\n")
        XCTAssertEqual(r.interface, "utun4")
        XCTAssertEqual(r.gateway, "100.64.0.1")
        XCTAssertTrue(DNSMap.isTunnelInterface("utun4") && !DNSMap.isTunnelInterface("en0") && !DNSMap.isTunnelInterface(nil))
    }

    func testZscalerAndTunnels() {
        let direct = "<p>The request received from you didn't come from a Zscaler IP therefore you are not going through the Zscaler proxy service.</p><p>Your request is arriving at this server from the IP address 197.103.133.125</p>"
        XCTAssertEqual(NetParse.zscalerPage(direct), ZscalerPath(throughProxy: false, publicIP: "197.103.133.125"))
        let proxied = "You are accessing this host via a Zscaler BETA proxy hostname: zs2-jnb1-2b5.gateway.zscalertwo.net. Your request is arriving at this server from the IP address 165.225.73.10 The Zscaler proxy virtual IP is 165.225.72.38."
        let z = NetParse.zscalerPage(proxied)
        XCTAssertEqual(z?.throughProxy, true)
        XCTAssertEqual(z?.proxyHost, "zs2-jnb1-2b5.gateway.zscalertwo.net")
        XCTAssertEqual(z?.proxyIP, "165.225.72.38")
        XCTAssertNil(NetParse.zscalerPage("<html>some other page</html>"))

        func conn(_ host: String, _ process: String, state: String = "ESTABLISHED") -> NetConn {
            NetConn(proto: .tcp, local: "172.20.13.62.60662", remoteHost: host, remotePort: 443, state: state, rx: 1, tx: 1, pid: 1, process: process)
        }
        let t = DNSMap.tunnels([conn("147.161.163.253", "ZscalerTunnel"), conn("147.161.163.253", "ZscalerTunnel"),
                                conn("147.161.170.1", "ZscalerService"), conn("10.0.0.1", "ZscalerTunnel"),
                                conn("140.82.121.4", "Safari"), conn("2.2.2.2", "ZscalerTunnel", state: "TIME_WAIT")])
        XCTAssertEqual(t, [Tunnel(vendor: "Zscaler", process: "ZscalerTunnel", edges: ["147.161.163.253", "147.161.170.1"])])
    }

    func testDoHFindings() {
        func answer(_ server: String, _ status: String?, _ addrs: [String], https: Bool = false) -> DNSMapResult.ServerAnswer {
            .init(server: server, scope: https ? "over HTTPS" : "main", status: status, ms: 10, addresses: addrs, cnames: [], viaHTTPS: https)
        }
        var r = DNSMapResult(query: "blocked.example", at: Date())
        r.status = "NXDOMAIN"
        r.system = []
        r.answers = [answer("192.168.1.1", "NXDOMAIN", []), answer("Cloudflare", "NOERROR", ["93.184.216.34"], https: true)]
        XCTAssertTrue(DNSMap.findings(r).contains { $0.tone == .warning && $0.text.contains("hiding it") })
        XCTAssertFalse(DNSMap.findings(r).contains { $0.text.contains("disagree") }, "DNS over HTTPS is compared on its own")

        r = DNSMapResult(query: "jira.corp", at: Date())
        r.status = "NOERROR"
        r.system = ["10.0.0.5"]
        r.answers = [answer("100.64.0.1", "NOERROR", ["10.0.0.5"]), answer("Cloudflare", "NXDOMAIN", [], https: true)]
        XCTAssertTrue(DNSMap.findings(r).contains { $0.text.contains("internal name") })

        r.answers = [answer("100.64.0.1", "NOERROR", ["10.0.0.5"]), answer("Cloudflare", nil, [], https: true), answer("Google", nil, [], https: true)]
        let f = DNSMap.findings(r)
        XCTAssertTrue(f.contains { $0.text.contains("blocked on this network") })
        XCTAssertFalse(f.contains { $0.text.contains("did not answer") })

        var route = DNSMapResult.Route(label: "x", address: "10.0.0.5")
        route.tunnel = "Zscaler"
        r.routes = [route]
        r.tunnels = [Tunnel(vendor: "Zscaler", process: "ZscalerTunnel", edges: ["147.161.163.253"])]
        r.zscaler = ZscalerPath(throughProxy: false, publicIP: "197.103.133.125")
        let g = DNSMap.findings(r)
        XCTAssertTrue(g.contains { $0.text.contains("Zscaler tunnel") && $0.text.contains("147.161.163.253") })
        XCTAssertTrue(g.contains { $0.text.contains("not through Zscaler's proxy") })
        XCTAssertTrue(DNSMap.report(r).contains("inside the Zscaler tunnel"))
    }
}
