import Foundation
import Testing
@testable import SentinelCore

@Suite struct FolderChurnTests {
    let home = "/Users/a"

    @Test func foldersSpotlightIndexes() {
        #expect(FolderChurn.folder(of: "/Users/a/Desktop/github/app/src/main.swift", home: home)?.path == "/Users/a/Desktop/github/app")
        #expect(FolderChurn.folder(of: "/Users/a/Desktop/github/app/src/main.swift", home: home)?.generated == false)
        #expect(FolderChurn.folder(of: "/Users/a/Documents/notes.txt", home: home)?.path == "/Users/a/Documents")
        let nm = FolderChurn.folder(of: "/Users/a/code/web/node_modules/react/index.js", home: home)
        #expect(nm?.path == "/Users/a/code/web/node_modules")
        #expect(nm?.generated == true)
    }

    @Test func foldersSpotlightSkips() {
        #expect(FolderChurn.folder(of: "/Users/a/Library/Caches/x/y", home: home) == nil)
        #expect(FolderChurn.folder(of: "/Users/a/code/app/.build/debug/x.o", home: home) == nil)
        #expect(FolderChurn.folder(of: "/Users/a/code/app/out.noindex/x.o", home: home) == nil)
        #expect(FolderChurn.folder(of: "/Users/a/code/app/.DS_Store", home: home) == nil)
        #expect(FolderChurn.folder(of: "/private/tmp/x", home: home) == nil)
        #expect(FolderChurn.folder(of: "/Users/a/file.txt", home: home) == nil)
    }

    @Test func topCountsTheWindow() {
        let c = FolderChurn(home: home, window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_020)
        c.record(Array(repeating: "/Users/a/code/web/node_modules/x.js", count: 80), at: t0)
        c.record(Array(repeating: "/Users/a/Documents/a.txt", count: 30), at: t0)
        c.record(Array(repeating: "/Users/a/code/web/node_modules/y.js", count: 40), at: t0.addingTimeInterval(120))
        let top = c.top(minimum: 50, at: t0.addingTimeInterval(120))
        #expect(top.map(\.path) == ["/Users/a/code/web/node_modules"])
        #expect(top.first?.changes == 120)
        #expect(top.first?.generated == true)
        // Ten minutes on, it has all aged out.
        #expect(c.top(minimum: 1, at: t0.addingTimeInterval(600)).isEmpty)
    }
}
