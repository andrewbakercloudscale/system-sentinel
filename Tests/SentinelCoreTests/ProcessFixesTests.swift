import XCTest
@testable import SentinelCore

final class ProcessFixesTests: XCTestCase {
    func testSpecificFirstThenLevers() {
        let f = ProcessFixes.fixes(for: "mds_stores", app: nil, canLower: true)
        XCTAssertEqual(f.map(\.id), ["spotlight", "lower", "lowerAlways"])
        XCTAssertEqual(f.first?.action, .settings(ProcessFixes.spotlight))
    }

    func testLeversReflectState() {
        XCTAssertEqual(ProcessFixes.fixes(for: "node", app: nil, canLower: true, lowered: true).map(\.id), ["lowerAlways"])
        XCTAssertEqual(ProcessFixes.fixes(for: "node", app: nil, canLower: true, lowered: true, always: true).map(\.id), [])
        XCTAssertEqual(ProcessFixes.fixes(for: "Slack Helper", app: "Slack", canLower: false).map(\.id), ["reopen"])
        XCTAssertTrue(ProcessFixes.fixes(for: "launchd", app: nil, canLower: false).isEmpty)
    }

    func testCatalogue() {
        XCTAssertTrue(ProcessFixes.hasSpecific("WindowServer"))
        XCTAssertTrue(ProcessFixes.hasSpecific("Google Chrome Helper (Renderer)"))
        XCTAssertFalse(ProcessFixes.hasSpecific("node"))
        for name in ["mds", "backupd", "bird", "photoanalysisd", "kernel_task", "Dropbox", "coreaudiod", "clang"] {
            let f = ProcessFixes.specific(name)
            XCTAssertFalse(f.isEmpty, name)
            XCTAssertEqual(f.allSatisfy { ($0.button == nil) == ($0.action == .none) }, true, "advice has no button, actions do: \(name)")
        }
    }
}
