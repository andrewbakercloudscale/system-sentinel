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

    /// `minutes` of one-a-second answers; the minutes listed in `lossy` lose 6 pings in 60.
    private func run(minutes: Int, lossy: Set<Int> = [], ms: Double = 10) -> [MTRSample] {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<minutes * 60).map { i in
            MTRSample(at: t0.addingTimeInterval(Double(i)), ms: lossy.contains(i / 60) && i % 60 < 6 ? nil : ms)
        }
    }

    func testWindowsCutTheRunIntoMinutes() {
        let w = MTR.windows(run(minutes: 3, lossy: [1]))
        XCTAssertEqual(w.map(\.sent), [60, 60, 60])
        XCTAssertEqual(w.map(\.lost), [0, 6, 0])
        XCTAssertEqual(w[1].loss, 10)
        XCTAssertEqual(w.map(\.troubled), [false, true, false])
        XCTAssertEqual(MTR.windows(Array(run(minutes: 2).prefix(90))).map(\.sent), [60, 30])
    }

    func testTimelineSaysWhetherTroubleCameAndWent() {
        XCTAssertNil(MTR.timeline(MTR.windows(run(minutes: 1, lossy: [0]))), "one minute has nothing to compare")
        XCTAssertNil(MTR.timeline(MTR.windows(run(minutes: 5))), "nothing went wrong")
        let burst = MTR.timeline(MTR.windows(run(minutes: 5, lossy: [3])))
        XCTAssertEqual(burst?.tone, .warning)
        XCTAssertEqual(burst?.title, "Trouble came and went: 1 of 5 minutes")
        XCTAssertEqual(MTR.timeline(MTR.windows(run(minutes: 3, lossy: [0, 1, 2])))?.tone, .bad)
    }

    func testJitterAloneMarksAMinute() {
        let t0 = Date()
        let spiky = (0..<120).map { MTRSample(at: t0.addingTimeInterval(Double($0)), ms: $0 >= 60 && $0 % 2 == 0 ? 100 : 10) }
        let w = MTR.windows(spiky)
        XCTAssertEqual(w.map(\.troubled), [false, true])
        XCTAssertTrue(MTR.timeline(w)?.detail.contains("varied by 45 ms") ?? false)
    }

    func testTimelineReportListsEveryMinuteAndMarksTheBadOnes() {
        XCTAssertEqual(MTR.timelineReport(MTR.windows(run(minutes: 1))), "")
        let r = MTR.timelineReport(MTR.windows(run(minutes: 3, lossy: [2])))
        XCTAssertEqual(r.components(separatedBy: "\n").filter { $0.hasSuffix("<") }.count, 1)
        XCTAssertTrue(r.contains("Minute by minute"))
    }
}
