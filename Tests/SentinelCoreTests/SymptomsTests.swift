@testable import SentinelCore
import XCTest

final class SymptomsTests: XCTestCase {
    private let gb: UInt64 = 1 << 30

    func testAQuietMacFindsNothingAndEverySymptomStillAnswers() {
        var v = Vitals()
        v.battery = BatteryStatus(onBattery: true, percent: 80, watts: 6, maxCapacity: 95, designCapacity: 100)
        v.disk = DiskSpace(total: 500 * gb, free: 200 * gb, available: 200 * gb)
        v.privacy = []
        v.bluetooth = BluetoothState(on: true, connected: ["AirPods"])
        XCTAssertTrue(Diagnose.found(v).isEmpty)
        for s in Symptom.allCases {
            let c = Diagnose.checks(s, v)
            XCTAssertFalse(c.isEmpty, "\(s) gave no answer")
            XCTAssertTrue(c.allSatisfy { $0.status <= .info }, "\(s) flagged something on a quiet Mac")
        }
    }

    func testHotAndBusyIsFoundOnItsOwnWithQuitButtons() {
        var v = Vitals()
        v.thermal = 2
        v.cpuBusy = 90
        v.busyApps = [AppLoad(name: "Chrome", amount: 400, pids: [1, 2]), AppLoad(name: "Slack", amount: 50, pids: [3])]
        let found = Diagnose.found(v)
        XCTAssertEqual(found.first?.symptom, .slow)
        XCTAssertEqual(found.first?.check.status, .problem)
        let checks = Diagnose.checks(.slow, v)
        XCTAssertEqual(checks.first?.status, .problem, "worst first")
        XCTAssertTrue(checks.contains { $0.actions.contains(.quit(pids: [1, 2], name: "Chrome")) })
    }

    func testLowDiskThresholds() {
        var v = Vitals()
        v.disk = DiskSpace(total: 500 * gb, free: 3 * gb, available: 3 * gb)
        XCTAssertEqual(Diagnose.checks(.disk, v).first?.status, .problem)
        v.disk = DiskSpace(total: 500 * gb, free: 15 * gb, available: 15 * gb)
        XCTAssertEqual(Diagnose.checks(.disk, v).first?.status, .warning)
        XCTAssertEqual(Diagnose.checks(.disk, v).first?.actions, [.goTo(tab: "Storage", card: "cleanups", label: "Free up space")])
    }

    func testBatteryWearAndFastDrain() {
        var v = Vitals()
        v.battery = BatteryStatus(onBattery: true, percent: 50, watts: 28, maxCapacity: 70, designCapacity: 100)
        v.energyApps = [AppLoad(name: "Zoom", amount: 80, pids: [9])]
        let c = Diagnose.checks(.battery, v)
        XCTAssertEqual(c.first?.status, .problem)
        XCTAssertTrue(c.contains { $0.title.contains("70%") })
        XCTAssertTrue(c.contains { $0.actions.contains(.quit(pids: [9], name: "Zoom")) })
        v.battery = BatteryStatus(present: false)
        XCTAssertEqual(Diagnose.checks(.battery, v).map(\.status), [.info])
    }

    func testRefusedPermissionsAreInfoNotAlarms() {
        var v = Vitals()
        v.privacy = [PrivacyGrant(service: "Microphone", bundleID: "com.microsoft.teams2", name: "Teams", allowed: false),
                     PrivacyGrant(service: "Camera", bundleID: "us.zoom.xos", name: "zoom.us", allowed: true)]
        XCTAssertTrue(Diagnose.found(v).isEmpty, "a refusal may be on purpose")
        let c = Diagnose.checks(.micCamera, v)
        XCTAssertEqual(c.first?.fixes.first, .run(label: "Reset Teams's microphone permission", path: "/usr/bin/tccutil", args: ["reset", "Microphone", "com.microsoft.teams2"]))
        v.privacy = nil
        XCTAssertTrue(Diagnose.checks(.micCamera, v)[0].title.contains("Cannot see"))
    }

    func testBlockedAppOffersToAllowIt() {
        var v = Vitals()
        v.blockedApps = [BlockedApp(name: "Tool", path: "/Applications/Tool.app")]
        let c = Diagnose.checks(.appWontOpen, v)
        XCTAssertEqual(c[0].status, .warning)
        XCTAssertEqual(c[0].fixes.first, .run(label: "Allow Tool to open", path: "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "/Applications/Tool.app"]))
    }

    func testSleepBlockersNameTheApp() {
        var v = Vitals()
        v.blockers = SleepBlockers.parse([42: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "Playing audio", "Process Name": "Music"]]])
        let c = Diagnose.checks(.sleep, v)
        XCTAssertEqual(c.first?.status, .warning)
        XCTAssertTrue(c.first?.title.hasPrefix("Music") ?? false, c.first?.title ?? "")
    }

    func testMacOSHoldingItselfAwakeIsNotAWarning() {
        var v = Vitals()
        v.blockers = SleepBlockers.parse([90: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "x", "Process Name": "powerd"]],
                                          91: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "y", "Process Name": "runningboardd"]]])
        XCTAssertEqual(Diagnose.checks(.sleep, v).first?.status, .ok)
        v.blockers = SleepBlockers.parse([92: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "z", "Process Name": "caffeinate",
                                                "Details": "caffeinate asserting on behalf of 'claude' (pid 61739)"]]])
        let c = Diagnose.checks(.sleep, v)
        XCTAssertEqual(c.first?.actions, [.quit(pids: [61739], name: "claude")])
    }

    func testParsesPrivacyRows() {
        let out = "kTCCServiceMicrophone|us.zoom.xos|2\nkTCCServiceCamera|com.microsoft.teams2|0\nkTCCServiceMicrophone|/usr/local/bin/tool|2\nkTCCServiceAccessibility|x|2\n"
        let g = SymptomParse.privacy(out) { $0 == "us.zoom.xos" ? "zoom.us" : $0 }
        XCTAssertEqual(g, [PrivacyGrant(service: "Microphone", bundleID: "us.zoom.xos", name: "zoom.us", allowed: true),
                           PrivacyGrant(service: "Camera", bundleID: "com.microsoft.teams2", name: "com.microsoft.teams2", allowed: false)])
    }

    func testQuarantineApproval() {
        XCTAssertFalse(SymptomParse.approved("0083;65f1c2a0;Safari;"))
        XCTAssertTrue(SymptomParse.approved("00c3;65f1c2a0;Safari;"))
        XCTAssertTrue(SymptomParse.rejected("/Applications/X.app: rejected\nsource=Unnotarized Developer ID"))
        XCTAssertFalse(SymptomParse.rejected("/Applications/X.app: accepted\nsource=Notarized Developer ID"))
    }

    func testParsesBluetooth() {
        let json = #"{"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},"device_connected":[{"Magic Mouse":{}},{"AirPods Pro":{}}]}]}"#
        XCTAssertEqual(SymptomParse.bluetooth(Data(json.utf8)), BluetoothState(on: true, connected: ["AirPods Pro", "Magic Mouse"]))
        let off = #"{"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_off"}}]}"#
        XCTAssertEqual(SymptomParse.bluetooth(Data(off.utf8))?.on, false)
    }

    func testParsesThunderboltDevices() {
        let json = #"{"SPThunderboltDataType":[{"_name":"bus0","device_name_key":"MacBook Air","receptacle_1_tag":{}},{"_name":"bus1","device_name_key":"MacBook Air","_items":[{"device_name_key":"TS4","vendor_name_key":"CalDigit","_items":[{"device_name_key":"Studio Display","vendor_name_key":"Apple Inc."}]}]}]}"#
        XCTAssertEqual(SymptomParse.thunderbolt(Data(json.utf8)), ["CalDigit TS4", "Apple Inc. Studio Display"])
    }

    func testDisplayChecks() {
        let json = #"{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_name":"Color LCD","_spdisplays_pixels":"2880 x 1864","_spdisplays_resolution":"1440 x 932 @ 60.00Hz","spdisplays_connection_type":"spdisplays_internal","spdisplays_pixelresolution":"spdisplays_2880x1864Retina"},{"_name":"LG 4K","_spdisplays_pixels":"1920 x 1080","_spdisplays_resolution":"1920 x 1080 @ 30.00Hz","spdisplays_pixelresolution":"3840 x 2160"}]}]}"#
        var v = Vitals()
        v.displaySetup = DisplaySetup(displays: DisplayPixels.parse(Data(json.utf8)), devices: [], chip: "Apple M2")
        let c = Diagnose.checks(.display, v)
        XCTAssertEqual(c.map(\.status), [.warning, .warning, .info])
        XCTAssertTrue(c[0].title.contains("30 Hz"))
        XCTAssertTrue(c[1].title.contains("full resolution"))
        XCTAssertTrue(c[2].title.contains("only one external"))
        v.displaySetup = DisplaySetup(displays: [], devices: ["CalDigit TS4"], chip: "Apple M4")
        let none = Diagnose.checks(.display, v)
        XCTAssertEqual(none.first?.title, "No external display found")
        XCTAssertEqual(none.first?.items, ["Plugged in: CalDigit TS4"])
    }

    func testExplainsPanics() {
        XCTAssertEqual(SymptomParse.panic("panic(cpu 2 caller 0x1): userspace watchdog timeout: no successful checkins from WindowServer"),
                       "The Mac stopped responding for minutes and the watchdog restarted it.")
        let usb = "panic(cpu 0 caller 0x2): IOThunderboltController\nKernel Extensions in backtrace:\n   com.apple.iokit.IOThunderboltFamily(1.0)\n   com.displaylink.driver.DisplayLinkDriver(5.2.1)\n"
        let s = SymptomParse.panic(usb) ?? ""
        XCTAssertTrue(s.hasPrefix("A USB or Thunderbolt device"), s)
        XCTAssertTrue(s.contains("com.displaylink.driver.DisplayLinkDriver"), s)
        XCTAssertFalse(s.contains("com.apple"), s)
        XCTAssertNil(SymptomParse.panic("nothing to see"))
    }

    func testIgnoringABlockerHidesOnlyThoseApps() {
        var v = Vitals()
        v.blockers = SleepBlockers.parse([92: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "z", "Process Name": "caffeinate",
                                                "Details": "caffeinate asserting on behalf of 'claude' (pid 61739)"]]])
        let c = Diagnose.found(v)[0].check
        XCTAssertEqual(c.ignoreFor, .infinity)
        XCTAssertTrue(Diagnose.found(v, ignoring: [c.ignoreKey]).isEmpty)
        v.blockers += SleepBlockers.parse([93: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "x", "Process Name": "Zoom"]]])
        XCTAssertEqual(Diagnose.found(v, ignoring: [c.ignoreKey]).count, 1, "another app keeping it awake still shows")
    }

    func testIgnoringAPassingStateLastsADay() {
        var v = Vitals()
        v.thermal = 2
        let c = Diagnose.found(v)[0].check
        XCTAssertNil(c.subject)
        XCTAssertEqual(c.ignoreFor, 86_400)
    }
}
