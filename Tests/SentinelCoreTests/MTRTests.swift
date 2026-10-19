@testable import SentinelCore
import XCTest

final class MTRTests: XCTestCase {
    private func hop(_ n: Int, _ address: String?, _ results: [Double?]) -> MTRHop {
        var h = MTRHop(n: n, address: address)
        results.forEach { h.record($0) }
        return h
    }

    private func steady(_ ms: Double, lost: Int = 0, of sent: Int = 20) -> [Double?] {
        (0..<sent).map { $0 < lost ? nil : ms }
    }

    func testParsesPingTime() {
        XCTAssertEqual(MTR.pingMS("64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=4.625 ms"), 4.625)
        XCTAssertEqual(MTR.pingMS("16 bytes from ::1, icmp_seq=0 hlim=64 time<1 ms"), 1)
        XCTAssertNil(MTR.pingMS("Request timeout for icmp_seq 0"))
    }

    func testStatistics() {
        let h = hop(1, "192.168.0.1", [10, nil, 20, 30])
        XCTAssertEqual(h.sent, 4)
        XCTAssertEqual(h.loss, 25)
        XCTAssertEqual(h.average, 20)
        XCTAssertEqual(h.best, 10)
        XCTAssertEqual(h.worst, 30)
        XCTAssertEqual(h.last, 30)
        XCTAssertEqual(h.jitter ?? 0, 8.165, accuracy: 0.01)
    }

    func testTrailingSilentHopsAreTrimmedToOne() {
        let trace = [Hop(n: 1, address: "192.168.0.1", ms: 2), Hop(n: 2, address: nil, ms: nil),
                     Hop(n: 3, address: "41.71.48.65", ms: 4), Hop(n: 4, address: nil, ms: nil),
                     Hop(n: 5, address: nil, ms: nil), Hop(n: 6, address: nil, ms: nil)]
        XCTAssertEqual(MTR.hops(from: trace).map(\.n), [1, 2, 3, 4])
    }

    func testLossAtOneRouterOnlyIsNotAProblem() {
        let hops = [hop(1, "192.168.0.1", steady(2)), hop(2, "41.71.48.65", steady(4, lost: 8)), hop(3, "1.1.1.1", steady(5))]
        let v = MTR.verdict(hops)
        XCTAssertEqual(v?.tone, .good)
        XCTAssertTrue(v?.detail.contains("Hop 2") ?? false)
    }

    func testLossCarriedToTheEndIsPlacedWhereItStarts() {
        let hops = [hop(1, "192.168.0.1", steady(2)), hop(2, "41.71.48.65", steady(4, lost: 4)),
                    hop(3, "41.71.65.153", steady(4, lost: 3)), hop(4, "1.1.1.1", steady(5, lost: 4))]
        let v = MTR.verdict(hops, isPrivate: { $0.hasPrefix("192.168.") })
        XCTAssertEqual(v?.tone, .bad)
        XCTAssertEqual(v?.title, "20% of packets lost, starting at hop 2")
        XCTAssertTrue(v?.detail.contains("outside your network") ?? false)
    }

    func testLossFromTheRouterIsLocal() {
        let hops = [hop(1, "192.168.0.1", steady(2, lost: 2)), hop(2, "1.1.1.1", steady(5, lost: 2))]
        let v = MTR.verdict(hops, isPrivate: { $0.hasPrefix("192.168.") })
        XCTAssertEqual(v?.tone, .bad)
        XCTAssertTrue(v?.detail.contains("inside your own network") ?? false)
    }

    func testDelayJumpThatLastsIsNamed() {
        let hops = [hop(1, "192.168.0.1", steady(2)), hop(2, "41.71.48.65", steady(5)),
                    hop(3, "4.68.1.1", steady(160)), hop(4, "8.8.8.8", steady(165))]
        XCTAssertEqual(MTR.verdict(hops)?.title, "Delay jumps by 155 ms at hop 3")
    }

    func testNeedsAFewRoundsAndReportsASilentTarget() {
        XCTAssertNil(MTR.verdict([hop(1, "1.1.1.1", steady(5, of: 3))]))
        XCTAssertEqual(MTR.verdict([hop(1, "192.168.0.1", steady(2)), hop(2, "1.1.1.1", steady(5, lost: 20))])?.tone, .bad)
    }

    func testReportHasEveryHop() {
        let r = MTR.report(target: "one.one.one.one", address: "1.1.1.1",
                           hops: [hop(1, "192.168.0.1", steady(2)), hop(2, nil, []), hop(3, "1.1.1.1", steady(5))],
                           owners: ["1.1.1.1": NetOwner(asn: 13335, prefix: "1.1.1.0/24", country: "US", name: "CLOUDFLARENET")],
                           at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(r.contains("one.one.one.one (1.1.1.1)"))
        XCTAssertTrue(r.contains("???"))
        XCTAssertTrue(r.contains("AS13335 CLOUDFLARENET"))
    }
}
