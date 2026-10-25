import XCTest
@testable import SentinelCore

final class HangsTests: XCTestCase {
    func testParseWithStateReadsTheStateColumn() {
        let out = "  42   501  12,5  2048     1 U+   /Applications/Foo.app/Contents/MacOS/Foo Helper\n"
        let rows = ProcessSampler.parseWithState(out)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sample.state, "U+")
        XCTAssertEqual(rows[0].sample.cpu, 12.5)
        XCTAssertEqual(rows[0].sample.path, "/Applications/Foo.app/Contents/MacOS/Foo Helper")
    }

    func testWaitReason() {
        func w(_ cpu: Double, _ state: String = "S", disk: Double = 0, net: Double = 0, tight: Bool = false) -> WaitReason? {
            WaitReason.of(cpu: cpu, state: state, diskPerSec: disk, netPerSec: net, memoryTight: tight)
        }
        XCTAssertNil(w(1))
        XCTAssertEqual(w(1, "U"), .disk)
        XCTAssertEqual(w(1, "U", tight: true), .memory)
        XCTAssertEqual(w(120, disk: 50_000_000), .cpu)
        XCTAssertEqual(w(10, disk: 50_000_000), .disk)
        XCTAssertEqual(w(2, net: 1_000_000), .network)
        XCTAssertEqual(w(8), .cpu)
    }

    func testHangTrackerTimesHangsAndDropsShortOnes() {
        let t = HangTracker(minimum: 2)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(t.update(hung: [7: "Foo", 8: "Bar"], at: t0, reason: { "why \($0)" }).isEmpty)
        let ended = t.update(hung: [8: "Bar"], at: t0 + 5, reason: { _ in "later" })
        XCTAssertEqual(ended, [Hang(app: "Foo", start: t0, seconds: 5, reason: "why 7")])
        XCTAssertEqual(t.due(after: 10, at: t0 + 11).map(\.pid), [8])
        XCTAssertTrue(t.due(after: 10, at: t0 + 12).isEmpty, "announced once")
        XCTAssertTrue(t.update(hung: [9: "Baz"], at: t0 + 20, reason: { _ in "" }).count == 1)
        XCTAssertTrue(t.update(hung: [:], at: t0 + 21, reason: { _ in "" }).isEmpty, "a 1 s hang is not kept")
    }
}
