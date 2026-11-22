import Testing
import Foundation
@testable import SentinelCore

@Suite struct AppDataHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // on a minute boundary

    @Test func readingsInOneMinuteAddUp() {
        var h = AppDataHistory()
        h.add(["a": ("Chrome", 100, 10)], at: t0)
        h.add(["a": ("Chrome", 50, 5)], at: t0.addingTimeInterval(30))
        #expect(h.minutes.count == 1)
        #expect(h.totals(.download)["a"] == 150)
        #expect(h.totals(.upload)["a"] == 15)
        #expect(h.totals(.both)["a"] == 165)
        #expect(h.slices(10, .both).first?.bytes == 165)
    }

    @Test func topTenAndTheRestAsOther() {
        var h = AppDataHistory()
        var by: [String: (name: String, down: UInt64, up: UInt64)] = [:]
        for i in 1...12 { by["k\(i)"] = ("App \(i)", UInt64(i * 100), 0) }
        h.add(by, at: t0)
        let top = h.top(10, .download)
        #expect(top.count == 10)
        #expect(top.first == "k12")
        let other = h.slices(10, .download).first { $0.key == "other" }
        #expect(other?.bytes == 300)   // k1 and k2
        #expect(h.top(10, .upload).isEmpty)
    }

    @Test func olderThanAnHourIsDropped() {
        var h = AppDataHistory()
        h.add(["a": ("Old", 1, 0)], at: t0)
        h.add(["b": ("New", 1, 0)], at: t0.addingTimeInterval(3601))
        #expect(h.minutes.count == 1)
        #expect(h.names["a"] == nil)
        #expect(h.names["b"] == "New")
    }
}
