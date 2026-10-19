import XCTest
@testable import SentinelCore

final class CPUBudgetTests: XCTestCase {
    func testBudget() {
        var b = CPUBudget(limit: 10, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        b.record(seconds: 0, at: t0)
        XCTAssertNil(b.usage(at: t0), "one point is no rate")
        XCTAssertFalse(b.over(at: t0))
        // 3 s of CPU over 60 s: 5% of a core.
        for i in 1...12 { b.record(seconds: Double(i) * 0.25, at: t0.addingTimeInterval(Double(i) * 5)) }
        XCTAssertEqual(b.usage(at: t0.addingTimeInterval(60)) ?? 0, 5, accuracy: 0.01)
        XCTAssertFalse(b.over(at: t0.addingTimeInterval(60)))
        // A burst: 30 s of CPU in the next 20 s.
        b.record(seconds: 33, at: t0.addingTimeInterval(80))
        XCTAssertTrue(b.over(at: t0.addingTimeInterval(80)))
        // A quiet minute later it is back under.
        for i in 1...12 { b.record(seconds: 33 + Double(i) * 0.05, at: t0.addingTimeInterval(80 + Double(i) * 5)) }
        XCTAssertFalse(b.over(at: t0.addingTimeInterval(140)))
    }
}
