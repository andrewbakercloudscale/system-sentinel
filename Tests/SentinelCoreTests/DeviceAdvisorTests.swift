import XCTest
@testable import SentinelCore

final class DeviceAdvisorTests: XCTestCase {
    let g: UInt64 = 1 << 30

    func w(busy: Double, need: UInt64, peak: UInt64, pressure: Double = 0, used: UInt64 = 300, growth: Double? = nil,
           kinds: [DeviceAdvisor.Kind] = [], days: Double = 20) -> DeviceAdvisor.Workload {
        DeviceAdvisor.Workload(days: days, cores: 10, memory: 32 * g, disk: 1024 * g, diskUsed: used * g,
                               diskGrowthPerDay: growth, cpuTypical: busy / 3, cpuBusy: busy, cpuPeak: busy * 1.5,
                               memoryNeed: need * g, memoryPeak: peak * g, pressureShare: pressure, batteryShare: 0.4, kinds: kinds)
    }

    func testLightUserGetsAnAirOnBudgetAndAProAsGold() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 1, need: 10, peak: 14)))
        XCTAssertEqual(a.budget.model.name, "MacBook Air 13-inch")
        XCTAssertEqual(a.budget.memoryGB, 16)
        XCTAssertEqual(a.budget.price, 1099)
        XCTAssertEqual(a.gold.model.rung, 1)
        XCTAssertEqual(a.gold.memoryGB, 24)
        XCTAssertEqual(a.verdict.memory, .good)
    }

    /// The case that was over-specced: 32 GB nearly full, rarely low, 4 cores in a busy hour.
    func testThirtyTwoGBThatIsEnoughStaysThirtyTwo() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 3.7, need: 30, peak: 31, pressure: 0.04)))
        XCTAssertEqual(a.budget.model.name, "MacBook Air 13-inch")
        XCTAssertEqual(a.budget.memoryGB, 32)
        XCTAssertEqual(a.gold.model.chip, "M5 Pro")
        XCTAssertEqual(a.gold.memoryGB, 48)
        XCTAssertEqual(a.verdict.memory, .good)
    }

    func testShortOfMemoryStepsUp() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 2, need: 31, peak: 32, pressure: 0.2)))
        XCTAssertEqual(a.budget.model.chip, "M5 Pro")
        XCTAssertEqual(a.budget.memoryGB, 48)
        XCTAssertEqual(a.verdict.memory, .short)
        XCTAssertEqual(a.gold.memoryGB, 64)
    }

    func testVideoWantsFansAndGoldGoesMax() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 2, need: 12, peak: 16, kinds: [.video])))
        XCTAssertEqual(a.budget.model.rung, 1)
        XCTAssertEqual(a.gold.model.chip, "M5 Max")
    }

    func testLargeScreenPicksFifteenAndSixteenInch() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 1, need: 10, peak: 12), large: true))
        XCTAssertEqual(a.budget.model.name, "MacBook Air 15-inch")
        XCTAssertEqual(a.gold.model.name, "MacBook Pro 16-inch")
    }

    func testDiskGrowthSizesTheSSD() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 1, need: 10, peak: 12, used: 600, growth: 2 * Double(g))))
        XCTAssertGreaterThanOrEqual(a.budget.storageGB, 2048)
        XCTAssertNotEqual(a.verdict.disk, .good)
    }

    func testTooLittleHistoryGivesNoAdvice() {
        XCTAssertNil(DeviceAdvisor.advise(w(busy: 1, need: 10, peak: 12, days: 1)))
    }

    func testKindsMatchWholeWords() {
        let k = DeviceAdvisor.kinds(in: [("Final Cut Pro", 0.3), ("Docker Desktop", 0.1), ("Mongo", 0.5), ("Xcode", 0.01)])
        XCTAssertEqual(k[.video], "Final Cut Pro")
        XCTAssertEqual(k[.virtualMachines], "Docker Desktop")
        XCTAssertNil(k[.development])
        XCTAssertEqual(k.count, 2)
    }
}
