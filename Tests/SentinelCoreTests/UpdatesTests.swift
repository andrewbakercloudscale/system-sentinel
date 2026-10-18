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
                    {"name": "System-Sentinel-0.7.1.zip", "browser_download_url": "https://github.com/x/y/releases/download/v0.7.1/s.zip"}]}
        """
        let r = Updates.parse(Data(json.utf8))
        XCTAssertEqual(r?.version, "0.7.1")
        XCTAssertEqual(r?.tag, "v0.7.1")
        XCTAssertEqual(r?.zip?.lastPathComponent, "s.zip")
        XCTAssertNotNil(r?.published)
        XCTAssertEqual(Updates.highlights(r?.notes ?? ""), ["Updates: checks for new versions.", "Fixes xattr."])
        XCTAssertNil(Updates.parse(Data("{\"message\": \"Not Found\"}".utf8)))
        XCTAssertNil(Updates.parse(Data(#"{"tag_name": "v../../x"}"#.utf8)), "a tag that is not a version is refused")
        XCTAssertNil(Updates.parse(Data(#"{"tag_name": "-v1.0"}"#.utf8)))
        let evil = Updates.parse(Data(#"{"tag_name": "v1.0.0", "html_url": "file:///etc", "assets": [{"name": "a.zip", "browser_download_url": "http://e/a.zip"}]}"#.utf8))
        XCTAssertNil(evil?.page, "only https GitHub links")
        XCTAssertNil(evil?.zip)
    }

    func testVerifyRefusesAnythingButTheSameApp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString)/X.app/Contents")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSDictionary(dictionary: ["CFBundleIdentifier": "other.app", "CFBundleShortVersionString": "1.0"])
            .write(to: dir.appendingPathComponent("Info.plist"), atomically: true)
        let app = dir.deletingLastPathComponent()
        XCTAssertEqual(Updates.verify(app, version: "1.0", bundleID: "consulting.cloudscale.systemsentinel"), "The download is a different app.")
        XCTAssertEqual(Updates.verify(app, version: "2.0", bundleID: "other.app"), "The download's version does not match the release.")
        XCTAssertNotNil(Updates.verify(app, version: "1.0", bundleID: "other.app"), "unsigned is refused")
    }

    func testParsesChangesNewestFirst() {
        let json = #"""
        {"ahead_by": 3, "html_url": "https://github.com/x/y/compare/v0.8.0...main",
         "commits": [{"sha": "aaaaaaa111", "commit": {"message": "First\n\nbody", "author": {"date": "2026-10-18T09:00:00Z"}}},
                     {"sha": "bbbbbbb222", "commit": {"message": "Second", "author": {"date": "2026-10-18T10:00:00Z"}}},
                     {"sha": "ccccccc333", "commit": {"message": "Third", "author": {"date": "2026-10-18T11:00:00Z"}}}],
         "files": [{"filename": "a"}, {"filename": "b"}]}
        """#
        let c = Updates.parseChanges(Data(json.utf8))
        XCTAssertEqual(c?.ahead, 3)
        XCTAssertEqual(c?.files, 2)
        XCTAssertEqual(c?.commits.map(\.title), ["Third", "Second", "First"])
        XCTAssertEqual(c?.commits.last?.sha, "aaaaaaa")
        XCTAssertNotNil(c?.page)
        XCTAssertNil(Updates.parseChanges(Data("{}".utf8)))
    }

    func testSwapScriptQuotesPaths() {
        let s = Updates.swapScript(pid: 42, newApp: "/tmp/a b/System Sentinel.app", installedAt: "/Applications/O'Brien.app")
        XCTAssertTrue(s.contains("kill -0 42"))
        XCTAssertTrue(s.contains("set -euo pipefail"))
        XCTAssertFalse(s.contains("xattr"))
        XCTAssertTrue(s.contains("'/tmp/a b/System Sentinel.app'"))
        XCTAssertTrue(s.contains("'/Applications/O'\\''Brien.app'"))
    }
}
