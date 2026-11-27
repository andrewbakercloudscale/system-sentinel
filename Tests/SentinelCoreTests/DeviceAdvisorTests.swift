import XCTest
@testable import SentinelCore

final class DeviceAdvisorTests: XCTestCase {
    let g: UInt64 = 1 << 30

    func w(busy: Double, need: UInt64, peak: UInt64, pressure: Double = 0, used: UInt64 = 300, growth: Double? = nil,
           profiles: [DeviceAdvisor.Profile] = [], gpu: Double? = nil, days: Double = 20, ram: UInt64 = 32) -> DeviceAdvisor.Workload {
        DeviceAdvisor.Workload(days: days, cores: 10, memory: ram * g, disk: 1024 * g, diskUsed: used * g,
                               diskGrowthPerDay: growth, cpuTypical: busy / 3, cpuBusy: busy, cpuPeak: busy * 1.5,
                               memoryNeed: need * g, memoryPeak: peak * g, pressureShare: pressure,
                               gpuTypical: gpu.map { $0 / 3 }, gpuBusy: gpu, gpuPeak: gpu, gpuHours: 100,
                               profiles: profiles.map { .init(profile: $0, share: 1 / Double(profiles.count), apps: []) })
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
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 2, need: 12, peak: 16, profiles: [.video])))
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

    func testLightWorkInEightGBGetsTheNeoAndGoldIsAnAir() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 1, need: 6, peak: 7, used: 150, ram: 8)))
        XCTAssertEqual(a.budget.model.name, "MacBook Neo")
        XCTAssertEqual(a.budget.price, 599)
        XCTAssertEqual(a.gold.model.name, "MacBook Air 13-inch")
        XCTAssertEqual(a.gold.memoryGB, 24)
    }

    func testEightGBNeoThatRunsShortGetsAnAir() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 1.5, need: 7, peak: 8, pressure: 0.3, used: 200, ram: 8)))
        XCTAssertEqual(a.budget.model.name, "MacBook Air 13-inch")
        XCTAssertEqual(a.budget.memoryGB, 16)
        XCTAssertEqual(a.verdict.memory, .short)
    }

    func testBusyGraphicsChipWantsTheProChipAndGoldGoesMax() throws {
        let a = try XCTUnwrap(DeviceAdvisor.advise(w(busy: 2, need: 12, peak: 16, gpu: 55)))
        XCTAssertEqual(a.budget.model.chip, "M5 Pro")
        XCTAssertEqual(a.gold.model.chip, "M5 Max")
        XCTAssertEqual(a.verdict.gpu, .tight)
    }

    func testProfilesMatchWholeWordsAndRankByShare() {
        let p = DeviceAdvisor.profiles(in: [("Xcode", 0.3), ("Google Chrome", 0.2), ("Cursor", 0.1), ("Mongo", 0.3),
                                            ("Wireshark", 0.05), ("Microsoft Teams", 0.01), ("WindowServer", 0.2)])
        XCTAssertEqual(p.first?.profile, .software)
        XCTAssertEqual(p.first?.apps, ["Xcode", "Cursor"])
        XCTAssertEqual(p.map(\.profile), [.software, .browser, .cyber])   // Teams under 3% of matched work
        XCTAssertEqual(p.first?.share ?? 0, 0.4 / 0.66, accuracy: 0.001)
        XCTAssertNil(DeviceAdvisor.profile(of: "Xcodebuild helper"))
        XCTAssertEqual(DeviceAdvisor.profile(of: "python3 train.py"), .data)
    }
}
