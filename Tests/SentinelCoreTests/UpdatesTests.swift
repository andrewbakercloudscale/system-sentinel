import XCTest
@testable import SentinelCore

final class UpdatesTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(Updates.isNewer("0.7.1", than: "0.7.0"))
        XCTAssertTrue(Updates.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(Updates.isNewer("v1.0", than: "0.99.9"))
        XCTAssertFalse(Updates.isNewer("0.7.0", than: "0.7.0"))
        XCTAssertFalse(Updates.isNewer("0.7", than: "0.7.0"))
        XCTAssertFalse(Updates.isNewer("0.6.9", than: "0.7.0"))
    }

    func testParsesLatestReleaseAndHighlights() {
        let json = """
        {"tag_name": "v0.7.1", "html_url": "https://github.com/x/y/releases/tag/v0.7.1",
         "published_at": "2026-10-18T09:00:00Z",
         "body": "## New in 0.7.1\\n\\n- **Updates**: checks for new versions.\\n- Fixes `xattr`.\\n\\n## Install\\n\\n- not this",
         "assets": [{"name": "notes.txt", "browser_download_url": "https://e/n.txt"},
                    {"name": "System-Sentinel-0.7.1.zip", "browser_download_url": "https://e/s.zip"}]}
        """
        let r = Updates.parse(Data(json.utf8))
        XCTAssertEqual(r?.version, "0.7.1")
        XCTAssertEqual(r?.tag, "v0.7.1")
        XCTAssertEqual(r?.zip?.absoluteString, "https://e/s.zip")
        XCTAssertNotNil(r?.published)
        XCTAssertEqual(Updates.highlights(r?.notes ?? ""), ["Updates: checks for new versions.", "Fixes xattr."])
        XCTAssertNil(Updates.parse(Data("{\"message\": \"Not Found\"}".utf8)))
    }

    func testSwapScriptQuotesPaths() {
        let s = Updates.swapScript(pid: 42, newApp: "/tmp/a b/System Sentinel.app", installedAt: "/Applications/O'Brien.app")
        XCTAssertTrue(s.contains("kill -0 42"))
        XCTAssertTrue(s.contains("'/tmp/a b/System Sentinel.app'"))
        XCTAssertTrue(s.contains("'/Applications/O'\\''Brien.app'"))
    }
}
