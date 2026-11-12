import XCTest
@testable import SentinelCore

final class AppCachesTests: XCTestCase {
    let mb: UInt64 = 1 << 20

    func testOffered() {
        XCTAssertTrue(AppCaches.offered("com.microsoft.Outlook", own: nil))
        XCTAssertTrue(AppCaches.offered("com.apple.Safari", own: nil))
        XCTAssertFalse(AppCaches.offered("com.apple.nsurlsessiond", own: nil), "macOS's own")
        XCTAssertFalse(AppCaches.offered("CloudKit", own: nil))
        XCTAssertFalse(AppCaches.offered("ms-playwright", own: nil), "slow to download again")
        XCTAssertFalse(AppCaches.offered(".DS_Store", own: nil))
        XCTAssertFalse(AppCaches.offered("com.cloudscale.SystemSentinel", own: "com.cloudscale.SystemSentinel"))
    }

    func testGroupMergesContainerAndDropsSmall() {
        let home = "/Users/a"
        let g = AppCaches.group(user: [("com.microsoft.Outlook", "\(home)/Library/Caches/com.microsoft.Outlook", 50 * mb),
                                       ("tiny", "\(home)/Library/Caches/tiny", 1000),
                                       ("com.apple.akd", "\(home)/Library/Caches/com.apple.akd", 900 * mb),
                                       ("Google", "\(home)/Library/Caches/Google", 300 * mb)],
                                containers: [("com.microsoft.Outlook", "\(home)/Library/Containers/com.microsoft.Outlook/Data/Library/Caches", 200 * mb)],
                                own: nil)
        XCTAssertEqual(g.map(\.id), ["Google", "com.microsoft.Outlook"])
        XCTAssertEqual(g[1].bytes, 250 * mb)
        XCTAssertEqual(g[1].folders.count, 2)
    }

    func testIsCacheFolder() {
        let h = "/Users/a"
        XCTAssertTrue(AppCaches.isCacheFolder("\(h)/Library/Caches/com.microsoft.Outlook", home: h))
        XCTAssertTrue(AppCaches.isCacheFolder("\(h)/Library/Containers/com.microsoft.Outlook/Data/Library/Caches", home: h))
        for bad in ["\(h)/Library/Caches", "\(h)/Library/Caches/../../Documents", "\(h)/Documents", "\(h)/Library/Caches/a/b",
                    "/Users/b/Library/Caches/x", "\(h)/Library/Containers/x/Data/Documents", "\(h)/Library/Caches/x/",
                    "\(h)//Library/Caches/x", "\(h)/Library/Containers/../Data/Library/Caches", "\(h)x/Library/Caches/y"] {
            XCTAssertFalse(AppCaches.isCacheFolder(bad, home: h), bad)
        }
    }
}
