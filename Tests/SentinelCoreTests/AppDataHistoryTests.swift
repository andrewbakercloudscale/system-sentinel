import Testing
import Foundation
@testable import SentinelCore

@Suite struct AppDataHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // on a minute boundary

    @Test func readingsInOneMinuteAddUp() {
        var h = AppDataHistory()
        h.add(["a": ("Chrome", 100, 10)], at: t0)
        h.add(["a": ("Chrome", 50, 5)], at: t0.addingTimeInterval(30))
        #expect(h.minutes.count == 1)
        #expect(h.totals(.download)["a"] == 150)
        #expect(h.totals(.upload)["a"] == 15)
        #expect(h.totals(.both)["a"] == 165)
        #expect(h.slices(10, .both).first?.bytes == 165)
    }

    @Test func topTenAndTheRestAsOther() {
        var h = AppDataHistory()
        var by: [String: (name: String, down: UInt64, up: UInt64)] = [:]
        for i in 1...12 { by["k\(i)"] = ("App \(i)", UInt64(i * 100), 0) }
        h.add(by, at: t0)
        let top = h.top(10, .download)
        #expect(top.count == 10)
        #expect(top.first == "k12")
        let other = h.slices(10, .download).first { $0.key == "other" }
        #expect(other?.bytes == 300)   // k1 and k2
        #expect(h.top(10, .upload).isEmpty)
    }

    @Test func olderThanAnHourIsDropped() {
        var h = AppDataHistory()
        h.add(["a": ("Old", 1, 0)], at: t0)
        h.add(["b": ("New", 1, 0)], at: t0.addingTimeInterval(3601))
        #expect(h.minutes.count == 1)
        #expect(h.names["a"] == nil)
        #expect(h.names["b"] == "New")
    }

    @Test func internetIsTotalLessLocal() {
        var h = AppDataHistory()
        h.add(["a": ("Lima", 1000, 400)], local: ["a": (900, 500)], at: t0)
        #expect(h.totals(.download, .local)["a"] == 900)
        #expect(h.totals(.download, .internet)["a"] == 100)
        #expect(h.totals(.upload, .local)["a"] == 400)     // never more than the total
        #expect(h.totals(.upload, .internet)["a"] == 0)
        #expect(h.top(10, .upload, .internet).isEmpty)
        #expect(h.totals(.both, .all)["a"] == 1400)
    }

    @Test func nettopConnectionsSplitLocalFromInternet() {
        let out = """
        ,bytes_in,bytes_out,
        limactl.812,5000,7000,
        tcp4 127.0.0.1:60022<->127.0.0.1:22,3000,4000,
        tcp4 192.168.5.2:5000<->8.8.8.8:443,2000,3000,
        mDNSResponder.593,60,40,
        udp4 *:5353<->*:*,60,40,
        Chrome.900,10,20,
        tcp6 fd7a:115c::1.443<->2a00:1450::1.443,10,20,
        tcp6 fe80::1%en0.5000<->fe80::2%en0.6000,1,1,
        """
        let l = NetParse.localConnections(out)
        #expect(l[812]?.count == 1)
        #expect(l[812]?.values.first?.bytesOut == 4000)
        #expect(l[593]?.values.first?.bytesIn == 60)
        #expect(l[900]?.count == 1)          // the fe80 one, not the internet one
        let t = NetParse.nettop(out)
        #expect(t.count == 3)
        #expect(t[812]?.bytesIn == 5000)
        #expect(NetParse.isLocalAddress("10.1.2.3") && NetParse.isLocalAddress("100.64.0.1") && NetParse.isLocalAddress("::ffff:192.168.1.1"))
        #expect(!NetParse.isLocalAddress("172.32.0.1") && !NetParse.isLocalAddress("2a00:1450::1") && !NetParse.isLocalAddress("17.57.146.184"))
    }
}
