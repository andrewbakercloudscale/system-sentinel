import XCTest
@testable import SentinelCore

final class NetDrawTests: XCTestCase {
    func testNetDrawOnlyWhenPluggedInAndBatteryGivingPower() {
        var b = PowerReader.parse(registry: ["ExternalConnected": true, "IsCharging": true,
                                               "PowerTelemetryData": ["BatteryPower": NSNumber(value: Int64(-8900))]],
                                    source: [:], lowPowerMode: false)
        XCTAssertEqual(b.netDraw ?? 0, 8.9, accuracy: 0.01)
        b.batteryWatts = 12
        XCTAssertNil(b.netDraw)
        b.batteryWatts = -5; b.onBattery = true
        XCTAssertNil(b.netDraw)
    }
}
