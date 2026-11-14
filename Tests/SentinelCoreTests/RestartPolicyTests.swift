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
